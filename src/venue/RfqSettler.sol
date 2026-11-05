// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ISettingsTimelock} from "../interfaces/ISettingsTimelock.sol";
import {IEligibilityRegistry} from "../interfaces/IEligibilityRegistry.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {VaultFactory} from "./VaultFactory.sol";
import {Types, Roles} from "../libraries/Types.sol";

/// @title RfqSettler
/// @notice Settles signed maker quotes atomically. Makers sign EIP-712 quotes off-chain at no cost. Once a quote wins
///         the route, three transfers happen together: the maker collects the trader's input, the recipient collects
///         the maker's output, and the treasury collects its fee. Tokens move wallet to wallet and are never
///         custodied here.
/// @dev Every fill has to land within the market's oracle band. A stolen maker key can therefore do no more harm than
///      an aggressive yet honest maker could do on purpose. Nothing can pause nonce cancellation. Smart-contract
///      wallets may quote as makers, since signatures are verified via EIP-1271.
contract RfqSettler is EIP712 {
    using SafeERC20 for IERC20;

    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "MakerQuote(address maker,address tokenIn,address tokenOut,uint256 amountIn,uint256 amountOut,"
        "address taker,uint40 expiry,uint256 nonce)"
    );

    ISettingsTimelock public immutable params;
    IEligibilityRegistry public immutable eligibility;
    IOracleAdapter public immutable oracle;
    VaultFactory public immutable factory;
    address public immutable feeTreasury;
    address public immutable quoteToken;

    mapping(address => mapping(uint256 => bool)) public nonceUsed;
    /// @notice Minimum valid nonce for each maker; anything beneath it is dead, whether or not it was ever filled.
    mapping(address => uint256) public minNonce;

    event RfqFilled(
        address indexed maker,
        address indexed taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 netOut,
        uint256 fee,
        uint256 mid
    );
    event NonceCancelled(address indexed maker, uint256 nonce);
    event MinNonceRaised(address indexed maker, uint256 minNonce);

    error NotRouter();
    error QuoteExpired();
    error WrongTaker();
    error SelfTrade();
    error NonceAlreadyUsed();
    error NonceTooLow();
    error BadSignature();
    error QuoteAssetRequired();
    error MarketNotListed();
    error MarketHalted();
    error BandExceeded(uint256 implied, uint256 mid);
    error ZeroAmount();
    error ZeroAddress();

    modifier onlyRouter() {
        if (msg.sender != factory.router()) revert NotRouter();
        _;
    }

    constructor(
        ISettingsTimelock params_,
        IEligibilityRegistry eligibility_,
        IOracleAdapter oracle_,
        VaultFactory factory_,
        address feeTreasury_
    ) EIP712("Canopic", "1") {
        if (
            address(params_) == address(0) || address(eligibility_) == address(0) || address(oracle_) == address(0)
                || feeTreasury_ == address(0)
        ) revert ZeroAddress();
        params = params_;
        eligibility = eligibility_;
        oracle = oracle_;
        factory = factory_;
        feeTreasury = feeTreasury_;
        quoteToken = factory_.quoteToken();
    }

    function quoteDigest(Types.MakerQuote calldata q) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    QUOTE_TYPEHASH, q.maker, q.tokenIn, q.tokenOut, q.amountIn, q.amountOut, q.taker, q.expiry, q.nonce
                )
            )
        );
    }

    /// @notice Settles quote `q` on behalf of `taker` and sends the output to `to`. Only the SwapRouter may call
    ///         it; by then the router has verified the taker's role and taken custody of the input tokens.
    function settle(Types.MakerQuote calldata q, bytes calldata signature, address taker, address to)
        external
        onlyRouter
        returns (uint256 netOut)
    {
        if (q.amountIn == 0 || q.amountOut == 0) revert ZeroAmount();
        if (block.timestamp > q.expiry) revert QuoteExpired();
        if (q.taker != address(0) && q.taker != taker) revert WrongTaker();
        // A maker trading against itself only burns a fee and pads the volume figures, so the fill is blocked.
        if (q.maker == taker) revert SelfTrade();
        if (nonceUsed[q.maker][q.nonce]) revert NonceAlreadyUsed();
        if (q.nonce < minNonce[q.maker]) revert NonceTooLow();
        nonceUsed[q.maker][q.nonce] = true;

        if (!SignatureChecker.isValidSignatureNow(q.maker, quoteDigest(q), signature)) revert BadSignature();
        eligibility.requireRole(q.maker, Roles.MAKER);

        // The quote asset must appear on precisely one side; the token on the other side selects the market to check.
        bool buyBase = q.tokenIn == quoteToken;
        if (buyBase == (q.tokenOut == quoteToken)) revert QuoteAssetRequired();
        address base = buyBase ? q.tokenOut : q.tokenIn;

        uint256 mid = _bandCheckedMid(base, buyBase ? q.amountIn : q.amountOut, buyBase ? q.amountOut : q.amountIn);

        uint256 fee;
        if (buyBase) {
            // Fees are always charged in the quote-asset leg. Quoted amounts are gross, so it is up to makers
            // to build the fee into their price.
            fee = q.amountIn * params.feeParams().rfqFeeBps / Types.BPS;
            IERC20(q.tokenIn).safeTransferFrom(msg.sender, q.maker, q.amountIn - fee);
            IERC20(q.tokenIn).safeTransferFrom(msg.sender, feeTreasury, fee);
            IERC20(q.tokenOut).safeTransferFrom(q.maker, to, q.amountOut);
            netOut = q.amountOut;
        } else {
            fee = q.amountOut * params.feeParams().rfqFeeBps / Types.BPS;
            IERC20(q.tokenIn).safeTransferFrom(msg.sender, q.maker, q.amountIn);
            IERC20(q.tokenOut).safeTransferFrom(q.maker, to, q.amountOut - fee);
            IERC20(q.tokenOut).safeTransferFrom(q.maker, feeTreasury, fee);
            netOut = q.amountOut - fee;
        }

        emit RfqFilled(q.maker, taker, q.tokenIn, q.tokenOut, q.amountIn, netOut, fee, mid);
    }

    /// @notice Tells whether `taker` could settle this quote right now, judging only the quote itself: it must be
    ///         unexpired, open to the taker (or to all), on a live nonce, correctly signed, and from a maker who
    ///         still has the role. Market state and balances are out of scope. Handy for clearing dead quotes.
    function quoteFillable(Types.MakerQuote calldata q, bytes calldata signature, address taker)
        external
        view
        returns (bool)
    {
        if (q.amountIn == 0 || q.amountOut == 0 || block.timestamp > q.expiry) return false;
        if (q.taker != address(0) && q.taker != taker) return false;
        if (q.maker == taker) return false;
        if (nonceUsed[q.maker][q.nonce] || q.nonce < minNonce[q.maker]) return false;
        if (!SignatureChecker.isValidSignatureNow(q.maker, quoteDigest(q), signature)) return false;
        return eligibility.isEligible(q.maker, Roles.MAKER);
    }

    /// @notice Marks every nonce in `nonces` as consumed for the caller, so those quotes can no longer settle. No pause
    ///         applies to it, and if the sequencer censors a maker, the call can still go through the L1 delayed inbox.
    function cancel(uint256[] calldata nonces) external {
        for (uint256 i = 0; i < nonces.length; i++) {
            // Nonces that were already filled or cancelled are passed over. Events then reflect genuine
            // cancellations only, and a quote that actually settled is never reported as cancelled.
            if (nonceUsed[msg.sender][nonces[i]]) continue;
            nonceUsed[msg.sender][nonces[i]] = true;
            emit NonceCancelled(msg.sender, nonces[i]);
        }
    }

    /// @notice Lifts the caller's minimum nonce to `floor`, voiding all quotes beneath it in a single call. This
    ///         helps a maker that has lost track of its outstanding quotes or suspects its key leaked. A value at
    ///         or below the current floor does nothing, and with increasing nonces the entire book can be cleared
    ///         for constant gas.
    function cancelBelow(uint256 floor) external {
        if (floor <= minNonce[msg.sender]) return;
        minNonce[msg.sender] = floor;
        emit MinNonceRaised(msg.sender, floor);
    }

    /// @notice Returns true when `nonce` is unused and at or above the maker's floor; no other quote checks run.
    function nonceUsable(address maker, uint256 nonce) external view returns (bool) {
        return !nonceUsed[maker][nonce] && nonce >= minNonce[maker];
    }

    /// @dev Applies the vault route's listing and halt checks, followed by the price band. Regardless of what the maker
    ///      signed, its implied price has to fall inside the tier band around the oracle mid. Returns that mid.
    function _bandCheckedMid(address base, uint256 quoteAmount, uint256 baseAmount) internal view returns (uint256) {
        ISettingsTimelock.MarketConfig memory mkt = params.marketConfig(base);
        if (!mkt.enabled) revert MarketNotListed();
        // A market is live only while its tier is enabled as well. Turning a tier off delists all its markets,
        // and the RFQ route has to respect that too; otherwise makers could go on trading markets the vault
        // route has already closed.
        ISettingsTimelock.TierConfig memory tier = params.tierConfig(mkt.tier);
        if (!tier.enabled) revert MarketNotListed();
        IOracleAdapter.Quote memory oq = oracle.quote(base);
        if (oq.paused || oq.stale || oq.sequencerGrace) revert MarketHalted();

        uint256 implied = quoteAmount * 10 ** oracle.tokenDecimals(base) / baseAmount;
        uint256 diff = implied > oq.price ? implied - oq.price : oq.price - implied;
        if (diff * Types.BPS / oq.price > tier.oracleBandBps) revert BandExceeded(implied, oq.price);
        return oq.price;
    }
}
