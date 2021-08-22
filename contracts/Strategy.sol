// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy, VaultAPI} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";

import "./interfaces/UniswapInterfaces/IUniswapV2Router02.sol";
import {IVault as IComplifiVault} from "./interfaces/complifi/IVault.sol";
import {ILiquidityMining} from "./interfaces/complifi/ILiquidityMining.sol";

interface IComplifiVaultRegistry {
    function getAllVaults() external view returns (address[] memory);
}

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    IComplifiVault public tokenVault;
    IComplifiVaultRegistry private tokenVaultRegistry;
    ILiquidityMining private liquidityMining;

    // Path for swaps
    address[] private path;

    address private constant router =
        0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506;
    address private constant weth = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
    IERC20 private constant comfi = IERC20(0x72bba3Aa59a1cCB1591D7CDDB714d8e4D5597E96);

    event Cloned(address indexed clone);

    constructor(
        address _vault,
        address _tokenVault,
        address _tokenVaultRegistry,
        address _liquidityMining
    ) public BaseStrategy(_vault) {
        _initializeStrat(
            _tokenVault,
            _tokenVaultRegistry,
            _liquidityMining
        );
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _tokenVault,
        address _tokenVaultRegistry,
        address _liquidityMining
    ) external {
        //note: initialise can only be called once.
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(
            _tokenVault,
            _tokenVaultRegistry,
            _liquidityMining
        );
    }

    function _initializeStrat(
        address _tokenVault,
        address _tokenVaultRegistry,
        address _liquidityMining
    ) internal {
        tokenVaultRegistry = IComplifiVaultRegistry(_tokenVaultRegistry);
        require(
            _isRegisteredTokenVault(_tokenVault),
            "Complifi token vault not registered"
        );

        tokenVault = IComplifiVault(_tokenVault);
        liquidityMining = ILiquidityMining(_liquidityMining);

        comfi.safeApprove(router, type(uint256).max);
        _approveSpend(type(uint256).max);

        // Initialize the swap path
        path = new address[](3);
        path[0] = address(comfi);
        path[1] = weth;
        path[2] = address(want);
    }

    function cloneStrategy(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _tokenVault,
        address _tokenVaultRegistry,
        address _liquidityMining
    ) external returns (address newStrategy) {
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(address(this));

        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(
                clone_code,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(
                add(clone_code, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            newStrategy := create(0, clone_code, 0x37)
        }

        Strategy(newStrategy).initialize(
            _vault,
            _strategist,
            _rewards,
            _keeper,
            _tokenVault,
            _tokenVaultRegistry,
            _liquidityMining
        );

        emit Cloned(newStrategy);
    }

    function name() external view override returns (string memory) {
        return "StrategyComplifiUSDC";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        uint256 looseTokens =
            complementToken().balanceOf(address(this)).add(
                primaryToken().balanceOf(address(this))
            );
        uint256 primDeposited =
            liquidityMining
                .userPoolInfo(primaryTokenPid(), address(this))
                .amount;
        uint256 compDeposited =
            liquidityMining
                .userPoolInfo(complementTokenPid(), address(this))
                .amount;

        uint256 depositedTokens = primDeposited.add(compDeposited);

        return
            want.balanceOf(address(this)).add(looseTokens).add(depositedTokens);
    }

    function primaryToken() private view returns (IERC20) {
        return IERC20(tokenVault.primaryToken());
    }

    function complementToken() private view returns (IERC20) {
        return IERC20(tokenVault.complementToken());
    }

    function primaryTokenPid() private view returns (uint256) {
        return liquidityMining.poolPidByAddress(address(primaryToken()));
    }

    function complementTokenPid() private view returns (uint256) {
        return liquidityMining.poolPidByAddress(address(complementToken()));
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        liquidityMining.claim();
        _sell();

        uint256 assets = estimatedTotalAssets();
        uint256 wantBal = want.balanceOf(address(this));

        uint256 debt = vault.strategies(address(this)).totalDebt;

        if (assets >= debt) {
            _debtPayment = _debtOutstanding;
            _profit = assets.sub(debt);

            uint256 amountToFree = _profit.add(_debtPayment);

            if (amountToFree > 0 && wantBal < amountToFree) {
                liquidatePosition(amountToFree);

                uint256 newLoose = want.balanceOf(address(this));

                //if we dont have enough money adjust _debtOutstanding and only change profit if needed
                if (newLoose < amountToFree) {
                    if (_profit > newLoose) {
                        _profit = newLoose;
                        _debtPayment = 0;
                    } else {
                        _debtPayment = Math.min(
                            newLoose.sub(_profit),
                            _debtPayment
                        );
                    }
                }
            }
        } else {
            //serious loss should never happen but if it does lets record it accurately
            _loss = debt.sub(assets);
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }

        uint256 wantBalance = want.balanceOf(address(this));

        if (
            wantBalance > 0 && tokenVault.state() == IComplifiVault.State.Live
        ) {
            // When we mint we get 1 primary and 1 complement token for every 2 wants
            tokenVault.mint(wantBalance);

            // Deposit the minted primary and complement tokens in the masterchefy thing
            liquidityMining.deposit(
                primaryTokenPid(),
                primaryToken().balanceOf(address(this))
            );
            liquidityMining.deposit(
                complementTokenPid(),
                complementToken().balanceOf(address(this))
            );
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 totalAssets = want.balanceOf(address(this));
        if (_amountNeeded > totalAssets) {
            uint256 amountToFree = _amountNeeded.sub(totalAssets);

            uint256 primTokenPid = primaryTokenPid();
            uint256 compTokenPid = complementTokenPid();

            uint256 primDeposited =
                liquidityMining
                    .userPoolInfo(primTokenPid, address(this))
                    .amount;
            uint256 compDeposited =
                liquidityMining
                    .userPoolInfo(compTokenPid, address(this))
                    .amount;
            uint256 deposited = primDeposited.add(compDeposited);

            if (deposited < amountToFree) {
                amountToFree = deposited;
            }
            if (deposited > 0) {
                // We withdraw half the amounted needed from each pool
                // As 1 primary and 1 complement can withdraw 2 want
                uint256 tokensToFree = amountToFree.div(2);

                // Avoid floor rounding issues
                while (tokensToFree.mul(2) < amountToFree) {
                    tokensToFree++;
                }

                liquidityMining.withdraw(
                    primTokenPid,
                    Math.min(primDeposited, tokensToFree)
                );
                liquidityMining.withdraw(
                    compTokenPid,
                    Math.min(compDeposited, tokensToFree)
                );

                uint256 primBalance = primaryToken().balanceOf(address(this));
                uint256 compBalance =
                    complementToken().balanceOf(address(this));

                // We should always have balanced amounts of primary and complement
                // but better safe than sorry
                if (primBalance > 0 && compBalance > 0) {
                    if (primBalance <= compBalance) {
                        tokenVault.refund(Math.min(primBalance, tokensToFree));
                    } else {
                        tokenVault.refund(Math.min(compBalance, tokensToFree));
                    }
                }
            }

            _liquidatedAmount = want.balanceOf(address(this));
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256 _amountFreed) {
        (_amountFreed, ) = liquidatePosition(type(uint256).max);
    }

    function migrateTokenVault(address _newTokenVault) external onlyGovernance {
        require(
            _isRegisteredTokenVault(_newTokenVault),
            "Complifi token vault not registered"
        );

        liquidateAllPositions();

        // Revoke approvals for the old token vault
        _approveSpend(0);

        tokenVault = IComplifiVault(_newTokenVault);

        // Approve spend of relevant tokens on the new token vault
        _approveSpend(type(uint256).max);
    }

    function prepareMigration(address _newStrategy) internal override {}

    function emergencyWithdrawal() external onlyAuthorized {
        liquidityMining.withdrawEmergency(primaryTokenPid());
        liquidityMining.withdrawEmergency(complementTokenPid());

        uint256 primBalance = primaryToken().balanceOf(address(this));
        uint256 compBalance = complementToken().balanceOf(address(this));

        // Refund will get back want
        if (primBalance > 0 && compBalance > 0) {
            (primBalance <= compBalance)
                ? tokenVault.refund(primBalance)
                : tokenVault.refund(compBalance);
        }
    }

    function _approveSpend(uint256 _amount) internal {
        want.safeApprove(address(tokenVault), _amount);

        IERC20 primToken = primaryToken();
        IERC20 compToken = complementToken();

        primToken.safeApprove(address(tokenVault), _amount);
        compToken.safeApprove(address(tokenVault), _amount);
        primToken.safeApprove(address(liquidityMining), _amount);
        compToken.safeApprove(address(liquidityMining), _amount);
    }

    //sell all function
    function _sell() internal {
        uint256 comfiBal = comfi.balanceOf(address(this));
        if (comfiBal == 0) {
            return;
        }

        IUniswapV2Router02(router).swapExactTokensForTokens(
            comfiBal,
            uint256(0),
            path,
            address(this),
            now
        );
    }

    function _isRegisteredTokenVault(address _tokenVault)
        internal
        returns (bool)
    {
        // Just return true if we don't have a registry set
        if (address(tokenVaultRegistry) == address(0x0)) return true;

        address[] memory vaults = tokenVaultRegistry.getAllVaults();
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i] == _tokenVault) return true;
        }

        return false;
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    function ethToWant(uint256 _amtInWei) public view override returns (uint256) {
        return _amtInWei;
    }
}
