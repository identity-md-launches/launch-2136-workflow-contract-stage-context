// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "src/LaunchToken.sol";

/// forge-config: default.fuzz.runs = 1000
contract LaunchTokenEdgesTest is Test {
    LaunchToken internal token;
    address internal holder = makeAddr("token holder fixture");
    address internal recipient = makeAddr("token recipient fixture");
    address internal spender = makeAddr("token spender fixture");
    uint256 internal constant SUPPLY = 1e27;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.prank(holder);
        token = new LaunchToken();
    }

    function test_zeroTransferFromUnfundedAccountEmitsWithoutChangingSupply() public {
        vm.expectEmit(address(token));
        emit Transfer(recipient, holder, 0);
        vm.prank(recipient);
        assertTrue(token.transfer(holder, 0));
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_oneWeiAndEntireSupplyTransferWithoutFee() public {
        vm.startPrank(holder);
        token.transfer(recipient, 1);
        assertEq(token.balanceOf(recipient), 1);
        token.transfer(recipient, SUPPLY - 1);
        vm.stopPrank();
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(recipient), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroRecipientRejectedEvenForZeroValue() public {
        vm.startPrank(holder);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.stopPrank();
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroSpenderApprovalRejected() public {
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        assertEq(token.allowance(holder, address(0)), 0);
    }

    function test_maximumTransferRevertsWithNoStateChanges() public {
        vm.prank(holder);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, SUPPLY, type(uint256).max)
        );
        token.transfer(recipient, type(uint256).max);
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_invalidTransferFromRecipientRestoresAllowance() public {
        vm.prank(holder);
        token.approve(spender, 1);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(holder, address(0), 1);
        assertEq(token.allowance(holder, spender), 1);
        assertEq(token.balanceOf(holder), SUPPLY);
    }

    function test_failedTransferFromRestoresFiniteAllowanceAfterBalanceCheck() public {
        vm.prank(recipient);
        token.approve(spender, 1);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, recipient, 0, 1));
        token.transferFrom(recipient, holder, 1);
        assertEq(token.allowance(recipient, spender), 1);
        assertEq(token.balanceOf(holder), SUPPLY);
    }

    function test_approvalReplacementAndRevocation() public {
        vm.startPrank(holder);
        token.approve(spender, type(uint256).max);
        vm.expectEmit(address(token));
        emit Approval(holder, spender, 7);
        token.approve(spender, 7);
        assertEq(token.allowance(holder, spender), 7);
        token.approve(spender, 0);
        vm.stopPrank();
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(holder, recipient, 1);
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
    }

    function testFuzz_transferRoundTripAndSelfTransferConserveEveryToken(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(holder);
        token.transfer(holder, amount);
        assertEq(token.balanceOf(holder), SUPPLY);
        vm.prank(holder);
        token.transfer(recipient, amount);
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(holder), SUPPLY - amount);
        vm.prank(recipient);
        token.transfer(holder, amount);
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferFromUsesOnlyCallersAllowance(uint256 amount, bool infinite) public {
        amount = bound(amount, 1, SUPPLY);
        uint256 approval = infinite ? type(uint256).max : amount;
        vm.prank(holder);
        token.approve(spender, approval);
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, recipient, 0, amount));
        token.transferFrom(holder, recipient, amount);
        assertEq(token.allowance(holder, spender), approval);
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, recipient, amount));
        assertEq(token.allowance(holder, spender), infinite ? type(uint256).max : 0);
        assertEq(token.balanceOf(holder), SUPPLY - amount);
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_selfTransferFromConsumesAllowanceWithoutChangingBalances(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(holder);
        token.approve(spender, amount);
        vm.prank(spender);
        token.transferFrom(holder, holder, amount);
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.allowance(holder, spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
