// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SettingsTimelock} from "../src/settings/SettingsTimelock.sol";
import {ISettingsTimelock} from "../src/interfaces/ISettingsTimelock.sol";
import {EligibilityRegistry} from "../src/eligibility/EligibilityRegistry.sol";
import {AttestationBook} from "../src/eligibility/AttestationBook.sol";
import {OracleAdapter} from "../src/oracle/OracleAdapter.sol";
import {ProtocolTreasury} from "../src/settings/ProtocolTreasury.sol";
import {VaultFactory} from "../src/venue/VaultFactory.sol";
import {OracleVault} from "../src/venue/OracleVault.sol";
import {RfqSettler} from "../src/venue/RfqSettler.sol";
import {SwapRouter} from "../src/venue/SwapRouter.sol";
import {AggregatorV3Interface} from "../src/interfaces/ThirdParty.sol";
import {Types, Roles} from "../src/libraries/Types.sol";
import {MockERC20, MockStockToken, MockPriceFeed} from "../src/mocks/Mocks.sol";

/// @notice Common parent for every test contract. Deploys the full protocol on top of mock tokens and price feeds,
///         opens two markets, then funds two LPs, one trader and one maker and sets their allowances.
abstract contract Fixture is Test {
    uint256 internal constant NVDA_PRICE_8 = 176_40_000_000; // raw 8-decimal feed value for a 176.40 price
    uint256 internal constant SPY_PRICE_8 = 645_20_000_000; // raw 8-decimal feed value for a 645.20 price
    uint256 internal constant NVDA_MID = 176_400_000; // NVDAx mid price: USDG (6 decimals) paid per 1e18 token units
    uint256 internal constant SPY_MID = 645_200_000;

    address internal gov = makeAddr("gov");
    address internal guardian = makeAddr("guardian");
    address internal issuer = makeAddr("issuer");
    address internal outsider = makeAddr("outsider");

    uint256 internal traderPk = 0x7A0DE;
    uint256 internal makerPk = 0x3A6E5;
    address internal trader = vm.addr(traderPk);
    address internal maker = vm.addr(makerPk);
    address internal lp1 = makeAddr("lp1");
    address internal lp2 = makeAddr("lp2");

    SettingsTimelock internal params;
    EligibilityRegistry internal eligibility;
    AttestationBook internal attestations;
    OracleAdapter internal oracle;
    ProtocolTreasury internal fees;
    VaultFactory internal factory;
    RfqSettler internal rfq;
    SwapRouter internal router;
    OracleVault internal nvdaVault;
    OracleVault internal spyVault;

    MockERC20 internal usdg;
    MockStockToken internal nvda;
    MockStockToken internal spy;
    MockPriceFeed internal nvdaFeed;
    MockPriceFeed internal spyFeed;
    MockPriceFeed internal sequencer;

    function setUp() public virtual {
        // Pin block time to a Wednesday at 16:00 UTC. Mock stock tokens report a regular session around the clock anyway.
        vm.warp(1_790_000_000 + 2 days + 16 hours - (1_790_000_000 % 1 days));
        _deploy();
        _configure();
        _fund();
    }

    function _deploy() internal {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        nvda = new MockStockToken("NVIDIA Stock Token", "NVDAx");
        spy = new MockStockToken("SPDR S&P 500 Stock Token", "SPYx");
        nvdaFeed = new MockPriceFeed(8, int256(NVDA_PRICE_8));
        spyFeed = new MockPriceFeed(8, int256(SPY_PRICE_8));
        sequencer = new MockPriceFeed(0, 0);

        params = new SettingsTimelock(gov, guardian, 1 days);
        eligibility = new EligibilityRegistry(params);
        attestations = new AttestationBook(params);
        oracle = new OracleAdapter(params);
        fees = new ProtocolTreasury(params);
        factory = new VaultFactory(params, eligibility, oracle, address(fees), address(usdg));
        rfq = new RfqSettler(params, eligibility, oracle, factory, address(fees));
        router = new SwapRouter(params, eligibility, factory, rfq);
    }

    function _configure() internal {
        vm.startPrank(gov);
        factory.setRouter(address(router));
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
        params.setMarketConfig(
            address(nvda),
            ISettingsTimelock.MarketConfig({tier: 1, dailyVolumeCap: 2_000_000e6, tvlCap: 5_000_000e6, enabled: true})
        );
        params.setMarketConfig(
            address(spy),
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

        _configureFeed(address(nvda), address(nvdaFeed));
        _configureFeed(address(spy), address(spyFeed));
        oracle.setSequencerFeed(AggregatorV3Interface(address(sequencer)));

        nvdaVault = OracleVault(factory.createMarket(address(nvda)));
        spyVault = OracleVault(factory.createMarket(address(spy)));
        vm.stopPrank();

        vm.startPrank(issuer);
        uint64 exp = uint64(block.timestamp + 365 days);
        attestations.attest(trader, Roles.TRADER, "LT", 2, exp);
        attestations.attest(lp1, Roles.LP, "LT", 3, exp);
        attestations.attest(lp2, Roles.LP, "DE", 3, exp);
        attestations.attest(maker, Roles.MAKER, "IE", 3, exp);
        vm.stopPrank();

        // Mark the L2 sequencer healthy, having come back online seven days earlier.
        sequencer.setWithTimestamps(0, block.timestamp - 7 days, block.timestamp);
    }

    function _configureFeed(address token, address feed) internal {
        oracle.configureFeed(
            token,
            address(usdg),
            AggregatorV3Interface(feed),
            1 hours,
            2 hours,
            4 days,
            2500,
            1 hours,
            200,
            token,
            token,
            token,
            address(0)
        );
    }

    function _fund() internal {
        usdg.mint(lp1, 10_000_000e6);
        usdg.mint(lp2, 10_000_000e6);
        usdg.mint(trader, 1_000_000e6);
        usdg.mint(maker, 1_000_000e6);
        nvda.mint(lp1, 100_000e18);
        nvda.mint(lp2, 100_000e18);
        nvda.mint(trader, 1_000e18);
        nvda.mint(maker, 10_000e18);
        spy.mint(lp1, 100_000e18);
        spy.mint(trader, 100e18);

        address[2] memory lps = [lp1, lp2];
        for (uint256 i = 0; i < lps.length; i++) {
            vm.startPrank(lps[i]);
            usdg.approve(address(nvdaVault), type(uint256).max);
            nvda.approve(address(nvdaVault), type(uint256).max);
            usdg.approve(address(spyVault), type(uint256).max);
            spy.approve(address(spyVault), type(uint256).max);
            vm.stopPrank();
        }
        vm.startPrank(trader);
        usdg.approve(address(router), type(uint256).max);
        nvda.approve(address(router), type(uint256).max);
        spy.approve(address(router), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(maker);
        usdg.approve(address(rfq), type(uint256).max);
        nvda.approve(address(rfq), type(uint256).max);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Test utilities
    // ---------------------------------------------------------------------

    /// @dev Makes lp1 supply 500,000 USDG plus an equal value of the stock token, priced at `mid`.
    function _seed(OracleVault vault, uint256 mid) internal returns (uint256 shares) {
        uint256 tokenAmount = 500_000e6 * 1e18 / mid;
        vm.prank(lp1);
        shares = vault.deposit(500_000e6, tokenAmount, 0, lp1);
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256) {
        return _swapAs(trader, tokenIn, tokenOut, amountIn, 0);
    }

    function _swapAs(address who, address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        internal
        returns (uint256)
    {
        vm.prank(who);
        return router.swapExactIn(_params(tokenIn, tokenOut, amountIn, minOut));
    }

    function _params(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        internal
        view
        returns (SwapRouter.SwapParams memory p)
    {
        p.tokenIn = tokenIn;
        p.tokenOut = tokenOut;
        p.amountIn = amountIn;
        p.minAmountOut = minOut;
        p.deadline = block.timestamp + 5 minutes;
    }

    function _makerQuote(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, uint256 nonce)
        internal
        view
        returns (Types.MakerQuote memory q)
    {
        q = Types.MakerQuote({
            maker: maker,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            amountOut: amountOut,
            taker: address(0),
            expiry: uint40(block.timestamp + 30 seconds),
            nonce: nonce
        });
    }

    function _sign(Types.MakerQuote memory q) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, rfq.quoteDigest(q));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Independent buy-side calculation. Net input (after a 2 bps fee) is converted at an ask equal to mid times one plus the half-spread.
    function _expectedBuyOut(uint256 amountIn, uint256 mid, uint256 halfSpreadBps) internal pure returns (uint256) {
        uint256 net = amountIn - amountIn * 2 / 10_000;
        uint256 ask = mid * (10_000 + halfSpreadBps) / 10_000;
        return net * 1e18 / ask;
    }
}
