// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISettingsTimelock} from "../interfaces/ISettingsTimelock.sol";
import {IEligibilityRegistry} from "../interfaces/IEligibilityRegistry.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {VaultFactory} from "./VaultFactory.sol";
import {Types, Roles} from "../libraries/Types.sol";

/// @title OracleVault
/// @notice Liquidity pool, funded by LPs, that pairs a single listed token with the quote asset and quotes a bid
///         and an ask on either side of the guarded oracle mid. Price discovery comes from the oracle alone, never
///         from reserves; the inventory position merely tilts the spread. Shares represent a claim on value, and
///         redemptions always pay out pro rata in the underlying assets, which keeps LP funds retrievable during
///         a pause or a halt.
/// @dev The SwapRouter is the sole caller allowed to swap. New shares are priced off the mid, which ties deposits
///      to a healthy oracle; withdrawals, by contrast, never read it.
contract OracleVault is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    ISettingsTimelock public immutable params;
    IEligibilityRegistry public immutable eligibility;
    IOracleAdapter public immutable oracle;
    VaultFactory public immutable factory;
    address public immutable feeTreasury;
    IERC20 public immutable quoteToken;
    IERC20 public immutable token;
    uint8 public immutable tokenDec;
    uint8 public immutable quoteDec;
    /// @dev Multiplier converting the first deposit's value (in quote units) into shares with 18 decimals.
    uint256 internal immutable shareScale;

    /// @notice Shares locked away for good on a vault's first deposit, worth a tiny fraction of a cent. With supply
    ///         unable to fall below this, nobody can shrink it to a few units and then inflate the value per share
    ///         with a direct transfer, which would otherwise let rounding take value from the next depositor.
    uint256 public constant LOCKED_SHARES = 1e15;
    address internal constant LOCKED_SHARES_HOLDER = address(0xdEaD);

    /// @notice Per UTC day index, the quote-token notional already traded, compared with the market's daily cap.
    mapping(uint256 => uint256) public dailyVolume;

    struct SwapQuote {
        uint256 amountOut;
        /// @dev Order size valued at the mid in quote-token units; both the clip and the daily cap are measured in it.
        uint256 notional;
        uint256 feeAmount;
        uint256 protocolSpread;
        Types.Breakdown breakdown;
    }

    event Deposited(
        address indexed lp, address indexed receiver, uint256 quoteAmount, uint256 tokenAmount, uint256 shares
    );
    event Withdrawn(address indexed lp, address indexed receiver, uint256 shares, uint256 quoteOut, uint256 tokenOut);
    event VaultSwap(
        address indexed to,
        bool buyToken,
        uint256 amountIn,
        uint256 amountOut,
        uint256 mid,
        uint16 halfSpreadBps,
        int16 skewBps,
        uint16 feeBps,
        Types.Session session
    );

    error NotRouter();
    error MarketNotListed();
    error MarketHalted();
    error SwapsPaused();
    error NoLiquidity();
    error ZeroAmount();
    error ZeroShares();
    error ZeroAddress();
    error InvalidReceiver();
    error Slippage(uint256 shares, uint256 minShares);
    error WithdrawSlippage(uint256 quoteOut, uint256 tokenOut);
    error BandExceeded();
    error ClipExceeded(uint256 notional, uint256 clip);
    error InsufficientInventory(uint256 needed, uint256 available);
    error DailyCapExceeded();
    error TvlCapExceeded();
    error InventoryBandExceeded();

    modifier onlyRouter() {
        if (msg.sender != factory.router()) revert NotRouter();
        _;
    }

    constructor(
        ISettingsTimelock params_,
        IEligibilityRegistry eligibility_,
        IOracleAdapter oracle_,
        address feeTreasury_,
        address quoteToken_,
        address token_,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {
        params = params_;
        eligibility = eligibility_;
        oracle = oracle_;
        factory = VaultFactory(msg.sender);
        feeTreasury = feeTreasury_;
        quoteToken = IERC20(quoteToken_);
        token = IERC20(token_);
        tokenDec = IERC20Metadata(token_).decimals();
        quoteDec = IERC20Metadata(quoteToken_).decimals();
        shareScale = 10 ** (18 - quoteDec);
    }

    // ---------------------------------------------------------------------
    // Adding and removing liquidity
    // ---------------------------------------------------------------------

    /// @notice Accepts the quote asset, the listed token, or any combination. The contribution is valued at the
    ///         guarded mid and turned into shares at today's value per share. `minShares` works like the
    ///         `minAmountOut` of a swap: should the mid shift between signing and inclusion so that fewer shares
    ///         would be minted, the transaction reverts.
    function deposit(uint256 quoteAmount, uint256 tokenAmount, uint256 minShares, address receiver)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (quoteAmount == 0 && tokenAmount == 0) revert ZeroAmount();
        // Minting to address zero always fails, but only later and as a role error about address zero, which
        // reads like an attestation problem rather than a missing receiver.
        if (receiver == address(0)) revert ZeroAddress();
        eligibility.requireRole(msg.sender, Roles.LP);
        if (receiver != msg.sender) eligibility.requireRole(receiver, Roles.LP);

        uint256 mid = _liveMid();
        uint256 value = quoteAmount + tokenAmount * mid / 10 ** tokenDec;
        uint256 total = _totalValue(mid);

        ISettingsTimelock.MarketConfig memory mkt = params.marketConfig(address(token));
        if (!mkt.enabled || !params.tierConfig(mkt.tier).enabled) revert MarketNotListed();
        if (total + value > mkt.tvlCap) revert TvlCapExceeded();

        uint256 supply = totalSupply();
        shares = _sharesFor(value, supply, total);
        if (shares == 0) revert ZeroShares();
        if (shares < minShares) revert Slippage(shares, minShares);

        if (quoteAmount != 0) quoteToken.safeTransferFrom(msg.sender, address(this), quoteAmount);
        if (tokenAmount != 0) token.safeTransferFrom(msg.sender, address(this), tokenAmount);
        if (supply == 0) _mint(LOCKED_SHARES_HOLDER, LOCKED_SHARES);
        _mint(receiver, shares);
        emit Deposited(msg.sender, receiver, quoteAmount, tokenAmount, shares);
    }

    /// @notice Redeems shares for a pro rata slice of every asset in the vault. Nothing gates it on purpose:
    ///         there is no role check, no pause check and no oracle read, since holding the shares already
    ///         confers the right to leave.
    function withdraw(uint256 shares, address receiver)
        external
        nonReentrant
        returns (uint256 quoteOut, uint256 tokenOut)
    {
        return _withdraw(shares, receiver);
    }

    /// @notice Same as `withdraw`, plus a floor on each asset received. A pro rata exit is always fair by value,
    ///         but a swap landing just before it can change the asset split; an LP who requires a minimum amount
    ///         of either asset passes those floors here, and falling short of one undoes the whole redemption.
    function withdrawWithMinimums(uint256 shares, address receiver, uint256 minQuoteOut, uint256 minTokenOut)
        external
        nonReentrant
        returns (uint256 quoteOut, uint256 tokenOut)
    {
        (quoteOut, tokenOut) = _withdraw(shares, receiver);
        if (quoteOut < minQuoteOut || tokenOut < minTokenOut) revert WithdrawSlippage(quoteOut, tokenOut);
    }

    function _withdraw(uint256 shares, address receiver) internal returns (uint256 quoteOut, uint256 tokenOut) {
        if (shares == 0) revert ZeroShares();
        // Many ERC-20 tokens will transfer to address(0) without complaint, destroying the funds. A forgotten
        // receiver would therefore quietly lose the LP's assets, so it is rejected here.
        if (receiver == address(0)) revert ZeroAddress();
        // Paying the vault itself would burn the LP's shares and leave their assets in the pool, quietly handing
        // that value to the remaining LPs.
        if (receiver == address(this)) revert InvalidReceiver();
        (quoteOut, tokenOut) = previewWithdraw(shares);
        _burn(msg.sender, shares);
        if (quoteOut != 0) quoteToken.safeTransfer(receiver, quoteOut);
        if (tokenOut != 0) token.safeTransfer(receiver, tokenOut);
        emit Withdrawn(msg.sender, receiver, shares, quoteOut, tokenOut);
    }

    // ---------------------------------------------------------------------
    // Trading (callable by the SwapRouter alone)
    // ---------------------------------------------------------------------

    /// @notice Simulates a swap on current state. It reverts when the market is halted or a limit would be hit;
    ///         the router treats such a revert as the vault opting out of the trade, not as a failure, which
    ///         leaves the RFQ route free to fill the order.
    function quoteSwap(bool buyToken, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, Types.Breakdown memory breakdown)
    {
        SwapQuote memory s = _price(oracle.quote(address(token)), buyToken, amountIn);
        return (s.amountOut, s.breakdown);
    }

    /// @notice Executes the swap: takes `amountIn` of the input asset from the router and delivers the output to
    ///         `to`. The ProtocolTreasury receives the itemised fee in the same call, along with the protocol share
    ///         of the spread.
    function swap(bool buyToken, uint256 amountIn, address to) external onlyRouter nonReentrant returns (uint256) {
        // `refresh` advances the move-cap checkpoint; a jump beyond the cap halts the market rather than trading.
        IOracleAdapter.Quote memory q = oracle.refresh(address(token));
        SwapQuote memory s = _price(q, buyToken, amountIn);
        dailyVolume[block.timestamp / 1 days] += s.notional;

        if (buyToken) {
            quoteToken.safeTransferFrom(msg.sender, address(this), amountIn);
            quoteToken.safeTransfer(feeTreasury, s.feeAmount + s.protocolSpread);
            token.safeTransfer(to, s.amountOut);
        } else {
            token.safeTransferFrom(msg.sender, address(this), amountIn);
            quoteToken.safeTransfer(to, s.amountOut);
            quoteToken.safeTransfer(feeTreasury, s.feeAmount + s.protocolSpread);
        }

        emit VaultSwap(
            to,
            buyToken,
            amountIn,
            s.amountOut,
            s.breakdown.mid,
            s.breakdown.halfSpreadBps,
            s.breakdown.skewBps,
            s.breakdown.feeBps,
            s.breakdown.session
        );
        return s.amountOut;
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Shares that depositing these amounts would mint at this moment. Like `deposit`, it reverts when the
    ///         oracle cannot be used, though it leaves out the role and cap checks that only a real deposit runs.
    function previewDeposit(uint256 quoteAmount, uint256 tokenAmount) external view returns (uint256) {
        uint256 mid = _liveMid();
        uint256 value = quoteAmount + tokenAmount * mid / 10 ** tokenDec;
        uint256 supply = totalSupply();
        return _sharesFor(value, supply, supply == 0 ? 0 : _totalValue(mid));
    }

    /// @notice Assets that redeeming `shares` would pay out right now. Like `withdraw`, it looks only at balances
    ///         and performs neither an oracle read nor a role check.
    function previewWithdraw(uint256 shares) public view returns (uint256 quoteOut, uint256 tokenOut) {
        uint256 supply = totalSupply();
        if (supply == 0) return (0, 0);
        quoteOut = quoteToken.balanceOf(address(this)) * shares / supply;
        tokenOut = token.balanceOf(address(this)) * shares / supply;
    }

    /// @notice Combined worth of both balances in quote units, using the present guarded mid. Fails if the oracle is
    ///         unusable.
    function totalValue() external view returns (uint256) {
        return _totalValue(_liveMid());
    }

    /// @notice How much quote-token notional today's volume cap still allows. Since pricing refuses any trade that
    ///         would overshoot the cap, integrators should size orders off this value instead of trial quoting.
    function remainingDailyCap() external view returns (uint256) {
        uint256 cap = params.marketConfig(address(token)).dailyVolumeCap;
        uint256 used = dailyVolume[block.timestamp / 1 days];
        return used >= cap ? 0 : cap - used;
    }

    /// @notice Value in quote units of one full share (1e18 units) at the present guarded mid; LP dashboards chart
    ///         this number to show returns. When the supply is zero it gives back the starting rate. Fails when
    ///         the oracle cannot be used.
    function pricePerShare() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18 / shareScale;
        return _totalValue(_liveMid()) * 1e18 / supply;
    }

    /// @notice How much more value the TVL cap can absorb, priced in quote units off the present mid. Deposits that
    ///         exceed it revert, so interfaces can read this to size a deposit in advance instead of finding the
    ///         ceiling by trial and error. Fails when the oracle cannot be used.
    function remainingTvlCap() external view returns (uint256) {
        uint256 cap = params.marketConfig(address(token)).tvlCap;
        uint256 total = _totalValue(_liveMid());
        return total >= cap ? 0 : cap - total;
    }

    /// @notice Share of total vault value held as the listed token, in bps; the target split of 50/50 equals 5_000.
    function inventoryRatioBps() external view returns (uint256) {
        uint256 mid = _liveMid();
        uint256 total = _totalValue(mid);
        if (total == 0) return Types.TARGET_RATIO_BPS;
        return token.balanceOf(address(this)) * mid / 10 ** tokenDec * Types.BPS / total;
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /// @dev The complete pricing sequence lives here: base spread scaled by session regime, signed inventory
    ///      skew, the fee as its own line, and finally the clip, oracle band and daily cap checks. All inputs
    ///      are readable on-chain, so anyone can reproduce a quote off-chain and get the exact same result.
    function _price(IOracleAdapter.Quote memory q, bool buyToken, uint256 amountIn)
        internal
        view
        returns (SwapQuote memory s)
    {
        if (amountIn == 0) revert ZeroAmount();
        // The router checks the global swap pause, and the vault checks it again here. Previews therefore never
        // show an unexecutable quote, and the vault stays shut even if some router omitted the check.
        if (params.swapsPaused()) revert SwapsPaused();
        if (q.paused || q.stale || q.sequencerGrace) revert MarketHalted();

        ISettingsTimelock.MarketConfig memory mkt = params.marketConfig(address(token));
        if (!mkt.enabled) revert MarketNotListed();
        // A market only counts as listed while its tier is enabled too. Because the SettingsTimelock will not
        // assign a market to a disabled tier, switching a tier off removes all of its markets in one step.
        ISettingsTimelock.TierConfig memory tier = params.tierConfig(mkt.tier);
        if (!tier.enabled) revert MarketNotListed();
        ISettingsTimelock.FeeParams memory fee = params.feeParams();
        (uint256 spreadMul, uint256 clipMul) = _regimeMultipliers(q.session);

        uint256 quoteBal = quoteToken.balanceOf(address(this));
        uint256 tokenBal = token.balanceOf(address(this));
        uint256 tokenValue = tokenBal * q.price / 10 ** tokenDec;
        uint256 total = quoteBal + tokenValue;
        if (total == 0) revert NoLiquidity();

        // When skew is above zero, the vault is overweight the token relative to its 50% goal. Trades that bring the
        // vault back toward the target get a tighter price, trades that move it further away get a wider one, and the
        // size of the tilt is bounded at `maxSkewBps` in either direction.
        int256 skew = int256(uint256(tier.maxSkewBps))
            * (int256(tokenValue * Types.BPS / total) - int256(Types.TARGET_RATIO_BPS))
            / int256(uint256(tier.inventoryBandBps));
        if (skew > int256(uint256(tier.maxSkewBps))) skew = int256(uint256(tier.maxSkewBps));
        if (skew < -int256(uint256(tier.maxSkewBps))) skew = -int256(uint256(tier.maxSkewBps));

        int256 half = int256(uint256(tier.baseHalfSpreadBps) * spreadMul / Types.BPS) + (buyToken ? -skew : skew);
        if (half < 0) half = 0;
        uint256 halfSpread = uint256(half);
        if (halfSpread + fee.swapFeeBps > tier.oracleBandBps) revert BandExceeded();

        // These size limits need nothing but the input amount and the mid, so they run first. That way an
        // oversized order reverts with a clip error instead of possibly overflowing the balance arithmetic below.
        s.notional = buyToken ? amountIn : amountIn * q.price / 10 ** tokenDec;
        uint256 clip = uint256(tier.maxClip) * clipMul / Types.BPS;
        if (s.notional > clip) revert ClipExceeded(s.notional, clip);
        if (dailyVolume[block.timestamp / 1 days] + s.notional > mkt.dailyVolumeCap) revert DailyCapExceeded();

        // Balances after the trade are derived together with the price, which makes `quoteSwap` and `swap` match
        // down to the wei, inventory band check included. When the vault cannot cover the payout, a specific
        // error fires immediately instead of leaving the failure to a later token transfer.
        uint256 newQuoteBal;
        uint256 newTokenVal;
        if (buyToken) {
            s.feeAmount = amountIn * fee.swapFeeBps / Types.BPS;
            uint256 net = amountIn - s.feeAmount;
            uint256 askPrice = q.price * (Types.BPS + halfSpread) / Types.BPS;
            s.amountOut = net * 10 ** tokenDec / askPrice;
            if (s.amountOut > tokenBal) revert InsufficientInventory(s.amountOut, tokenBal);
            uint256 midValue = s.amountOut * q.price / 10 ** tokenDec;
            s.protocolSpread = (net - midValue) * fee.spreadShareBps / Types.BPS;
            newQuoteBal = quoteBal + amountIn - s.feeAmount - s.protocolSpread;
            newTokenVal = tokenValue - midValue;
        } else {
            uint256 midValue = s.notional;
            uint256 bidPrice = q.price * (Types.BPS - halfSpread) / Types.BPS;
            uint256 gross = amountIn * bidPrice / 10 ** tokenDec;
            s.feeAmount = gross * fee.swapFeeBps / Types.BPS;
            s.amountOut = gross - s.feeAmount;
            s.protocolSpread = (midValue - gross) * fee.spreadShareBps / Types.BPS;
            // Although the fee is subtracted from `gross`, it still exits the vault alongside the spread share.
            // In total the quote balance therefore falls by `gross` plus the spread share, matching what `swap` sends.
            if (gross + s.protocolSpread > quoteBal) revert InsufficientInventory(gross + s.protocolSpread, quoteBal);
            newQuoteBal = quoteBal - gross - s.protocolSpread;
            newTokenVal = tokenValue + midValue;
        }

        // Fills that would leave the vault outside the inventory band are refused, except when they shrink the drift
        // (for instance once a market move has already left the vault beyond the band). While out of band the vault
        // therefore only quotes the corrective side, so ordinary flow brings it back in with no new LP deposits needed.
        uint256 newTotal = newQuoteBal + newTokenVal;
        if (newTotal == 0) revert NoLiquidity();
        uint256 drift = _drift(newTokenVal * Types.BPS / newTotal);
        if (drift > tier.inventoryBandBps && drift >= _drift(tokenValue * Types.BPS / total)) {
            revert InventoryBandExceeded();
        }

        s.breakdown = Types.Breakdown({
            mid: q.price,
            halfSpreadBps: uint16(halfSpread),
            skewBps: int16(skew),
            feeBps: fee.swapFeeBps,
            session: q.session
        });
    }

    /// @dev Shares due to the depositor. The first deposit pays for `LOCKED_SHARES` out of its own mint, and one too
    ///      small to cover them yields zero, which `deposit` refuses.
    function _sharesFor(uint256 value, uint256 supply, uint256 total) internal view returns (uint256) {
        if (supply != 0) return value * supply / total;
        uint256 gross = value * shareScale;
        return gross > LOCKED_SHARES ? gross - LOCKED_SHARES : 0;
    }

    /// @dev How far, in bps and without sign, a token value ratio sits from the 50% target.
    function _drift(uint256 ratioBps) internal pure returns (uint256) {
        return ratioBps > Types.TARGET_RATIO_BPS ? ratioBps - Types.TARGET_RATIO_BPS : Types.TARGET_RATIO_BPS - ratioBps;
    }

    function _regimeMultipliers(Types.Session session) internal view returns (uint256 spreadMul, uint256 clipMul) {
        ISettingsTimelock.RegimeParams memory r = params.regimeParams();
        if (session == Types.Session.Regular) return (Types.BPS, Types.BPS);
        if (session == Types.Session.Extended) return (r.extendedSpreadMulBps, r.extendedClipMulBps);
        return (r.closedSpreadMulBps, r.closedClipMulBps);
    }

    function _liveMid() internal view returns (uint256) {
        IOracleAdapter.Quote memory q = oracle.quote(address(token));
        if (q.paused || q.stale || q.sequencerGrace) revert MarketHalted();
        return q.price;
    }

    function _totalValue(uint256 mid) internal view returns (uint256) {
        return quoteToken.balanceOf(address(this)) + token.balanceOf(address(this)) * mid / 10 ** tokenDec;
    }

    /// @dev Moving shares between holders needs the LP role on the receiving side. Minting and burning skip this
    ///      check, so an expired attestation can never block an LP's exit.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) eligibility.requireRole(to, Roles.LP);
        super._update(from, to, value);
    }
}
