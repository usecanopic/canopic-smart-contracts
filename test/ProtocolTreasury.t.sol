// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Fixture} from "./Fixture.t.sol";
import {ProtocolTreasury} from "../src/settings/ProtocolTreasury.sol";

/// @notice Holding collected fees: only governance can pull funds out, and address zero is never accepted as the payee.
contract ProtocolTreasuryTest is Fixture {
    address internal treasury = makeAddr("treasury");

    function setUp() public override {
        super.setUp();
        usdg.mint(address(fees), 1_234e6);
    }

    function test_onlyGovernanceMayWithdraw() public {
        vm.prank(outsider);
        vm.expectRevert(ProtocolTreasury.NotGovernance.selector);
        fees.withdraw(IERC20(address(usdg)), outsider, 1e6);

        vm.prank(outsider);
        vm.expectRevert(ProtocolTreasury.NotGovernance.selector);
        fees.withdrawAll(IERC20(address(usdg)), outsider);
    }

    function test_withdrawRefusesTheZeroRecipient() public {
        vm.startPrank(gov);
        vm.expectRevert(ProtocolTreasury.ZeroAddress.selector);
        fees.withdraw(IERC20(address(usdg)), address(0), 1e6);
        vm.expectRevert(ProtocolTreasury.ZeroAddress.selector);
        fees.withdrawAll(IERC20(address(usdg)), address(0));
        vm.stopPrank();
    }

    function test_withdrawAllSweepsTheFullBalance() public {
        vm.prank(gov);
        uint256 amount = fees.withdrawAll(IERC20(address(usdg)), treasury);

        assertEq(amount, 1_234e6);
        assertEq(usdg.balanceOf(treasury), 1_234e6);
        assertEq(usdg.balanceOf(address(fees)), 0);
    }

    function test_partialWithdrawLeavesTheRest() public {
        vm.prank(gov);
        fees.withdraw(IERC20(address(usdg)), treasury, 234e6);

        assertEq(usdg.balanceOf(treasury), 234e6);
        assertEq(usdg.balanceOf(address(fees)), 1_000e6);
    }

    function test_withdrawAllManySweepsEachToken() public {
        nvda.mint(address(fees), 3e18);
        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(usdg));
        tokens[1] = IERC20(address(nvda));
        tokens[2] = IERC20(address(spy)); // no SPY balance sits in the treasury

        vm.prank(gov);
        uint256[] memory amounts = fees.withdrawAllMany(tokens, treasury);

        assertEq(amounts[0], 1_234e6);
        assertEq(amounts[1], 3e18);
        assertEq(amounts[2], 0);
        assertEq(usdg.balanceOf(treasury), 1_234e6);
        assertEq(nvda.balanceOf(treasury), 3e18);

        vm.prank(outsider);
        vm.expectRevert(ProtocolTreasury.NotGovernance.selector);
        fees.withdrawAllMany(tokens, outsider);
    }

    function test_withdrawRefusesAZeroAmount() public {
        vm.prank(gov);
        vm.expectRevert(ProtocolTreasury.ZeroAmount.selector);
        fees.withdraw(IERC20(address(usdg)), treasury, 0);
    }

    function test_treasuryCannotPayItself() public {
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(usdg));
        vm.startPrank(gov);
        vm.expectRevert(ProtocolTreasury.InvalidRecipient.selector);
        fees.withdraw(tokens[0], address(fees), 1e6);
        vm.expectRevert(ProtocolTreasury.InvalidRecipient.selector);
        fees.withdrawAll(tokens[0], address(fees));
        vm.expectRevert(ProtocolTreasury.InvalidRecipient.selector);
        fees.withdrawAllMany(tokens, address(fees));
        vm.stopPrank();
    }
}
