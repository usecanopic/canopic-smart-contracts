# Canopic protocol contracts

Canopic is a non-custodial venue for trading tokenised real-world assets on Robinhood Chain, and the code in this repository is its on-chain layer. Every market is served by two sources of liquidity. The first is an oracle vault that quotes both sides around the guarded Chainlink mid; the second is an RFQ maker, whose EIP-712 signed quote can take over for larger orders. A single router contract gives traders access to both, and all settlement happens in USDG.

The chain itself runs on Arbitrum Nitro, with chain ID 4663 for mainnet and 46630 for testnet. Foundry handles building, testing and deployment for the whole project.

## Table of contents

- [Project layout](#project-layout)
- [Lifecycle of a swap](#lifecycle-of-a-swap)
- [Local setup](#local-setup)
- [Deploying the protocol](#deploying-the-protocol)
- [Deployed contracts](#deployed-contracts)
- [Administration and upgrades](#administration-and-upgrades)
- [Protocol invariants](#protocol-invariants)
- [Integration guidance](#integration-guidance)
- [Security disclosures](#security-disclosures)
- [Licensing](#licensing)

## Project layout

### Contracts under `src/`

| Path | Responsibility |
| --- | --- |
| `venue/SwapRouter.sol` | The only contract traders call. It enforces eligibility, chooses between the vault and an RFQ quote, and links two legs together when both sides are tokens. |
| `venue/OracleVault.sol` | One instance exists for each market. It quotes off the oracle, skews for inventory, mints LP shares and settles redemptions in kind. |
| `venue/VaultFactory.sol` | Spawns new oracle vaults and maintains the token to vault mapping that the router consults. |
| `venue/RfqSettler.sol` | Settles maker RFQs in a single atomic step, provided the price lies inside the oracle band. Signatures follow EIP-712, and any outstanding quote can be voided by its nonce. |
| `oracle/OracleAdapter.sol` | Turns Chainlink aggregator and stream data into a guarded mid. A price is rejected when it is stale, jumps past the move cap, arrives during the wrong session or arrives while the sequencer is down. |
| `eligibility/EligibilityRegistry.sol` | Resolves role lookups by forwarding them to an attestation provider that can be swapped out. |
| `eligibility/AttestationBook.sol` | A standalone attestation registry whose semantics follow EAS. |
| `settings/SettingsTimelock.sol` | Stores all tunable parameters, with changes gated by a delay. Apart from stopping swaps, the guardian role can do nothing. |
| `settings/ProtocolTreasury.sol` | Destination for protocol revenue: per-swap fees, fees on RFQ fills, and a share of the vault spread. |
| `libraries/Types.sol` | Common structs and constants (quotes, fee breakdowns and similar) along with the `Roles` library. |
| `interfaces/` | Holds `IEligibilityRegistry`, `ISettingsTimelock` and `IOracleAdapter`, and also `ThirdParty.sol`, which declares external interfaces like Chainlink and ERC-8056. |
| `mocks/Mocks.sol` | Mock contracts for local use. USDG is simulated by `MockERC20` and a Stock Token by `MockStockToken`; `MockPriceFeed` and `MockStreamReader` imitate the aggregator and stream reader. |

### Scripts, tests and outputs

| Path | Description |
| --- | --- |
| `script/DeployProtocol.s.sol` | Stands up and connects every contract, applies the launch configuration and creates the initial market. |
| `script/Bootstrap.s.sol` | Seeds liquidity into a fresh testnet market and executes an opening buy and sell. |
| `script/GenerateActivity.s.sol` | Runs a single round of activity across several wallets: LP deposits, one partial redemption and a series of swaps. |
| `test/` | The Foundry suite, covering vault accounting, swap pricing, market hours and halts, the RFQ settler, governance and invariant tests. |
| `deployments/` | Address records keyed by chain ID, one JSON file each, produced by the deployment script. |

## Lifecycle of a swap

1. A trader submits `SwapRouter.swapExactIn`, supplying the token pair, an exact input amount, the smallest acceptable output and a deadline. Attaching a signed maker quote is optional.
2. The router confirms a valid `TRADER` attestation for the caller. Next, all in one transaction, the router derives a fresh vault quote, checks any attached maker signature, compares the two outputs and sends the order to whichever is better for the trader.
3. Vault pricing starts from the guarded Chainlink mid, then applies the tier's half-spread (multiplied by the current session factor), a signed skew based on inventory, and a separately itemised fee. Each fill logs every one of these components. Fills from either venue are confined to the tier's oracle band.
4. Swaps from one token to another are executed by the router as two atomic legs routed through USDG. Should either leg violate the guards of its market, the whole swap reverts.

## Local setup

```bash
forge soldeer install     # pulls forge-std and OpenZeppelin into dependencies/
forge build
forge test -vv
```

Libraries are managed by Soldeer instead of git submodules, pinning forge-std 1.9.7 and OpenZeppelin Contracts 5.2.0. Compilation uses Solidity 0.8.26 with via-IR turned on and the Cancun EVM as the target.

## Deploying the protocol

### Configuring the environment

Copy the example file to create your own:

```bash
cp .env.example .env
```

Fill in these values next:

- `PRIVATE_KEY`, holding the key of the account that will deploy.
- An RPC URL for the network you are targeting, either `ROBINHOOD_TESTNET_RPC` or `ROBINHOOD_RPC`. You can find the official endpoints at docs.robinhood.com/chain.
- The corresponding Blockscout API URL, needed so sources can be verified.
- `USDG`, `STOCK_TOKEN` and `STOCK_FEED`, pointing at real deployed contracts. Leave them empty on testnet or a local Anvil chain and the script deploys mocks in their place.

### Executing the deployment

Two RPC aliases are defined: `robinhood_testnet` points at chain ID 46630, while `robinhood` is reserved for mainnet.

```bash
source .env
forge script script/DeployProtocol.s.sol:DeployProtocol --rpc-url robinhood_testnet --broadcast --verify
```

When the run completes, `deployments/<chainId>.json` contains every address. The first market is also opened, configured with these documented launch values:

| Parameter | Value set by DeployProtocol |
| --- | --- |
| Half-spread for tier A | 10 bps |
| Oracle band for tier A | 75 bps |
| Maximum clip size for tier A | 50,000 USDG |
| Spread multiplier outside regular hours | x1.5 |
| Spread multiplier while the market is shut | x3 |
| Fee charged on each swap and on each RFQ fill | 2 bps apiece |
| Protocol's portion of the spread | 10% |

Additional options:

- `GOV`: the multisig address that should end up owning governance.
- `FINISH_BOOTSTRAP=true`: ends bootstrap mode, after which no parameter changes without the timelock delay.
- If mocks are being deployed and the deploying account is also the attestation issuer, that account receives attestations for all roles, letting you test every flow immediately.

### Manual verification of the vault

The `--verify` flag handles the eleven contracts deployed by the script itself. The oracle vault is the exception. It is deployed from inside `VaultFactory`, which leaves forge without the constructor arguments it needs, so the automated Blockscout attempt fails. Pull the addresses out of the deployments file and run the following:

```bash
ARGS=$(cast abi-encode "constructor(address,address,address,address,address,address,string,string)" \
  $SETTINGS_TIMELOCK $ELIGIBILITY_REGISTRY $ORACLE_ADAPTER $PROTOCOL_TREASURY $USDG $STOCK_TOKEN \
  "Canopic NVDAx Vault" "cvNVDAx")
forge verify-contract $ORACLE_VAULT src/venue/OracleVault.sol:OracleVault --chain 46630 \
  --verifier blockscout --verifier-url "$ROBINHOOD_TESTNET_BLOCKSCOUT_API" --constructor-args "$ARGS" --watch
```

### Producing activity on testnet

The two helper scripts read `deployments/<chainId>.json` and rely on the mock contracts, which limits them to testnet and local chains.

```bash
forge script script/Bootstrap.s.sol:Bootstrap --rpc-url robinhood_testnet --broadcast
forge script script/GenerateActivity.s.sol:GenerateActivity --rpc-url robinhood_testnet --broadcast --slow
```

`Bootstrap` issues tokens to the deploying account, supplies 500,000 USDG worth of liquidity to each side of the first vault, then sends a single buy and a single sell via the router.

`GenerateActivity` uses the deployer key to derive five trader wallets and two LP wallets, tops each up with a little gas and grants them attestations. Next it performs two deposits, a partial redemption and twenty swaps split between buys and sells. Runs build on whatever state already exists, so give `ROUND` a fresh value each time to vary the trade sizes.

Keep around 0.003 ETH in the deploying account to pay for a deployment plus one execution of each helper script. The gas top-ups account for most of that amount.

## Deployed contracts

### Robinhood Chain testnet, 46630

`0x5AF4587fb8702b4708F99293F26377158788ABAd` performed this deployment on 3 November 2026. It holds three hats on this network: bootstrap owner, guardian and attestation issuer. You can read the verified source of each of the twelve contracts on [Blockscout](https://explorer.testnet.chain.robinhood.com).

This deployment relies on no live third-party contracts. The launch script deployed mocks for USDG, the NVDAx stock token and the Chainlink aggregator, pricing NVDAx at 176.40 USDG. See `deployments/46630.json` for the complete record.

Roughly 1,000,000 USDG of liquidity sits in the first vault, split evenly. Thanks to the helper scripts, the explorer and the app can also display genuine history, including deposits, a redemption and a number of fills.

| Contract | Address |
| --- | --- |
| SwapRouter | [`0x0d57EB046fCe57530d43D8e3DA2f26B9e0Aa70BE`](https://explorer.testnet.chain.robinhood.com/address/0x0d57EB046fCe57530d43D8e3DA2f26B9e0Aa70BE) |
| RfqSettler | [`0x2613dF746BEfc8cfE7a3ecB3aa794733b5fC7Bc6`](https://explorer.testnet.chain.robinhood.com/address/0x2613dF746BEfc8cfE7a3ecB3aa794733b5fC7Bc6) |
| VaultFactory | [`0x0f68e9B872844F393CAcA5a2188B80C0565719b3`](https://explorer.testnet.chain.robinhood.com/address/0x0f68e9B872844F393CAcA5a2188B80C0565719b3) |
| OracleVault (`cvNVDAx` shares, NVDAx market) | [`0x51354EC791E91b93A0FBf4bBBFa830d84637Cd12`](https://explorer.testnet.chain.robinhood.com/address/0x51354EC791E91b93A0FBf4bBBFa830d84637Cd12) |
| OracleAdapter | [`0x80AAB4b90295a8b9213689DE573338a7a61eAa6F`](https://explorer.testnet.chain.robinhood.com/address/0x80AAB4b90295a8b9213689DE573338a7a61eAa6F) |
| EligibilityRegistry | [`0xA72A34D649F3Dcf7169AFef1429f7F9c0FA5C19f`](https://explorer.testnet.chain.robinhood.com/address/0xA72A34D649F3Dcf7169AFef1429f7F9c0FA5C19f) |
| AttestationBook | [`0x20e1e034F34E617A3Bda5DD8Ef12E8A3BE59827E`](https://explorer.testnet.chain.robinhood.com/address/0x20e1e034F34E617A3Bda5DD8Ef12E8A3BE59827E) |
| SettingsTimelock | [`0x91F91cD0f235F41d50647F831ffbb467EE3c287B`](https://explorer.testnet.chain.robinhood.com/address/0x91F91cD0f235F41d50647F831ffbb467EE3c287B) |
| ProtocolTreasury | [`0x6870a841765a5a04C0cFFBAC954F512aEdC81560`](https://explorer.testnet.chain.robinhood.com/address/0x6870a841765a5a04C0cFFBAC954F512aEdC81560) |
| USDG mock | [`0xcbd595B6254137FD79745D2Ec7E553dC6Fb8a279`](https://explorer.testnet.chain.robinhood.com/address/0xcbd595B6254137FD79745D2Ec7E553dC6Fb8a279) |
| Mock NVDAx stock token | [`0xB7C4698E4c7f115ACbfC687f9f7c04A35bb23167`](https://explorer.testnet.chain.robinhood.com/address/0xB7C4698E4c7f115ACbfC687f9f7c04A35bb23167) |
| Mock aggregator for NVDAx in USD | [`0xC16eF530FE7Cd6E0EfA725F00ab11031c929ed82`](https://explorer.testnet.chain.robinhood.com/address/0xC16eF530FE7Cd6E0EfA725F00ab11031c929ed82) |

The testnet deployment uses the documented launch values `TIMELOCK_DELAY=3600` and `FINISH_BOOTSTRAP=false`, which leaves the deployer able to invoke `SettingsTimelock` setters without a delay. That account also carries attestations for every one of the four roles (trader, LP, maker and relayer), so any flow can be exercised from it with no extra configuration.

### Robinhood Chain mainnet, 4663

There is no mainnet deployment yet. Launching there needs real addresses for `USDG`, `STOCK_TOKEN`, `STOCK_FEED` and `SEQUENCER_FEED`, because the script will not deploy mocks on chain ID 4663.

## Administration and upgrades

- At deployment `SettingsTimelock` is in bootstrap mode, letting the owner invoke setters immediately. Calling `finishBootstrap()` cannot be undone; from then on, each update must be queued with `schedule` and applied with `execute` after the configured delay elapses. A queued batch lapses if it has not been executed within 14 days of its eta, and has to be queued again.
- Pausing swaps is the guardian's one and only capability. No role exists that could freeze deposits, redemptions or the cancelling of RFQ quotes.
- There are no proxies or admin keys on `SwapRouter`, `OracleVault`, `VaultFactory` or `RfqSettler`. Upgrading means deploying fresh contracts, and each LP chooses independently whether to migrate.

## Protocol invariants

- Regardless of the regime, and for every parameter combination `SettingsTimelock` permits, neither a vault fill nor a maker fill can settle beyond the tier's oracle band.
- Redemptions from a vault are always paid in kind and pro-rata, and they go through under all circumstances, including a halted market, a guardian pause, a retired market or an expired attestation. Liquidity providers are never trapped.
- Value per share cannot decrease as a result of swaps. Rounding on share mints and burns always favours the vault.
- No fill may move a vault beyond its inventory band, and if price movement has already pushed it past the band, no fill may push it further. A preview always matches the resulting fill exactly. In practice this means the inventory-worsening side becomes one-sided rather than absorbing flow indefinitely, while the inventory-correcting side brings the vault back inside the band.
- A vault only ever reads the feed assigned to the very token it holds; wrapped tokens and derived rates play no part in pricing.
- Quotes are itemised on-chain, and the mid, spread, skew and fee captured in the fill event agree with the quote that produced them.

## Integration guidance

- Approvals from traders go to `SwapRouter`, while makers approve `RfqSettler`. Batching via Permit2 or ERC-4337 is left to a higher layer and is not part of these contracts.
- A halted market rejects deposits, since valuing what comes in requires the guarded mid. Withdrawals do not consult the oracle at all and are unaffected by market state.
- `OracleVault.quoteSwap` gives a preview that matches the eventual fill exactly. On a halted market it reverts, and the router interprets that as the vault being unavailable, allowing RFQ to keep serving the market.
- For a dry run, call `SwapRouter.previewExactIn` with the arguments you would pass to `swapExactIn`. You get back the expected output and the winning venue, with RFQ candidates and two-leg routes both supported. Three checks are skipped until execution (deadline, eligibility and the RFQ signature); every other failure surfaces in the preview just as it would in a live fill.
- A feed update that jumps further than the move cap from a recent checkpoint halts the market immediately, in the very block it lands, and that halt applies equally to previews, fills and RFQ settlement. `OracleAdapter.refresh` is permissionless. Calling it during a halt writes the halt to storage, so it survives after the move-cap window ends; lifting it then takes a `resume` from governance.

## Security disclosures

Our approach to testing, audits, the bug bounty and responsible disclosure is set out in `docs/architecture/security.md`. Please report suspected vulnerabilities privately to security@usecanopic.com and keep them out of public issues.

## Licensing

This code is released under MIT. The SPDX header in every `.sol` file across `src/`, `script/` and `test/` says so.
