import pytest
from brownie import config
from brownie import Contract


@pytest.fixture
def gov(accounts):
    yield accounts.at("0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52", force=True)


@pytest.fixture
def user(accounts):
    yield accounts[0]


@pytest.fixture
def rewards(accounts):
    yield accounts[1]


@pytest.fixture
def guardian(accounts):
    yield accounts[2]


@pytest.fixture
def management(accounts):
    yield accounts[3]


@pytest.fixture
def strategist(accounts):
    yield accounts[4]


@pytest.fixture
def keeper(accounts):
    yield accounts[5]


@pytest.fixture
def token():
    token_address = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"  # this should be the address of the ERC-20 used by the strategy/vault (DAI)
    yield Contract(token_address)


@pytest.fixture
def amount(accounts, token, user):
    amount = 5_000_000 * 10 ** token.decimals()
    # In order to get some funds for the token you are about to use,
    # it impersonate an exchange address to use it's funds.
    reserve = accounts.at("0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503", True)
    token.transfer(user, amount, {"from": reserve})
    yield amount


@pytest.fixture
def weth():
    token_address = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
    yield Contract(token_address)


@pytest.fixture
def weth_amout(user, weth):
    weth_amout = 10 ** weth.decimals()
    user.transfer(weth, weth_amout)
    yield weth_amout


@pytest.fixture
def vault(pm, gov, rewards, guardian, management, token):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(token, gov, rewards, "", "", guardian)
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    yield vault


@pytest.fixture
def strategy(
    strategist,
    keeper,
    vault,
    Strategy,
    gov,
    token_vault,
    token_vault_registry,
    liquidity_mining,
    comfi,
):
    strategy = strategist.deploy(
        Strategy, vault, token_vault, token_vault_registry, liquidity_mining, comfi
    )
    strategy.setKeeper(keeper)
    vault.addStrategy(strategy, 10_000, 0, 1_000, {"from": gov})
    yield strategy


@pytest.fixture
def token_vault():
    # 5x eth 1 june 2021 expiry
    yield Contract("0xea5b9650f6c47D112Bb008132a86388B594Eb849")


@pytest.fixture
def token_vault_registry():
    yield Contract("0x3269DeB913363eE58E221808661CfDDa9d898127")


@pytest.fixture
def comfi():
    yield Contract("0x752Efadc0a7E05ad1BCCcDA22c141D01a75EF1e4")


@pytest.fixture
def comfi_whale(accounts):
    yield accounts.at("0x0FB21490A878AA2Af08117C96F897095797bD91C", force=True)


@pytest.fixture
def liquidity_mining():
    yield Contract("0x8a5827Ad1f28d3f397B748CE89895e437b8ef90D")


@pytest.fixture(scope="session")
def RELATIVE_APPROX():
    yield 1e-5
