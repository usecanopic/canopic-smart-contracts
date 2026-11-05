// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISettingsTimelock} from "../interfaces/ISettingsTimelock.sol";
import {IEligibilityRegistry} from "../interfaces/IEligibilityRegistry.sol";
import {OracleVault} from "./OracleVault.sol";
import {RfqSettler} from "./RfqSettler.sol";
import {VaultFactory} from "./VaultFactory.sol";
import {Types, Roles} from "../libraries/Types.sol";

/// @title SwapRouter
/// @notice The one contract through which all trading flows. Only holders of the trader role may call it. Each
///         order is compared across the market's vault and an optional signed maker quote, and the trader gets
///         the better of the two outputs. A trade from one listed token into another becomes two vault legs
///         that hop through the quote asset, both executed in the same transaction.
/// @dev The choice of venue happens on-chain as part of the swap. Vault pricing is recomputed in the same call
///      and maker signatures are validated only when funds move, which means a client has no way to force an
///      order into a fill that pays less than the vault would.
contract SwapRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    ISettingsTimelock public immutable params;
    IEligibilityRegistry public immutable eligibility;
    VaultFactory public immutable factory;
    RfqSettler public immutable rfq;
    address public immutable quoteToken;

    struct SwapParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        /// @dev Address that receives the output; the zero address means the caller is paid.
        address to;
        uint256 deadline;
        /// @dev Optional maker quote that races the vault on one-leg swaps; set `quote.maker` to zero to omit it.
        Types.MakerQuote quote;
        bytes quoteSig;
    }

    event Swapped(
        address indexed trader,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        Types.Venue venue
    );

    error Expired();
    error SwapsPaused();
    error SameToken();
    error ZeroAmount();
    error NoLiquidity();
    error Slippage(uint256 amountOut, uint256 minAmountOut);
    error QuoteMismatch();
    error QuoteNotApplicable();
    error ZeroAddress();

    constructor(
        ISettingsTimelock params_,
        IEligibilityRegistry eligibility_,
        VaultFactory factory_,
        RfqSettler rfq_
    ) {
        // A bad factory already fails on the quoteToken() call below; other zero addresses would surface at first use.
        if (address(params_) == address(0) || address(eligibility_) == address(0) || address(rfq_) == address(0)) {
            revert ZeroAddress();
        }
        params = params_;
        eligibility = eligibility_;
        factory = factory_;
        rfq = rfq_;
        quoteToken = factory_.quoteToken();
    }

    /// @notice Spends precisely `amountIn` of the input token, guarded by two caller limits, `deadline` and
    ///         `minAmountOut`. Should the market or reserves shift enough to violate either limit, the entire
    ///         transaction is rolled back.
    function swapExactIn(SwapParams calldata p) external nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > p.deadline) revert Expired();
        if (params.swapsPaused()) revert SwapsPaused();
        if (p.tokenIn == p.tokenOut) revert SameToken();
        if (p.amountIn == 0) revert ZeroAmount();
        eligibility.requireRole(msg.sender, Roles.TRADER);
        address to = p.to == address(0) ? msg.sender : p.to;
        if (to != msg.sender) eligibility.requireRole(to, Roles.TRADER);

        IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);

        Types.Venue venue;
        if (p.tokenIn == quoteToken || p.tokenOut == quoteToken) {
            (amountOut, venue) = _bestLeg(p, p.tokenIn == quoteToken, to);
        } else {
            // The quote asset is on neither side, so the trade hops through it as two vault legs in one call.
            // A maker quote has no meaning on this route, so supplying one is treated as a mistake and reverts.
            if (p.quote.maker != address(0)) revert QuoteNotApplicable();
            uint256 quoteOut = _vaultSwap(p.tokenIn, false, p.amountIn, address(this));
            amountOut = _vaultSwap(p.tokenOut, true, quoteOut, to);
            venue = Types.Venue.Vault;
        }

        if (amountOut < p.minAmountOut) revert Slippage(amountOut, p.minAmountOut);
        emit Swapped(msg.sender, p.tokenIn, p.tokenOut, p.amountIn, amountOut, venue);
    }

    /// @notice Read-only rehearsal of `swapExactIn` using today's balances and prices. It returns the output the trader
    ///         would receive and the venue that would be chosen, covering maker quotes and the two-leg path alike.
    ///         Failures use the same errors a live swap would raise, letting a client size and route with a single
    ///         call. Role checks, the deadline and the maker's signature are skipped; only the real swap enforces them.
    function previewExactIn(SwapParams calldata p) external view returns (uint256 amountOut, Types.Venue venue) {
        if (params.swapsPaused()) revert SwapsPaused();
        if (p.tokenIn == p.tokenOut) revert SameToken();
        if (p.amountIn == 0) revert ZeroAmount();

        if (p.tokenIn == quoteToken || p.tokenOut == quoteToken) {
            (, uint256 vaultOut, uint256 rfqNet) = _priceLeg(p, p.tokenIn == quoteToken);
            if (rfqNet > vaultOut) return (rfqNet, Types.Venue.Rfq);
            if (vaultOut == 0) revert NoLiquidity();
            return (vaultOut, Types.Venue.Vault);
        }

        if (p.quote.maker != address(0)) revert QuoteNotApplicable();
        uint256 quoteOut = _vaultQuote(p.tokenIn, false, p.amountIn);
        return (_vaultQuote(p.tokenOut, true, quoteOut), Types.Venue.Vault);
    }

    // ---------------------------------------------------------------------
    // Internal routing
    // ---------------------------------------------------------------------

    /// @dev Fills a one-leg trade wherever the trader comes out ahead. The maker quote is used when it pays
    ///      more than the vault; failing that the vault fills, and if neither is available the call reverts.
    function _bestLeg(SwapParams calldata p, bool buyToken, address to)
        internal
        returns (uint256 amountOut, Types.Venue venue)
    {
        (address vault, uint256 vaultOut, uint256 rfqNet) = _priceLeg(p, buyToken);

        if (rfqNet > vaultOut) {
            IERC20(p.tokenIn).forceApprove(address(rfq), p.amountIn);
            amountOut = rfq.settle(p.quote, p.quoteSig, msg.sender, to);
            venue = Types.Venue.Rfq;
        } else if (vaultOut > 0) {
            amountOut = _vaultSwapAt(vault, buyToken, p.amountIn, to);
            venue = Types.Venue.Vault;
        } else {
            revert NoLiquidity();
        }
    }

    /// @dev Computes the pair of outputs that decide the venue. When the market has no vault, or its quote
    ///      reverts (a halt, for instance), the vault side is counted as zero and a maker may still fill.
    function _priceLeg(SwapParams calldata p, bool buyToken)
        internal
        view
        returns (address vault, uint256 vaultOut, uint256 rfqNet)
    {
        vault = factory.vaultOf(buyToken ? p.tokenOut : p.tokenIn);
        if (vault != address(0)) {
            try OracleVault(vault).quoteSwap(buyToken, p.amountIn) returns (uint256 out, Types.Breakdown memory) {
                vaultOut = out;
            } catch {}
        }

        if (p.quote.maker != address(0)) {
            if (p.quote.tokenIn != p.tokenIn || p.quote.tokenOut != p.tokenOut || p.quote.amountIn != p.amountIn) {
                revert QuoteMismatch();
            }
            // Between the moment of quoting and inclusion, the quote may expire, its nonce may be used or
            // cancelled, or the maker may lose its role, none of which the caller controls. Any of these
            // simply drops the quote and leaves the vault as the only venue. Signature validity is not
            // checked at this stage; RfqSettler refuses invalid signatures during settlement.
            bool usable = block.timestamp <= p.quote.expiry && rfq.nonceUsable(p.quote.maker, p.quote.nonce)
                && eligibility.isEligible(p.quote.maker, Roles.MAKER);
            if (usable) {
                // Whichever direction the trade goes, the maker fee is taken in the quote asset. For buys the
                // maker simply receives less input and the trader keeps every unit of amountOut, while for sells
                // the fee is subtracted from what the trader receives. The figure weighed against the vault
                // is therefore always the net amount that reaches the trader.
                rfqNet = buyToken
                    ? p.quote.amountOut
                    : p.quote.amountOut - p.quote.amountOut * params.feeParams().rfqFeeBps / Types.BPS;
            }
        }
    }

    /// @dev Prices one vault leg of the two-leg preview; any revert from the vault propagates, as in a real swap.
    function _vaultQuote(address base, bool buyToken, uint256 amountIn) internal view returns (uint256 out) {
        address vault = factory.vaultOf(base);
        if (vault == address(0)) revert NoLiquidity();
        (out,) = OracleVault(vault).quoteSwap(buyToken, amountIn);
    }

    function _vaultSwap(address base, bool buyToken, uint256 amountIn, address to) internal returns (uint256) {
        address vault = factory.vaultOf(base);
        if (vault == address(0)) revert NoLiquidity();
        return _vaultSwapAt(vault, buyToken, amountIn, to);
    }

    function _vaultSwapAt(address vault, bool buyToken, uint256 amountIn, address to) internal returns (uint256) {
        IERC20(buyToken ? quoteToken : address(OracleVault(vault).token())).forceApprove(vault, amountIn);
        return OracleVault(vault).swap(buyToken, amountIn, to);
    }
}
