import pytest


def test_emergency_exit(
    accounts,
    token,
    vault,
    strategy,
    user,
    gov,
    strategist,
    amount,
    RELATIVE_APPROX,
    chain,
):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # Harvest 1: Send funds through the strategy
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    chain.mine(1)

    strategy.setEmergencyExit({"from": gov})
    strategy.emergencyWithdrawal({"from": gov})
    assert pytest.approx(token.balanceOf(strategy), rel=RELATIVE_APPROX) == amount

    strategy.harvest()
    assert pytest.approx(token.balanceOf(vault.address), rel=RELATIVE_APPROX) == amount
