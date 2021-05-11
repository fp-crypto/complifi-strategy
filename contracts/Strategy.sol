// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "./interfaces/UniswapInterfaces/IUniswapV2Router02.sol";
import {IVault as IComplifiVault} from "./interfaces/complifi/IVault.sol";

interface ILiquidityMining {
    function deposit(uint256 _pid, uint256 _amount) external;

    function withdraw(uint256 _pid, uint256 _amount) external;

    function withdrawEmergency(uint256 _pid) external;

    function poolInfo(uint256 _pid)
        external
        view
        returns (
            address,
            uint256,
            uint256,
            uint256
        );

    function userPoolInfo(uint256 _pid, address user)
        external
        view
        returns (uint256, uint256);

    function claim() external;

    function poolPidByAddress(address _address) external view returns (uint256);

    function getPendingReward(uint256 _pid, address _user)
        external
        view
        returns (uint256 total, uint256 unlocked);
}

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    ILiquidityMining private constant liquidityMining =
        ILiquidityMining(address(0x8a5827Ad1f28d3f397B748CE89895e437b8ef90D));
    IComplifiVault private constant tokenVault =
        IComplifiVault(address(0xea5b9650f6c47D112Bb008132a86388B594Eb849));
    IERC20 comfi = IERC20(address(0x752Efadc0a7E05ad1BCCcDA22c141D01a75EF1e4));

    address private constant router =
        address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    address private constant weth =
        address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    address[] public path;

    constructor(address _vault) public BaseStrategy(_vault) {
        want.safeApprove(address(tokenVault), type(uint256).max);

        primaryToken().safeApprove(address(tokenVault), type(uint256).max);
        complementToken().safeApprove(address(tokenVault), type(uint256).max);

        primaryToken().safeApprove(address(liquidityMining), type(uint256).max);
        complementToken().safeApprove(
            address(liquidityMining),
            type(uint256).max
        );

        comfi.safeApprove(router, type(uint256).max);
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "StrategyComplifiUSDC";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        uint256 tokens =
            complementToken().balanceOf(address(this)).add(
                primaryToken().balanceOf(address(this))
            );
        (uint256 depositedPrimary, ) =
            liquidityMining.userPoolInfo(primaryTokenPid(), address(this));
        (uint256 depositedComplement, ) =
            liquidityMining.userPoolInfo(complementTokenPid(), address(this));

        uint256 depositedTokens = depositedPrimary.add(depositedComplement);

        return want.balanceOf(address(this)).add(tokens).add(depositedTokens);
    }

    function pendingRewards()
        public
        view
        returns (uint256 _total, uint256 _unlocked)
    {
        (uint256 primaryTotal, uint256 primaryUnlocked) =
            liquidityMining.getPendingReward(primaryTokenPid(), address(this));

        (uint256 complementTotal, uint256 complementUnlocked) =
            liquidityMining.getPendingReward(
                complementTokenPid(),
                address(this)
            );

        _total = primaryTotal.add(complementTotal);
        _unlocked = primaryUnlocked.add(complementUnlocked);
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
            _profit = assets - debt;

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
                            newLoose - _profit,
                            _debtPayment
                        );
                    }
                }
            }
        } else {
            //serious loss should never happen but if it does lets record it accurately
            _loss = debt - assets;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }

        uint256 wantBalance = want.balanceOf(address(this));

        if (wantBalance > 0) {
            // When we mint we get 1 primary and 1 complement token for every 2 wants
            tokenVault.mint(wantBalance);

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

            (uint256 depositedPrimary, ) =
                liquidityMining.userPoolInfo(primaryTokenPid(), address(this));
            (uint256 depositedComplement, ) =
                liquidityMining.userPoolInfo(
                    complementTokenPid(),
                    address(this)
                );
            uint256 deposited = depositedPrimary.add(depositedComplement);
            if (deposited < amountToFree) {
                amountToFree = deposited;
            }
            if (deposited > 0) {
                liquidityMining.claim();
                liquidityMining.withdraw(
                    primaryTokenPid(),
                    amountToFree.div(2)
                );
                liquidityMining.withdraw(
                    complementTokenPid(),
                    amountToFree.div(2)
                );

                uint256 primBalance = primaryToken().balanceOf(address(this));
                uint256 compBalance =
                    complementToken().balanceOf(address(this));

                // We should always have balanced amounts, but better safe than sorry
                if (primBalance > 0 && compBalance > 0) {
                    (primBalance >= compBalance)
                        ? tokenVault.refund(
                            Math.min(primBalance, amountToFree.div(2))
                        )
                        : tokenVault.refund(
                            Math.min(compBalance, amountToFree.div(2))
                        );
                }
            }

            _liquidatedAmount = want.balanceOf(address(this));
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary

    function prepareMigration(address _newStrategy) internal override {
        liquidatePosition(uint256(-1)); //withdraw all. does not matter if we ask for too much
        _sell();
    }

    function emergencyWithdrawal(uint256 _pid) external onlyGovernance {
        liquidityMining.withdrawEmergency(_pid);

        uint256 primBalance = primaryToken().balanceOf(address(this));
        uint256 compBalance = complementToken().balanceOf(address(this));

        if (primBalance > 0 && compBalance > 0) {
            (primBalance >= compBalance)
                ? tokenVault.refund(primBalance)
                : tokenVault.refund(compBalance);
        }
    }

    //sell all function
    function _sell() internal {
        uint256 rewardBal = comfi.balanceOf(address(this));
        if (rewardBal == 0) {
            return;
        }

        if (path.length == 0) {
            address[] memory tpath;
            if (address(want) != weth) {
                tpath = new address[](3);
                tpath[2] = address(want);
            } else {
                tpath = new address[](2);
            }

            tpath[0] = address(comfi);
            tpath[1] = weth;

            IUniswapV2Router02(router).swapExactTokensForTokens(
                rewardBal,
                uint256(0),
                tpath,
                address(this),
                now
            );
        } else {
            IUniswapV2Router02(router).swapExactTokensForTokens(
                rewardBal,
                uint256(0),
                path,
                address(this),
                now
            );
        }
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}
}
