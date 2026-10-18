// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MnemoVault} from "src/MnemoVault.sol";
import {MnemoTestFixture} from "./helpers/MnemoTestFixture.sol";

/// forge-config: default.fuzz.runs = 1000
contract MnemoVaultAdversarialTest is MnemoTestFixture {
    function testFuzz_lateInvalidNoteRollsBackWholeBatch(
        uint8 countSeed,
        uint8 indexSeed,
        bool oversized,
        bool delegated
    ) public {
        uint256 count = bound(countSeed, 2, 16);
        uint256 badIndex = bound(indexSeed, 1, count - 1);
        bytes[] memory notes = _notes(count, 32);
        notes[badIndex] = new bytes(oversized ? 2049 : 0);
        address payer = delegated ? agent : alice;
        if (delegated) _grant(alice, agent);

        vm.prank(payer);
        token.approve(address(vault), STAMP * count);
        bytes memory reason = oversized
            ? abi.encodeWithSelector(MnemoVault.NoteTooLong.selector, badIndex, 2049)
            : abi.encodeWithSelector(MnemoVault.EmptyNote.selector, badIndex);
        vm.expectRevert(reason);
        _write(payer, delegated, notes, 0);

        _assertPristineAccounting();
        assertEq(token.allowance(payer, address(vault)), STAMP * count);
        for (uint256 id = 1; id <= count; ++id) {
            assertEq(vault.noteOwnerOf(id), address(0));
        }

        // A failed batch consumes neither ids nor approval; the exact same approval pays the retry.
        notes[badIndex] = hex"01";
        assertEq(_write(payer, delegated, notes, 0), 1);
        assertEq(vault.notesTotal(), count);
        assertEq(vault.burnedTotal(), STAMP * count);
        assertEq(token.allowance(payer, address(vault)), 0);
    }

    function testFuzz_oneWeiShortAllowanceRevertsAtomically(uint8 countSeed, bool delegated) public {
        uint256 count = bound(countSeed, 1, 16);
        uint256 cost = count * STAMP;
        address payer = delegated ? agent : alice;
        if (delegated) _grant(alice, agent);
        vm.prank(payer);
        token.approve(address(vault), cost - 1);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), cost - 1, cost)
        );
        _write(payer, delegated, _notes(count, 1), 0);
        _assertPristineAccounting();
        assertEq(token.allowance(payer, address(vault)), cost - 1);
        for (uint256 id = 1; id <= count; ++id) {
            assertEq(vault.noteOwnerOf(id), address(0));
        }
    }

    function testFuzz_oneWeiShortBalanceRestoresSpentAllowance(uint8 countSeed, bool delegated) public {
        uint256 count = bound(countSeed, 1, 16);
        uint256 cost = count * STAMP;
        address payer = delegated ? agent : alice;
        if (delegated) _grant(alice, agent);
        vm.startPrank(payer);
        token.transfer(bob, FUNDS - (cost - 1));
        token.approve(address(vault), cost);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, payer, cost - 1, cost));
        _write(payer, delegated, _notes(count, 1), 0);
        assertEq(vault.notesTotal(), 0);
        assertEq(vault.burnedTotal(), 0);
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(token.balanceOf(payer), cost - 1);
        assertEq(token.allowance(payer, address(vault)), cost);
        for (uint256 id = 1; id <= count; ++id) {
            assertEq(vault.noteOwnerOf(id), address(0));
        }

        vm.prank(bob);
        token.transfer(payer, 1);
        assertEq(_write(payer, delegated, _notes(count, 1), 0), 1);
        assertEq(token.balanceOf(payer), 0);
        assertEq(token.allowance(payer, address(vault)), 0);
        assertEq(token.balanceOf(DEAD), cost);
    }

    function test_stampIncreaseAfterApprovalCannotPartiallyChargeOrConsumeIds() public {
        vm.prank(alice);
        token.approve(address(vault), STAMP);
        vm.prank(admin);
        vault.setStamp(STAMP + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), STAMP, STAMP + 1)
        );
        _write(alice, false, _notes(1, 1), 0);
        _assertPristineAccounting();
        assertEq(token.allowance(alice, address(vault)), STAMP);

        vm.prank(admin);
        vault.setStamp(100e18);
        _write(alice, false, _notes(1, 1), 0);
        assertEq(token.allowance(alice, address(vault)), STAMP - 100e18);
        assertEq(vault.burnedTotal(), 100e18);
    }

    function test_agentApprovalCannotBeReplacedByOwnersApproval() public {
        _grant(alice, agent);
        vm.prank(agent);
        token.approve(address(vault), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 0, STAMP)
        );
        _write(agent, true, _notes(1, 1), 0);
        _assertPristineAccounting();
        assertEq(token.allowance(alice, address(vault)), type(uint256).max);
    }

    function test_agentCanPayForOwnerWithNoTokensAndNoApproval() public {
        _grant(alice, agent);
        vm.startPrank(alice);
        token.transfer(bob, FUNDS);
        token.approve(address(vault), 0);
        vm.stopPrank();
        _write(agent, true, _notes(1, 1), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(alice, address(vault)), 0);
        assertEq(token.balanceOf(agent), FUNDS - STAMP);
        assertEq(vault.noteOwnerOf(1), alice);
    }

    function test_maximumBatchAtMaximumStampChargesExactlyOnce() public {
        vm.prank(admin);
        vault.setStamp(100_000e18);
        uint256 cost = 16 * 100_000e18;
        vm.prank(alice);
        token.approve(address(vault), cost);
        vm.expectEmit(address(token));
        emit Transfer(alice, DEAD, cost);
        _write(alice, false, _notes(16, 2048), 0);
        assertEq(vault.burnedTotal(), cost);
        assertEq(token.balanceOf(alice), FUNDS - cost);
        assertEq(token.allowance(alice, address(vault)), 0);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_oneByteNoteAtMinimumStamp() public {
        vm.prank(admin);
        vault.setStamp(100e18);
        _write(alice, false, _notes(1, 1), 0);
        assertEq(vault.notesTotal(), 1);
        assertEq(vault.burnedTotal(), 100e18);
        assertEq(token.balanceOf(alice), FUNDS - 100e18);
    }

    function testFuzz_eventsPreserveCiphertextAndHaveNoExtraNotes(bytes memory ciphertext, bool delegated) public {
        // Include arbitrary binary bytes, not only printable text or repeated zeroes.
        if (ciphertext.length == 0) ciphertext = hex"00";
        if (ciphertext.length > 2048) {
            assembly ("memory-safe") { mstore(ciphertext, 2048) }
        }
        if (delegated) _grant(alice, agent);
        vm.prank(alice);
        vault.rotate();
        bytes[] memory notes = new bytes[](2);
        notes[0] = ciphertext;
        notes[1] = hex"0000ff00";
        vm.recordLogs();
        _write(delegated ? agent : alice, delegated, notes, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 noted;
        uint256 transfers;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(vault)) {
                assertLt(noted, 2);
                assertEq(logs[i].topics.length, 3);
                assertEq(logs[i].topics[0], keccak256("Noted(address,uint256,uint32,bytes)"));
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(alice))));
                assertEq(uint256(logs[i].topics[2]), noted + 1);
                (uint32 epoch, bytes memory emitted) = abi.decode(logs[i].data, (uint32, bytes));
                assertEq(epoch, 1);
                assertEq(emitted, notes[noted]);
                ++noted;
            } else if (logs[i].emitter == address(token)) {
                assertEq(logs[i].topics[0], keccak256("Transfer(address,address,uint256)"));
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(delegated ? agent : alice))));
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(DEAD))));
                assertEq(abi.decode(logs[i].data, (uint256)), 2 * STAMP);
                ++transfers;
            }
        }
        assertEq(noted, 2);
        assertEq(transfers, 1);
    }

    function test_duplicateForgetRollsBackEarlierDeletion() public {
        _write(alice, false, _notes(2, 1), 0);
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.NotNoteOwner.selector, 1));
        vault.forget(ids);
        assertEq(vault.noteOwnerOf(1), alice);
        assertEq(vault.noteOwnerOf(2), alice);
        assertEq(vault.notesTotal(), 2);
        assertEq(vault.burnedTotal(), 2 * STAMP);
        vm.prank(alice);
        vault.forget(_ids(1));
        assertEq(vault.noteOwnerOf(1), address(0));
    }

    function test_mixedOwnerForgetRollsBackAndNeverRefundsStamp() public {
        _write(alice, false, _notes(2, 1), 0);
        _write(bob, false, _notes(1, 1), 0);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 3;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.NotNoteOwner.selector, 3));
        vault.forget(ids);
        assertEq(vault.noteOwnerOf(1), alice);
        assertEq(vault.noteOwnerOf(3), bob);
        ids[1] = 2;
        vm.prank(alice);
        vault.forget(ids);
        assertEq(token.balanceOf(alice), FUNDS - 2 * STAMP);
        assertEq(token.balanceOf(DEAD), 3 * STAMP);
        assertEq(vault.burnedTotal(), 3 * STAMP);
        assertEq(_write(alice, false, _notes(1, 1), 0), 4);
        assertEq(vault.noteOwnerOf(1), address(0));
        assertEq(vault.noteOwnerOf(2), address(0));
    }

    function test_forgetBatchIsNotLimitedToWriteBatchSize() public {
        _write(alice, false, _notes(16, 1), 0);
        _write(alice, false, _notes(16, 1), 0);
        uint256[] memory ids = new uint256[](32);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = ids.length - i;
        }
        vm.prank(alice);
        vault.forget(ids);
        for (uint256 i = 1; i <= 32; ++i) {
            assertEq(vault.noteOwnerOf(i), address(0));
        }
        assertEq(vault.notesTotal(), 32);
        assertEq(vault.burnedTotal(), 32 * STAMP);
    }

    function test_revokeIsDirectionalAndLeavesOtherVaultsAndAgentsAlone() public {
        _grant(alice, agent);
        _grant(alice, bob);
        _grant(bob, agent);
        _grant(agent, alice);
        _write(agent, true, _notes(1, 1), 0);
        vm.prank(alice);
        vault.revoke(agent);

        assertFalse(vault.isGranted(alice, agent));
        assertTrue(vault.isGranted(alice, bob));
        assertTrue(vault.isGranted(bob, agent));
        assertTrue(vault.isGranted(agent, alice));
        assertEq(vault.epochOf(alice), 1);
        assertEq(vault.epochOf(agent), 0);
        assertEq(vault.epochOf(bob), 0);
        assertEq(vault.noteOwnerOf(1), alice);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.NotGranted.selector, alice, agent));
        _write(agent, true, _notes(1, 1), 1);
        vm.prank(agent);
        vault.writeFor(bob, _notes(1, 1), 0);
        assertEq(vault.noteOwnerOf(2), bob);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.NotGranted.selector, alice, agent));
        vault.revoke(agent);
        assertEq(vault.epochOf(alice), 1);
        vm.prank(alice);
        vault.grant(agent, hex"9876");
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.WrongEpoch.selector, 1, 0));
        _write(agent, true, _notes(1, 1), 0);
        _write(agent, true, _notes(1, 1), 1);
        assertEq(vault.noteOwnerOf(3), alice);
    }

    function test_zeroKeyReplacementCannotEraseRegisteredKeyOrGrants() public {
        _grant(alice, agent);
        bytes32 previous = vault.keyOf(agent);
        vm.prank(agent);
        vm.expectRevert(MnemoVault.ZeroKey.selector);
        vault.register(bytes32(0));
        assertEq(vault.keyOf(agent), previous);
        assertTrue(vault.isGranted(alice, agent));
        assertEq(vault.epochOf(alice), 0);
    }

    function test_ownerReplacementAndCancellationCannotBeAcceptedByStaleNominee() public {
        vm.startPrank(admin);
        vault.transferOwnership(alice);
        vault.transferOwnership(bob);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.acceptOwnership();
        assertEq(vault.owner(), admin);
        assertEq(vault.pendingOwner(), bob);
        vm.prank(admin);
        vault.transferOwnership(address(0));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        vault.acceptOwnership();
        assertEq(vault.owner(), admin);
        assertEq(vault.pendingOwner(), address(0));
        vm.prank(admin);
        vm.expectRevert(MnemoVault.RenounceDisabled.selector);
        vault.renounceOwnership();
    }

    function test_ownershipHandoffDoesNotGrantAccessToUsersNotesOrFunds() public {
        _write(alice, false, _notes(1, 1), 0);
        _grant(alice, agent);
        vm.prank(admin);
        vault.transferOwnership(bob);
        vm.prank(bob);
        vault.acceptOwnership();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.NotNoteOwner.selector, 1));
        vault.forget(_ids(1));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.NotGranted.selector, alice, bob));
        vault.writeFor(alice, _notes(1, 1), 0);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        vault.transferOwnership(admin);
        vm.prank(bob);
        vm.expectRevert(MnemoVault.RenounceDisabled.selector);
        vault.renounceOwnership();
        assertEq(vault.noteOwnerOf(1), alice);
        assertTrue(vault.isGranted(alice, agent));
        assertEq(vault.epochOf(alice), 0);
        assertEq(token.balanceOf(alice), FUNDS - STAMP);
    }

    function test_firstWriteToTokenWithoutCodeRollsBackAllAccounting() public {
        address futureToken = makeAddr("not deployed token fixture");
        MnemoVault unconfigured = new MnemoVault(futureToken, admin);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, futureToken));
        unconfigured.write(_notes(2, 1), 0);
        assertEq(unconfigured.notesTotal(), 0);
        assertEq(unconfigured.burnedTotal(), 0);
        assertEq(unconfigured.noteOwnerOf(1), address(0));
        assertEq(unconfigured.noteOwnerOf(2), address(0));
    }

    function test_unsolicitedTokensDoNotPayStampsOrInflateBurnAccounting() public {
        vm.startPrank(bob);
        token.transfer(address(vault), 7 * STAMP);
        token.transfer(DEAD, 3 * STAMP);
        vm.stopPrank();
        assertEq(vault.burnedTotal(), 0);
        _write(alice, false, _notes(2, 1), 0);
        assertEq(token.balanceOf(alice), FUNDS - 2 * STAMP);
        assertEq(token.balanceOf(address(vault)), 7 * STAMP);
        assertEq(token.balanceOf(DEAD), 5 * STAMP);
        assertEq(vault.burnedTotal(), 2 * STAMP);
        assertEq(token.totalSupply(), 1e27);
    }
}
