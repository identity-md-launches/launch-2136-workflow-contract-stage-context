// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {MnemoVault} from "../src/MnemoVault.sol";

contract MnemoVaultTest is Test {
    LaunchToken internal token;
    MnemoVault internal vault;

    address internal factory = makeAddr("factory");
    address internal owner = makeAddr("launchOwner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal agent = makeAddr("agent");

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant STAMP = 2_000e18;
    bytes32 internal constant AGENT_KEY = bytes32(uint256(0xA6E7));

    event Noted(address indexed owner, uint256 indexed id, uint32 epoch, bytes ciphertext);
    event Forgotten(address indexed owner, uint256 indexed id);
    event Rotated(address indexed owner, uint32 epoch);
    event Granted(address indexed owner, address indexed agent, uint32 epoch, bytes sealedKey);
    event Revoked(address indexed owner, address indexed agent);
    event KeyRegistered(address indexed account, bytes32 key);
    event StampChanged(uint256 oldStamp, uint256 newStamp);

    function setUp() public {
        vm.prank(factory);
        token = new LaunchToken();
        vm.prank(factory);
        vault = new MnemoVault(address(token), owner);

        // Users buy MNEMO after launch; here the factory simply hands some out.
        vm.startPrank(factory);
        token.transfer(alice, 1_000_000e18);
        token.transfer(bob, 1_000_000e18);
        token.transfer(agent, 1_000_000e18);
        vm.stopPrank();

        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);
        vm.prank(agent);
        token.approve(address(vault), type(uint256).max);
    }

    // ------------------------------------------------------------------ helpers

    function _notes(uint256 count, uint256 len) internal pure returns (bytes[] memory notes) {
        notes = new bytes[](count);
        for (uint256 i; i < count; ++i) {
            bytes memory n = new bytes(len);
            for (uint256 j; j < len; ++j) {
                n[j] = bytes1(uint8(0x41 + ((i + j) % 26)));
            }
            notes[i] = n;
        }
    }

    function _one(bytes memory n) internal pure returns (bytes[] memory notes) {
        notes = new bytes[](1);
        notes[0] = n;
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    function _registerAndGrant(address vaultOwner, address agent_) internal {
        vm.prank(agent_);
        vault.register(AGENT_KEY);
        vm.prank(vaultOwner);
        vault.grant(agent_, hex"deadbeef");
    }

    // ------------------------------------------------------------------ deployment

    function test_constructorState() public view {
        assertEq(address(vault.token()), address(token));
        assertEq(vault.owner(), owner);
        assertEq(vault.stamp(), STAMP);
        assertEq(vault.INITIAL_STAMP(), STAMP);
        assertEq(vault.MIN_STAMP(), 100e18);
        assertEq(vault.MAX_STAMP(), 100_000e18);
        assertEq(vault.MAX_NOTE_BYTES(), 2_048);
        assertEq(vault.MAX_NOTES_PER_CALL(), 16);
        assertEq(vault.BURN_ADDRESS(), DEAD);
        assertEq(vault.notesTotal(), 0);
        assertEq(vault.burnedTotal(), 0);
    }

    function test_constructorOwnerIsTheArgumentNotTheDeployer() public {
        vm.prank(factory);
        MnemoVault v = new MnemoVault(address(token), owner);
        assertEq(v.owner(), owner);
        assertTrue(v.owner() != factory);
    }

    function test_constructorMakesNoCallToTheToken() public {
        // An address with no code: the launch checks run constructors on an empty chain.
        address noCode = makeAddr("tokenToBe");
        assertEq(noCode.code.length, 0);
        MnemoVault v = new MnemoVault(noCode, owner);
        assertEq(address(v.token()), noCode);
    }

    function test_constructorRevertsOnZeroToken() public {
        vm.expectRevert(MnemoVault.ZeroAddress.selector);
        new MnemoVault(address(0), owner);
    }

    function test_constructorRevertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new MnemoVault(address(token), address(0));
    }

    // ------------------------------------------------------------------ write

    function test_writeSealsNotesBurnsStampAndEmits() public {
        bytes[] memory notes = _notes(3, 100);
        uint256 before = token.balanceOf(alice);

        vm.expectEmit(address(vault));
        emit Noted(alice, 1, 0, notes[0]);
        vm.expectEmit(address(vault));
        emit Noted(alice, 2, 0, notes[1]);
        vm.expectEmit(address(vault));
        emit Noted(alice, 3, 0, notes[2]);

        vm.prank(alice);
        uint256 firstId = vault.write(notes, 0);

        assertEq(firstId, 1);
        assertEq(vault.notesTotal(), 3);
        assertEq(vault.burnedTotal(), 3 * STAMP);
        assertEq(token.balanceOf(DEAD), 3 * STAMP);
        assertEq(token.balanceOf(alice), before - 3 * STAMP);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(vault.noteOwnerOf(1), alice);
        assertEq(vault.noteOwnerOf(2), alice);
        assertEq(vault.noteOwnerOf(3), alice);
        assertEq(vault.noteOwnerOf(4), address(0));
    }

    function test_writeIdsCountUpAcrossWriters() public {
        vm.prank(alice);
        vault.write(_notes(2, 10), 0);
        vm.prank(bob);
        uint256 firstId = vault.write(_notes(1, 10), 0);
        assertEq(firstId, 3);
        assertEq(vault.noteOwnerOf(3), bob);
        assertEq(vault.notesTotal(), 3);
    }

    function test_writeAcceptsMaxNotesAndMaxLength() public {
        bytes[] memory notes = _notes(16, 2_048);
        vm.prank(alice);
        vault.write(notes, 0);
        assertEq(vault.notesTotal(), 16);
        assertEq(vault.burnedTotal(), 16 * STAMP);
    }

    function test_writeRevertsOnNoNotes() public {
        bytes[] memory none = new bytes[](0);
        vm.prank(alice);
        vm.expectRevert(MnemoVault.NoNotes.selector);
        vault.write(none, 0);
    }

    function test_writeRevertsOnTooManyNotes() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.TooManyNotes.selector, 17));
        vault.write(_notes(17, 10), 0);
    }

    function test_writeRevertsOnNoteTooLong() public {
        bytes[] memory notes = _notes(2, 10);
        notes[1] = new bytes(2_049);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.NoteTooLong.selector, 1, 2_049));
        vault.write(notes, 0);
    }

    function test_writeRevertsOnEmptyNote() public {
        bytes[] memory notes = _notes(2, 10);
        notes[0] = "";
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.EmptyNote.selector, 0));
        vault.write(notes, 0);
    }

    function test_writeRevertsOnWrongEpoch() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.WrongEpoch.selector, 0, 1));
        vault.write(_notes(1, 10), 1);

        vm.prank(alice);
        vault.rotate();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.WrongEpoch.selector, 1, 0));
        vault.write(_notes(1, 10), 0);
    }

    function test_writeRevertsWithoutMnemo() public {
        address poor = makeAddr("poor");
        vm.prank(poor);
        token.approve(address(vault), type(uint256).max);
        vm.prank(poor);
        vm.expectRevert();
        vault.write(_notes(1, 10), 0);
        assertEq(vault.notesTotal(), 0);
        assertEq(vault.burnedTotal(), 0);
    }

    function test_writeRevertsWithoutAllowance() public {
        address holder = makeAddr("holder");
        vm.prank(factory);
        token.transfer(holder, 10_000e18);
        vm.prank(holder);
        vm.expectRevert();
        vault.write(_notes(1, 10), 0);
    }

    function test_writeRevertsWhenBalanceCoversSomeButNotAllNotes() public {
        address holder = makeAddr("holder");
        vm.prank(factory);
        token.transfer(holder, 2 * STAMP);
        vm.prank(holder);
        token.approve(address(vault), type(uint256).max);
        vm.prank(holder);
        vm.expectRevert();
        vault.write(_notes(3, 10), 0);
        assertEq(vault.notesTotal(), 0);
    }

    function test_writeUsesCurrentStampForFutureWritesOnly() public {
        vm.prank(alice);
        vault.write(_notes(1, 10), 0);
        assertEq(vault.burnedTotal(), STAMP);

        vm.prank(owner);
        vault.setStamp(500e18);

        vm.prank(alice);
        vault.write(_notes(2, 10), 0);
        assertEq(vault.burnedTotal(), STAMP + 1_000e18);
        assertEq(token.balanceOf(DEAD), STAMP + 1_000e18);
    }

    function test_writeAfterRotationUsesNewEpoch() public {
        vm.prank(alice);
        vault.rotate();
        bytes[] memory notes = _notes(1, 10);
        vm.expectEmit(address(vault));
        emit Noted(alice, 1, 1, notes[0]);
        vm.prank(alice);
        vault.write(notes, 1);
    }

    // ------------------------------------------------------------------ forget

    function test_forgetOwnNotes() public {
        vm.prank(alice);
        vault.write(_notes(3, 10), 0);

        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 3;
        vm.expectEmit(address(vault));
        emit Forgotten(alice, 1);
        vm.expectEmit(address(vault));
        emit Forgotten(alice, 3);
        vm.prank(alice);
        vault.forget(ids);

        assertEq(vault.noteOwnerOf(1), address(0));
        assertEq(vault.noteOwnerOf(2), alice);
        assertEq(vault.noteOwnerOf(3), address(0));
        // Totals are historical and never shrink.
        assertEq(vault.notesTotal(), 3);
        assertEq(vault.burnedTotal(), 3 * STAMP);
    }

    function test_forgetRevertsForSomeoneElsesNote() public {
        vm.prank(alice);
        vault.write(_notes(1, 10), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.NotNoteOwner.selector, 1));
        vault.forget(_ids(1));
    }

    function test_forgetRevertsForUnknownId() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.NotNoteOwner.selector, 42));
        vault.forget(_ids(42));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.NotNoteOwner.selector, 0));
        vault.forget(_ids(0));
    }

    function test_forgetRevertsOnDoubleForget() public {
        vm.prank(alice);
        vault.write(_notes(1, 10), 0);
        vm.prank(alice);
        vault.forget(_ids(1));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.NotNoteOwner.selector, 1));
        vault.forget(_ids(1));
    }

    function test_forgetRevertsOnEmptyList() public {
        uint256[] memory none = new uint256[](0);
        vm.prank(alice);
        vm.expectRevert(MnemoVault.NoNotes.selector);
        vault.forget(none);
    }

    function test_forgetIsAllOrNothing() public {
        vm.prank(alice);
        vault.write(_notes(2, 10), 0);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 99;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.NotNoteOwner.selector, 99));
        vault.forget(ids);
        assertEq(vault.noteOwnerOf(1), alice);
    }

    function test_agentCannotForgetNotesItWrote() public {
        _registerAndGrant(alice, agent);
        vm.prank(agent);
        vault.writeFor(alice, _notes(1, 10), 0);
        assertEq(vault.noteOwnerOf(1), alice);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.NotNoteOwner.selector, 1));
        vault.forget(_ids(1));
        vm.prank(alice);
        vault.forget(_ids(1));
    }

    // ------------------------------------------------------------------ rotate

    function test_rotateIncrementsEpochAndEmits() public {
        assertEq(vault.epochOf(alice), 0);
        vm.expectEmit(address(vault));
        emit Rotated(alice, 1);
        vm.prank(alice);
        vault.rotate();
        assertEq(vault.epochOf(alice), 1);
        vm.prank(alice);
        vault.rotate();
        assertEq(vault.epochOf(alice), 2);
        assertEq(vault.epochOf(bob), 0);
    }

    // ------------------------------------------------------------------ register

    function test_registerStoresKeyAndEmits() public {
        vm.expectEmit(address(vault));
        emit KeyRegistered(agent, AGENT_KEY);
        vm.prank(agent);
        vault.register(AGENT_KEY);
        assertEq(vault.keyOf(agent), AGENT_KEY);
    }

    function test_registerCanBeReplaced() public {
        vm.prank(agent);
        vault.register(AGENT_KEY);
        vm.prank(agent);
        vault.register(bytes32(uint256(2)));
        assertEq(vault.keyOf(agent), bytes32(uint256(2)));
    }

    function test_registerRevertsOnZeroKey() public {
        vm.prank(agent);
        vm.expectRevert(MnemoVault.ZeroKey.selector);
        vault.register(bytes32(0));
    }

    // ------------------------------------------------------------------ grant / revoke

    function test_grantRecordsAgentAndEmitsCurrentEpoch() public {
        vm.prank(agent);
        vault.register(AGENT_KEY);
        vm.prank(alice);
        vault.rotate();

        vm.expectEmit(address(vault));
        emit Granted(alice, agent, 1, hex"c0ffee");
        vm.prank(alice);
        vault.grant(agent, hex"c0ffee");

        assertTrue(vault.isGranted(alice, agent));
        assertFalse(vault.isGranted(bob, agent));
        assertFalse(vault.isGranted(alice, bob));
    }

    function test_grantRevertsForUnregisteredAgent() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.AgentNotRegistered.selector, agent));
        vault.grant(agent, hex"c0ffee");
    }

    function test_grantRevertsOnZeroAgent() public {
        vm.prank(alice);
        vm.expectRevert(MnemoVault.ZeroAddress.selector);
        vault.grant(address(0), hex"c0ffee");
    }

    function test_grantRevertsOnSelf() public {
        vm.prank(alice);
        vault.register(AGENT_KEY);
        vm.prank(alice);
        vm.expectRevert(MnemoVault.SelfGrant.selector);
        vault.grant(alice, hex"c0ffee");
    }

    function test_grantRevertsOnEmptySealedKey() public {
        vm.prank(agent);
        vault.register(AGENT_KEY);
        vm.prank(alice);
        vm.expectRevert(MnemoVault.EmptySealedKey.selector);
        vault.grant(agent, "");
    }

    function test_grantRevertsWhenAlreadyGranted() public {
        _registerAndGrant(alice, agent);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.AlreadyGranted.selector, alice, agent));
        vault.grant(agent, hex"c0ffee");
    }

    function test_revokeClearsGrantAndRotates() public {
        _registerAndGrant(alice, agent);
        assertEq(vault.epochOf(alice), 0);

        vm.expectEmit(address(vault));
        emit Revoked(alice, agent);
        vm.expectEmit(address(vault));
        emit Rotated(alice, 1);
        vm.prank(alice);
        vault.revoke(agent);

        assertFalse(vault.isGranted(alice, agent));
        assertEq(vault.epochOf(alice), 1);
    }

    function test_revokeRevertsWhenNotGranted() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.NotGranted.selector, alice, agent));
        vault.revoke(agent);
        assertEq(vault.epochOf(alice), 0);
    }

    function test_regrantAfterRevokeWorks() public {
        _registerAndGrant(alice, agent);
        vm.prank(alice);
        vault.revoke(agent);
        vm.expectEmit(address(vault));
        emit Granted(alice, agent, 1, hex"01");
        vm.prank(alice);
        vault.grant(agent, hex"01");
        assertTrue(vault.isGranted(alice, agent));
    }

    // ------------------------------------------------------------------ writeFor

    function test_writeForBurnsFromAgentAndAttributesToOwner() public {
        _registerAndGrant(alice, agent);
        bytes[] memory notes = _notes(2, 50);
        uint256 agentBefore = token.balanceOf(agent);
        uint256 aliceBefore = token.balanceOf(alice);

        vm.expectEmit(address(vault));
        emit Noted(alice, 1, 0, notes[0]);
        vm.expectEmit(address(vault));
        emit Noted(alice, 2, 0, notes[1]);
        vm.prank(agent);
        uint256 firstId = vault.writeFor(alice, notes, 0);

        assertEq(firstId, 1);
        assertEq(token.balanceOf(agent), agentBefore - 2 * STAMP);
        assertEq(token.balanceOf(alice), aliceBefore);
        assertEq(token.balanceOf(DEAD), 2 * STAMP);
        assertEq(vault.noteOwnerOf(1), alice);
        assertEq(vault.noteOwnerOf(2), alice);
    }

    function test_writeForRevertsWhenNotGranted() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.NotGranted.selector, alice, agent));
        vault.writeFor(alice, _notes(1, 10), 0);
    }

    function test_writeForRevertsAfterRevoke() public {
        _registerAndGrant(alice, agent);
        vm.prank(alice);
        vault.revoke(agent);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.NotGranted.selector, alice, agent));
        vault.writeFor(alice, _notes(1, 10), 1);
    }

    function test_writeForRevertsOnStaleEpochAfterOwnerRotates() public {
        _registerAndGrant(alice, agent);
        vm.prank(alice);
        vault.rotate();
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.WrongEpoch.selector, 1, 0));
        vault.writeFor(alice, _notes(1, 10), 0);
        // With the owner's current epoch it succeeds.
        vm.prank(agent);
        vault.writeFor(alice, _notes(1, 10), 1);
    }

    function test_writeForChecksTheOwnersEpochNotTheAgents() public {
        _registerAndGrant(alice, agent);
        vm.prank(agent);
        vault.rotate();
        assertEq(vault.epochOf(agent), 1);
        vm.prank(agent);
        vault.writeFor(alice, _notes(1, 10), 0);
        assertEq(vault.notesTotal(), 1);
    }

    function test_writeForGrantIsPerOwner() public {
        _registerAndGrant(alice, agent);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.NotGranted.selector, bob, agent));
        vault.writeFor(bob, _notes(1, 10), 0);
    }

    function test_writeForAppliesNoteLimits() public {
        _registerAndGrant(alice, agent);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.TooManyNotes.selector, 17));
        vault.writeFor(alice, _notes(17, 10), 0);
    }

    function test_writeForRevertsWhenAgentHasNoMnemo() public {
        address brokeAgent = makeAddr("brokeAgent");
        vm.prank(brokeAgent);
        vault.register(AGENT_KEY);
        vm.prank(brokeAgent);
        token.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.grant(brokeAgent, hex"01");

        vm.prank(brokeAgent);
        vm.expectRevert();
        vault.writeFor(alice, _notes(1, 10), 0);
        // The owner's balance is never touched by an agent write.
        assertEq(token.balanceOf(alice), 1_000_000e18);
    }

    // ------------------------------------------------------------------ owner

    function test_setStampByOwnerWithinRange() public {
        vm.expectEmit(address(vault));
        emit StampChanged(STAMP, 100e18);
        vm.prank(owner);
        vault.setStamp(100e18);
        assertEq(vault.stamp(), 100e18);

        vm.prank(owner);
        vault.setStamp(100_000e18);
        assertEq(vault.stamp(), 100_000e18);
    }

    function test_setStampRevertsOutOfRange() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.StampOutOfRange.selector, 100e18 - 1));
        vault.setStamp(100e18 - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.StampOutOfRange.selector, 100_000e18 + 1));
        vault.setStamp(100_000e18 + 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.StampOutOfRange.selector, 0));
        vault.setStamp(0);
        assertEq(vault.stamp(), STAMP);
    }

    function test_setStampRevertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setStamp(500e18);
        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, factory));
        vault.setStamp(500e18);
    }

    function test_ownershipTransferIsTwoStep() public {
        address next = makeAddr("nextOwner");
        vm.prank(owner);
        vault.transferOwnership(next);
        assertEq(vault.owner(), owner);
        assertEq(vault.pendingOwner(), next);

        // The pending owner has no power yet.
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, next));
        vault.setStamp(500e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.acceptOwnership();

        vm.prank(next);
        vault.acceptOwnership();
        assertEq(vault.owner(), next);
        assertEq(vault.pendingOwner(), address(0));

        vm.prank(next);
        vault.setStamp(500e18);
        assertEq(vault.stamp(), 500e18);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vault.setStamp(600e18);
    }

    function test_renounceOwnershipIsDisabled() public {
        vm.prank(owner);
        vm.expectRevert(MnemoVault.RenounceDisabled.selector);
        vault.renounceOwnership();
        assertEq(vault.owner(), owner);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.renounceOwnership();
    }

    function test_vaultNeverHoldsTokens() public {
        vm.prank(alice);
        vault.write(_notes(5, 10), 0);
        _registerAndGrant(bob, agent);
        vm.prank(agent);
        vault.writeFor(bob, _notes(2, 10), 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(DEAD), vault.burnedTotal());
        assertEq(vault.burnedTotal(), 7 * STAMP);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_writeBurnsStampTimesCount(uint8 count, uint16 len, uint256 newStamp) public {
        count = uint8(bound(count, 1, 16));
        len = uint16(bound(len, 1, 2_048));
        newStamp = bound(newStamp, 100e18, 100_000e18);
        vm.prank(owner);
        vault.setStamp(newStamp);
        // 16 notes at the maximum stamp cost 1,600,000 MNEMO; make sure alice can pay.
        vm.prank(factory);
        token.transfer(alice, 1_000_000e18);

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        uint256 firstId = vault.write(_notes(count, len), 0);

        assertEq(firstId, 1);
        assertEq(vault.notesTotal(), count);
        assertEq(vault.burnedTotal(), uint256(count) * newStamp);
        assertEq(token.balanceOf(DEAD), uint256(count) * newStamp);
        assertEq(token.balanceOf(alice), before - uint256(count) * newStamp);
    }

    function testFuzz_setStampRejectsOutsideRange(uint256 value) public {
        vm.assume(value < 100e18 || value > 100_000e18);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.StampOutOfRange.selector, value));
        vault.setStamp(value);
    }

    function testFuzz_wrongEpochAlwaysReverts(uint32 epoch, uint8 rotations) public {
        rotations = uint8(bound(rotations, 0, 8));
        for (uint256 i; i < rotations; ++i) {
            vm.prank(alice);
            vault.rotate();
        }
        vm.assume(epoch != rotations);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.WrongEpoch.selector, uint32(rotations), epoch));
        vault.write(_notes(1, 10), epoch);
    }

    function testFuzz_onlyNoteOwnerCanForget(address who) public {
        vm.assume(who != alice);
        vm.prank(alice);
        vault.write(_notes(1, 10), 0);
        vm.prank(who);
        vm.expectRevert(abi.encodeWithSelector(MnemoVault.NotNoteOwner.selector, 1));
        vault.forget(_ids(1));
    }
}
