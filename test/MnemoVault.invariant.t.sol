// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {MnemoVault} from "../src/MnemoVault.sol";

/// @dev Drives the vault with a small set of actors and records what should hold afterwards.
contract VaultHandler is Test {
    LaunchToken internal token;
    MnemoVault internal vault;
    address[] internal actors;

    uint256 public ghostNotes;
    uint256 public ghostBurned;
    uint256 public ghostLiveNotes;
    mapping(address => uint32) public ghostEpoch;
    mapping(uint256 => address) public ghostNoteOwner;

    constructor(LaunchToken token_, MnemoVault vault_, address[] memory actors_) {
        token = token_;
        vault = vault_;
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _notes(uint256 count) internal pure returns (bytes[] memory notes) {
        notes = new bytes[](count);
        for (uint256 i; i < count; ++i) {
            notes[i] = abi.encodePacked("note", i);
        }
    }

    function write(uint256 actorSeed, uint256 count) external {
        address who = _actor(actorSeed);
        count = bound(count, 1, 16);
        uint256 cost = vault.stamp() * count;
        if (token.balanceOf(who) < cost) return;
        uint256 first = vault.notesTotal() + 1;
        vm.prank(who);
        vault.write(_notes(count), ghostEpoch[who]);
        for (uint256 i; i < count; ++i) {
            ghostNoteOwner[first + i] = who;
        }
        ghostNotes += count;
        ghostLiveNotes += count;
        ghostBurned += cost;
    }

    function writeFor(uint256 agentSeed, uint256 ownerSeed, uint256 count) external {
        address agent = _actor(agentSeed);
        address owner = _actor(ownerSeed);
        if (!vault.isGranted(owner, agent)) return;
        count = bound(count, 1, 16);
        uint256 cost = vault.stamp() * count;
        if (token.balanceOf(agent) < cost) return;
        uint256 first = vault.notesTotal() + 1;
        vm.prank(agent);
        vault.writeFor(owner, _notes(count), ghostEpoch[owner]);
        for (uint256 i; i < count; ++i) {
            ghostNoteOwner[first + i] = owner;
        }
        ghostNotes += count;
        ghostLiveNotes += count;
        ghostBurned += cost;
    }

    function forget(uint256 actorSeed, uint256 idSeed) external {
        address who = _actor(actorSeed);
        uint256 total = vault.notesTotal();
        if (total == 0) return;
        uint256 id = bound(idSeed, 1, total);
        if (ghostNoteOwner[id] != who) return;
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(who);
        vault.forget(ids);
        delete ghostNoteOwner[id];
        ghostLiveNotes -= 1;
    }

    function rotate(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        vm.prank(who);
        vault.rotate();
        ghostEpoch[who] += 1;
    }

    function grant(uint256 ownerSeed, uint256 agentSeed) external {
        address owner = _actor(ownerSeed);
        address agent = _actor(agentSeed);
        if (owner == agent || vault.isGranted(owner, agent)) return;
        if (vault.keyOf(agent) == bytes32(0)) {
            vm.prank(agent);
            vault.register(keccak256(abi.encodePacked(agent)));
        }
        vm.prank(owner);
        vault.grant(agent, hex"01");
    }

    function revoke(uint256 ownerSeed, uint256 agentSeed) external {
        address owner = _actor(ownerSeed);
        address agent = _actor(agentSeed);
        if (!vault.isGranted(owner, agent)) return;
        vm.prank(owner);
        vault.revoke(agent);
        ghostEpoch[owner] += 1;
    }

    function setStamp(uint256 value) external {
        value = bound(value, vault.MIN_STAMP(), vault.MAX_STAMP());
        vm.prank(vault.owner());
        vault.setStamp(value);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }
}

contract MnemoVaultInvariantTest is Test {
    LaunchToken internal token;
    MnemoVault internal vault;
    VaultHandler internal handler;

    address internal factory = makeAddr("factory");
    address internal owner = makeAddr("launchOwner");
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        vm.prank(factory);
        token = new LaunchToken();
        vm.prank(factory);
        vault = new MnemoVault(address(token), owner);

        address[] memory actors = new address[](4);
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
            vm.prank(factory);
            token.transfer(actors[i], 5_000_000e18);
            vm.prank(actors[i]);
            token.approve(address(vault), type(uint256).max);
        }

        handler = new VaultHandler(token, vault, actors);
        targetContract(address(handler));
    }

    function invariant_burnedMatchesDeadBalance() public view {
        assertEq(vault.burnedTotal(), token.balanceOf(DEAD));
        assertEq(vault.burnedTotal(), handler.ghostBurned());
    }

    function invariant_vaultHoldsNothing() public view {
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function invariant_notesTotalIsMonotoneCount() public view {
        assertEq(vault.notesTotal(), handler.ghostNotes());
        assertEq(vault.noteOwnerOf(0), address(0));
        assertEq(vault.noteOwnerOf(vault.notesTotal() + 1), address(0));
    }

    function invariant_epochsMatch() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actorAt(i);
            assertEq(vault.epochOf(a), handler.ghostEpoch(a));
        }
    }

    function invariant_supplyConserved() public view {
        assertEq(token.totalSupply(), 1e27);
    }

    function invariant_ownerUnchanged() public view {
        assertEq(vault.owner(), owner);
    }
}
