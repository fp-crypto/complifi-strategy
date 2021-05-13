import pytest
import brownie
from brownie import Wei, accounts, Contract, config


@pytest.mark.require_network("mainnet-fork")
def test_clone(
    chain,
    gov,
    strategist,
    rewards,
    keeper,
    strategy,
    Strategy,
    vault,
    token_vault,
    liquitiy_mining,
    comfi,
):
    # Shouldn't be able to call initialize again
    with brownie.reverts():
        strategy.initialize(
            vault,
            strategist,
            rewards,
            keeper,
            token_vault,
            liquitiy_mining,
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
        liquitiy_mining,
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
            liquitiy_mining,
            comfi,
            {"from": gov},
        )
