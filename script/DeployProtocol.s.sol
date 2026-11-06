// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SettingsTimelock} from "../src/settings/SettingsTimelock.sol";
import {ISettingsTimelock} from "../src/interfaces/ISettingsTimelock.sol";
import {EligibilityRegistry} from "../src/eligibility/EligibilityRegistry.sol";
import {AttestationBook} from "../src/eligibility/AttestationBook.sol";
import {OracleAdapter} from "../src/oracle/OracleAdapter.sol";
import {ProtocolTreasury} from "../src/settings/ProtocolTreasury.sol";
import {VaultFactory} from "../src/venue/VaultFactory.sol";
import {RfqSettler} from "../src/venue/RfqSettler.sol";
import {SwapRouter} from "../src/venue/SwapRouter.sol";
import {AggregatorV3Interface} from "../src/interfaces/ThirdParty.sol";
import {Roles} from "../src/libraries/Types.sol";
import {MockERC20, MockStockToken, MockPriceFeed} from "../src/mocks/Mocks.sol";

/// @title DeployProtocol
/// @notice One-shot rollout of the whole Canopic stack. Targets Robinhood Chain: chain 46630 is testnet, chain 4663 is mainnet.
/// @dev Configuration via env:
///        PRIVATE_KEY                key that signs the deployment; that account starts as owner if GOV is not set
///        GOV, GUARDIAN              addresses for governance and the guardian, each falling back to the deployer
///        TIMELOCK_DELAY             how long queued changes wait, in seconds (falls back to 1 hour)
///        DEPLOY_MOCKS               permits mock dependencies; on by default everywhere except mainnet
///        USDG                       address of the quote asset; if missing and mocks are permitted, one is mocked
///        STOCK_TOKEN, STOCK_FEED    first listed stock (tier 1) and the Chainlink feed that prices it; mocked if missing and permitted
///        SEQUENCER_FEED             uptime oracle for the L2 sequencer; leave empty to deploy without the sequencer check
///        ATTESTATION_ISSUER         compliance signer approved to write attestations (deployer if omitted)
///        FINISH_BOOTSTRAP           set to "true" to end SettingsTimelock bootstrap as the final step
///      Run with:
///        forge script script/DeployProtocol.s.sol:DeployProtocol --broadcast --verify --rpc-url robinhood_testnet
contract DeployProtocol is Script {
    struct Addresses {
        address settingsTimelock;
        address eligibilityRegistry;
        address attestationBook;
        address oracleAdapter;
        address protocolTreasury;
        address vaultFactory;
        address rfqSettler;
        address swapRouter;
        address vault;
        address usdg;
        address stockToken;
        address stockFeed;
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address gov = vm.envOr("GOV", deployer);
        address guardian = vm.envOr("GUARDIAN", deployer);
        uint256 delay = vm.envOr("TIMELOCK_DELAY", uint256(1 hours));
        bool mocks = vm.envOr("DEPLOY_MOCKS", block.chainid != 4663);
        bool finish = vm.envOr("FINISH_BOOTSTRAP", false);
        address issuer = vm.envOr("ATTESTATION_ISSUER", deployer);

        Addresses memory a;
        vm.startBroadcast(pk);

        // ----- External dependencies: live addresses on mainnet, testnet falls back to mocks if none is supplied -----
        a.usdg = vm.envOr("USDG", address(0));
        a.stockToken = vm.envOr("STOCK_TOKEN", address(0));
        a.stockFeed = vm.envOr("STOCK_FEED", address(0));
        address sequencerFeed = vm.envOr("SEQUENCER_FEED", address(0));

        if (a.usdg == address(0)) {
            require(mocks, "missing USDG address");
            a.usdg = address(new MockERC20("Global Dollar (mock)", "USDG", 6));
        }
        if (a.stockToken == address(0)) {
            require(mocks, "missing STOCK_TOKEN address");
            a.stockToken = address(new MockStockToken("NVIDIA Stock Token (mock)", "NVDAx"));
        }
        if (a.stockFeed == address(0)) {
            require(mocks, "missing STOCK_FEED address");
            a.stockFeed = address(new MockPriceFeed(8, 176_40_000_000));
        }

        // ----- Core deployment -----
        // The deployer owns everything during bootstrap, and ownership is offered to `gov` as the last step.
        SettingsTimelock params = new SettingsTimelock(deployer, guardian, delay);
        EligibilityRegistry eligibility = new EligibilityRegistry(params);
        AttestationBook attestations = new AttestationBook(params);
        OracleAdapter oracle = new OracleAdapter(params);
        ProtocolTreasury fees = new ProtocolTreasury(params);
        VaultFactory factory = new VaultFactory(params, eligibility, oracle, address(fees), a.usdg);
        RfqSettler rfqSettler = new RfqSettler(params, eligibility, oracle, factory, address(fees));
        SwapRouter router = new SwapRouter(params, eligibility, factory, rfqSettler);
        factory.setRouter(address(router));

        // ----- Initial settings: bootstrap is still open, so setters are invoked directly with the documented launch values -----
        params.setEligibilityAdapter(address(attestations));
        params.setAttestationIssuer(issuer, true);
        params.setTierConfig(
            1,
            ISettingsTimelock.TierConfig({
                baseHalfSpreadBps: 10,
                maxSkewBps: 15,
                inventoryBandBps: 2000,
                oracleBandBps: 75,
                maxClip: 50_000e6,
                enabled: true
            })
        );
        params.setTierConfig(
            2,
            ISettingsTimelock.TierConfig({
                baseHalfSpreadBps: 20,
                maxSkewBps: 25,
                inventoryBandBps: 2000,
                oracleBandBps: 150,
                maxClip: 20_000e6,
                enabled: true
            })
        );
        params.setTierConfig(
            3,
            ISettingsTimelock.TierConfig({
                baseHalfSpreadBps: 40,
                maxSkewBps: 50,
                inventoryBandBps: 2000,
                oracleBandBps: 300,
                maxClip: 5_000e6,
                enabled: true
            })
        );
        params.setMarketConfig(
            a.stockToken,
            ISettingsTimelock.MarketConfig({tier: 1, dailyVolumeCap: 2_000_000e6, tvlCap: 5_000_000e6, enabled: true})
        );
        params.setRegimeParams(
            ISettingsTimelock.RegimeParams({
                extendedSpreadMulBps: 15_000,
                closedSpreadMulBps: 30_000,
                extendedClipMulBps: 7_500,
                closedClipMulBps: 5_000
            })
        );
        params.setRiskParams(ISettingsTimelock.RiskParams({sequencerGrace: 1 hours}));
        params.setFeeParams(ISettingsTimelock.FeeParams({swapFeeBps: 2, rfqFeeBps: 2, spreadShareBps: 1000}));

        // ----- Oracle setup -----
        // Pause flag and multiplier are always read from the stock token. Session status also comes from the token
        // when mocks are in use; on a real deployment it is taken from MARKET_STATUS_SOURCE.
        address statusSource = mocks ? a.stockToken : vm.envOr("MARKET_STATUS_SOURCE", address(0));
        oracle.configureFeed(
            a.stockToken,
            a.usdg,
            AggregatorV3Interface(a.stockFeed),
            uint32(vm.envOr("STALENESS_REGULAR", uint256(1 hours))),
            uint32(vm.envOr("STALENESS_EXTENDED", uint256(2 hours))),
            uint32(vm.envOr("STALENESS_CLOSED", uint256(4 days))),
            2500,
            uint32(vm.envOr("MOVE_CAP_WINDOW", uint256(1 hours))),
            200,
            statusSource,
            a.stockToken,
            a.stockToken,
            vm.envOr("STREAM_ADAPTER", address(0))
        );
        if (sequencerFeed != address(0)) oracle.setSequencerFeed(AggregatorV3Interface(sequencerFeed));

        // ----- Launch market -----
        a.vault = factory.createMarket(a.stockToken);

        // For quick testnet checks: if mocks are enabled and the deployer is the issuer, it attests itself for every role.
        if (mocks && issuer == deployer) {
            uint64 exp = uint64(block.timestamp + 365 days);
            attestations.attest(deployer, Roles.TRADER, "LT", 2, exp);
            attestations.attest(deployer, Roles.LP, "LT", 3, exp);
            attestations.attest(deployer, Roles.MAKER, "LT", 3, exp);
            attestations.attest(deployer, Roles.RELAYER, "LT", 0, exp);
        }

        if (finish) params.finishBootstrap();
        if (gov != deployer) params.transferOwnership(gov);

        vm.stopBroadcast();

        a.settingsTimelock = address(params);
        a.eligibilityRegistry = address(eligibility);
        a.attestationBook = address(attestations);
        a.oracleAdapter = address(oracle);
        a.protocolTreasury = address(fees);
        a.vaultFactory = address(factory);
        a.rfqSettler = address(rfqSettler);
        a.swapRouter = address(router);
        _write(a);
    }

    function _write(Addresses memory a) internal {
        string memory root = "canopic";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeAddress(root, "SettingsTimelock", a.settingsTimelock);
        vm.serializeAddress(root, "EligibilityRegistry", a.eligibilityRegistry);
        vm.serializeAddress(root, "AttestationBook", a.attestationBook);
        vm.serializeAddress(root, "OracleAdapter", a.oracleAdapter);
        vm.serializeAddress(root, "ProtocolTreasury", a.protocolTreasury);
        vm.serializeAddress(root, "VaultFactory", a.vaultFactory);
        vm.serializeAddress(root, "RfqSettler", a.rfqSettler);
        vm.serializeAddress(root, "SwapRouter", a.swapRouter);
        vm.serializeAddress(root, "OracleVault", a.vault);
        vm.serializeAddress(root, "USDG", a.usdg);
        vm.serializeAddress(root, "StockToken", a.stockToken);
        string memory json = vm.serializeAddress(root, "StockFeed", a.stockFeed);
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console2.log("Saved deployment addresses to", path);
        console2.log("SwapRouter", a.swapRouter);
    }
}
