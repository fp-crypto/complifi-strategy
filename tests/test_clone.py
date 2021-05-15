import pytest
import brownie
from brownie import Wei, accounts, Contract, config


@pytest.mark.require_network("mainnet-fork")
def test_clone(
    chain,
    gov,
    token,
    strategist,
    rewards,
    keeper,
    strategy,
    Strategy,
    vault,
    token_vault,
    token_vault_registry,
    liquidity_mining,
    comfi,
    user,
    amount,
):
    # Shouldn't be able to call initialize again
    with brownie.reverts():
        strategy.initialize(
            vault,
            strategist,
            rewards,
            keeper,
            token_vault,
            token_vault_registry,
            liquidity_mining,
            comfi,
            {"from": gov},
        )

    # Clone the strategy
    tx = strategy.cloneStrategy(
        vault,
        strategist,
        rewards,
        keeper,
        token_vault,
        token_vault_registry,
        liquidity_mining,
        comfi,
        {"from": gov},
    )
    new_strategy = Strategy.at(tx.return_value)

    # Shouldn't be able to call initialize again
    with brownie.reverts():
        new_strategy.initialize(
            vault,
            strategist,
            rewards,
            keeper,
            token_vault,
            token_vault_registry,
            liquidity_mining,
            comfi,
            {"from": gov},
        )

    vault.revokeStrategy(strategy, {"from": gov})
    vault.addStrategy(new_strategy, 10_000, 0, 1_000, {"from": gov})

    user_start_balance = token.balanceOf(user)
    before_pps = vault.pricePerShare()
    token.approve(vault.address, amount, {"from": user})
    vault.deposit({"from": user})

    new_strategy.harvest({"from": gov})

    chain.sleep(3600)
    chain.mine(100)

    # Get profits and withdraw
    new_strategy.harvest({"from": gov})
    chain.sleep(3600 * 6)
    chain.mine(1)

    vault.withdraw({"from": user})
    user_end_balance = token.balanceOf(user)

    assert vault.pricePerShare() > before_pps
    assert user_end_balance > user_start_balance
