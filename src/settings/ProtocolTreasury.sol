// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISettingsTimelock} from "../interfaces/ISettingsTimelock.sol";

/// @title ProtocolTreasury
/// @notice Custody for everything the protocol earns, namely swap fees, RFQ fees and its share of the spread.
///         The SettingsTimelock owner decides on withdrawals for now; a purpose-built governance module will
///         handle allocation later.
contract ProtocolTreasury {
    using SafeERC20 for IERC20;

    ISettingsTimelock public immutable params;

    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    error NotGovernance();
    error ZeroAddress();

    constructor(ISettingsTimelock params_) {
        if (address(params_) == address(0)) revert ZeroAddress();
        params = params_;
    }

    function withdraw(IERC20 token, address to, uint256 amount) external {
        if (msg.sender != params.owner()) revert NotGovernance();
        // Plenty of tokens treat sending to address zero as burning, meaning a proposal with a blank recipient
        // would quietly destroy the fees instead of failing.
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
        emit Withdrawn(address(token), to, amount);
    }

    /// @notice Sends out the full `token` balance. A proposal therefore does not have to name an exact amount,
    ///         one that new fees landing ahead of execution would render out of date regardless.
    function withdrawAll(IERC20 token, address to) external returns (uint256 amount) {
        if (msg.sender != params.owner()) revert NotGovernance();
        if (to == address(0)) revert ZeroAddress();
        amount = _sweep(token, to);
    }

    /// @notice Sweeps each entry of `tokens` to `to` at once, so a single proposal can collect every fee asset.
    ///         Tokens with nothing held are skipped.
    function withdrawAllMany(IERC20[] calldata tokens, address to) external returns (uint256[] memory amounts) {
        if (msg.sender != params.owner()) revert NotGovernance();
        if (to == address(0)) revert ZeroAddress();
        amounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            amounts[i] = _sweep(tokens[i], to);
        }
    }

    function _sweep(IERC20 token, address to) internal returns (uint256 amount) {
        amount = token.balanceOf(address(this));
        if (amount == 0) return 0;
        token.safeTransfer(to, amount);
        emit Withdrawn(address(token), to, amount);
    }
}
