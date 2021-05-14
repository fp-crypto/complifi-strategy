# TODO: Add tests that show proper migration of the strategy to a newer one
#       Use another copy of the strategy to simulate the migration
#       Show that nothing is lost!

import pytest
from brownie import Contract
import brownie


def test_migration(
    token,
    vault,
    strategy,
    amount,
    Strategy,
    strategist,
    gov,
    user,
    token_vault,
    token_vault_registry,
    liquidity_mining,
    comfi,
    RELATIVE_APPROX,
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # migrate to a new strategy
    new_strategy = strategist.deploy(
        Strategy, vault, token_vault, token_vault_registry, liquidity_mining, comfi
    )
    strategy.migrate(new_strategy.address, {"from": gov})
    assert (
        pytest.approx(new_strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX)
        == amount
    )


def test_token_vault_migration(
    token, vault, strategy, amount, Strategy, strategist, gov, user, RELATIVE_APPROX
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # migrate to a new token vault
    new_token_vault = Contract("0xd498bF281262e04b0Dc8A1c6D14877Cee46AAAAE")

    strategy.migrateTokenVault(new_token_vault.address, {"from": gov})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount


def test_token_invalid_vault_migration(
    token, vault, strategy, amount, Strategy, strategist, gov, user, RELATIVE_APPROX
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    invalid_token_vault = Contract("0x11111112542D85B3EF69AE05771c2dCCff4fAa26")

    # migrate to a new token vault
    with brownie.reverts():
        strategy.migrateTokenVault(invalid_token_vault, {"from": gov})
