// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {MnemoVault} from "src/MnemoVault.sol";

/// @dev The oracle starts from fixture allocations and updates only for successful operations.
/// It never copies balances, grants, epochs, prices or ids back from the contracts under test.
contract MnemoModelHandler is Test {
    LaunchToken internal immutable token;
    MnemoVault internal immutable vault;
    address[4] internal actors;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant SUPPLY = 1e27;

    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    mapping(address => mapping(address => bool)) public expectedGrant;
    mapping(address => uint32) public expectedEpoch;
    mapping(address => bytes32) public expectedKey;
    mapping(uint256 => address) public expectedNoteOwner;
    mapping(address => uint256) public stampsPaid;
    uint256 public expectedNotes;
    uint256 public expectedBurned;
    uint256 public expectedLive;
    uint256 public expectedStamp = 2_000e18;
    address public expectedOwner;
    address public expectedPendingOwner;
    uint256 public successfulWrites;
    uint256 public rejectedWrites;
    uint256 public successfulForgets;

    constructor(LaunchToken token_, MnemoVault vault_, address[4] memory actors_) {
        token = token_;
        vault = vault_;
        actors = actors_;
        expectedOwner = actors_[0];
        for (uint256 i; i < 4; ++i) {
            expectedBalance[actors_[i]] = SUPPLY / 4;
            expectedAllowance[actors_[i]][address(vault_)] = type(uint256).max;
        }
    }

    function writeSelf(uint256 actorSeed, uint8 countSeed, uint16 sizeSeed) external {
        address who = _actor(actorSeed);
        _write(who, who, countSeed, sizeSeed, false);
    }

    function writeAsAgent(uint256 ownerSeed, uint256 agentSeed, uint8 countSeed, uint16 sizeSeed) external {
        _write(_actor(ownerSeed), _actor(agentSeed), countSeed, sizeSeed, true);
    }

    function _write(address owner_, address payer, uint8 countSeed, uint16 sizeSeed, bool delegated) internal {
        uint256 count = bound(countSeed, 1, 16);
        bytes[] memory notes = _notes(count, bound(sizeSeed, 1, 2048));
        uint256 cost = expectedStamp * count;
        bytes memory reason;
        if (delegated && !expectedGrant[owner_][payer]) {
            reason = abi.encodeWithSelector(MnemoVault.NotGranted.selector, owner_, payer);
        } else if (expectedAllowance[payer][address(vault)] < cost) {
            reason = abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                address(vault),
                expectedAllowance[payer][address(vault)],
                cost
            );
        } else if (expectedBalance[payer] < cost) {
            reason = abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, payer, expectedBalance[payer], cost
            );
        }
        if (reason.length != 0) vm.expectRevert(reason);
        vm.prank(payer);
        uint256 first = delegated
            ? vault.writeFor(owner_, notes, expectedEpoch[owner_])
            : vault.write(notes, expectedEpoch[owner_]);
        if (reason.length != 0) {
            ++rejectedWrites;
            return;
        }
        assertEq(first, expectedNotes + 1, "successful writes must use the next global id");
        for (uint256 i; i < count; ++i) {
            expectedNoteOwner[expectedNotes + i + 1] = owner_;
        }
        expectedNotes += count;
        expectedLive += count;
        expectedBurned += cost;
        stampsPaid[payer] += cost;
        _move(payer, DEAD, cost);
        _spend(payer, address(vault), cost);
        ++successfulWrites;
    }

    function invalidWrite(uint256 actorSeed, uint8 modeSeed) external {
        address who = _actor(actorSeed);
        uint256 mode = modeSeed % 5;
        uint32 epoch = expectedEpoch[who];
        bytes[] memory notes = _notes(2, 1);
        bytes memory reason;
        if (mode == 0) {
            epoch ^= 1;
            reason = abi.encodeWithSelector(MnemoVault.WrongEpoch.selector, expectedEpoch[who], epoch);
        } else if (mode == 1) {
            notes = new bytes[](0);
            reason = abi.encodeWithSelector(MnemoVault.NoNotes.selector);
        } else if (mode == 2) {
            notes = _notes(17, 1);
            reason = abi.encodeWithSelector(MnemoVault.TooManyNotes.selector, 17);
        } else if (mode == 3) {
            notes[1] = hex"";
            reason = abi.encodeWithSelector(MnemoVault.EmptyNote.selector, 1);
        } else {
            notes[1] = new bytes(2049);
            reason = abi.encodeWithSelector(MnemoVault.NoteTooLong.selector, 1, 2049);
        }
        vm.prank(who);
        vm.expectRevert(reason);
        vault.write(notes, epoch);
        ++rejectedWrites;
    }

    function forget(uint256 actorSeed, uint256 idSeed, bool rightfulOwner, bool duplicate) external {
        uint256 id = bound(idSeed, 0, expectedNotes + 1);
        address who = rightfulOwner && expectedNoteOwner[id] != address(0) ? expectedNoteOwner[id] : _actor(actorSeed);
        uint256[] memory ids = new uint256[](duplicate ? 2 : 1);
        ids[0] = id;
        if (duplicate) ids[1] = id;
        bool rejected = duplicate || expectedNoteOwner[id] != who;
        if (rejected) vm.expectRevert(abi.encodeWithSelector(MnemoVault.NotNoteOwner.selector, id));
        vm.prank(who);
        vault.forget(ids);
        if (!rejected) {
            delete expectedNoteOwner[id];
            --expectedLive;
            ++successfulForgets;
        }
    }

    function rotate(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        vm.prank(who);
        vault.rotate();
        ++expectedEpoch[who];
    }

    function registerKey(uint256 actorSeed, bytes32 key) external {
        address who = _actor(actorSeed);
        if (key == bytes32(0)) vm.expectRevert(MnemoVault.ZeroKey.selector);
        vm.prank(who);
        vault.register(key);
        if (key != bytes32(0)) expectedKey[who] = key;
    }

    function grant(uint256 ownerSeed, uint256 agentSeed, bool emptyKey) external {
        address owner_ = _actor(ownerSeed);
        address agent = _actor(agentSeed);
        bytes memory reason;
        if (owner_ == agent) {
            reason = abi.encodeWithSelector(MnemoVault.SelfGrant.selector);
        } else if (expectedKey[agent] == bytes32(0)) {
            reason = abi.encodeWithSelector(MnemoVault.AgentNotRegistered.selector, agent);
        } else if (emptyKey) {
            reason = abi.encodeWithSelector(MnemoVault.EmptySealedKey.selector);
        } else if (expectedGrant[owner_][agent]) {
            reason = abi.encodeWithSelector(MnemoVault.AlreadyGranted.selector, owner_, agent);
        }
        bytes memory sealedKey = emptyKey ? bytes("") : bytes(hex"123456");
        if (reason.length != 0) vm.expectRevert(reason);
        vm.prank(owner_);
        vault.grant(agent, sealedKey);
        if (reason.length == 0) expectedGrant[owner_][agent] = true;
    }

    function revoke(uint256 ownerSeed, uint256 agentSeed) external {
        address owner_ = _actor(ownerSeed);
        address agent = _actor(agentSeed);
        bool granted = expectedGrant[owner_][agent];
        if (!granted) vm.expectRevert(abi.encodeWithSelector(MnemoVault.NotGranted.selector, owner_, agent));
        vm.prank(owner_);
        vault.revoke(agent);
        if (granted) {
            expectedGrant[owner_][agent] = false;
            ++expectedEpoch[owner_];
        }
    }

    function setStamp(uint256 value, bool invalid) external {
        if (invalid) {
            value = value % 2 == 0 ? bound(value, 0, 100e18 - 1) : bound(value, 100_000e18 + 1, type(uint256).max);
            vm.expectRevert(abi.encodeWithSelector(MnemoVault.StampOutOfRange.selector, value));
        } else {
            value = bound(value, 100e18, 100_000e18);
        }
        vm.prank(expectedOwner);
        vault.setStamp(value);
        if (!invalid) expectedStamp = value;
    }

    function nominateOwner(uint256 candidateSeed, bool cancel) external {
        address candidate = cancel ? address(0) : _actor(candidateSeed);
        vm.prank(expectedOwner);
        vault.transferOwnership(candidate);
        expectedPendingOwner = candidate;
    }

    function acceptOwner(uint256 actorSeed, bool useNominee) external {
        address who = useNominee && expectedPendingOwner != address(0) ? expectedPendingOwner : _actor(actorSeed);
        bool entitled = who == expectedPendingOwner;
        if (!entitled) vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who));
        vm.prank(who);
        vault.acceptOwnership();
        if (entitled) {
            expectedOwner = who;
            expectedPendingOwner = address(0);
        }
    }

    function forbiddenAdmin(uint256 actorSeed, uint8 modeSeed) external {
        address who = _actor(actorSeed);
        if (who == expectedOwner) who = _actor((actorSeed % 4) + 1);
        uint256 mode = modeSeed % 4;
        if (mode == 3) {
            vm.prank(expectedOwner);
            vm.expectRevert(MnemoVault.RenounceDisabled.selector);
            vault.renounceOwnership();
            return;
        }
        vm.prank(who);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who));
        if (mode == 0) vault.setStamp(100e18);
        else if (mode == 1) vault.transferOwnership(who);
        else vault.renounceOwnership();
    }

    function approve(uint256 actorSeed, uint256 spenderSeed, uint256 amount, bool unlimited) external {
        address who = _actor(actorSeed);
        address spender = spenderSeed % 5 == 4 ? address(vault) : _actor(spenderSeed);
        amount = unlimited ? type(uint256).max : bound(amount, 0, SUPPLY);
        vm.prank(who);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[who][spender] = amount;
    }

    function transfer(uint256 senderSeed, uint256 recipientSeed, uint256 amount) external {
        address from = _actor(senderSeed);
        address to = _recipient(recipientSeed);
        amount = bound(amount, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _move(from, to, amount);
    }

    function transferFrom(uint256 holderSeed, uint256 spenderSeed, uint256 recipientSeed, uint256 amount) external {
        address from = _actor(holderSeed);
        address spender = _actor(spenderSeed);
        address to = _recipient(recipientSeed);
        amount = bound(amount, 0, expectedBalance[from] + 1);
        bytes memory reason;
        if (expectedAllowance[from][spender] < amount) {
            reason = abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, spender, expectedAllowance[from][spender], amount
            );
        } else if (expectedBalance[from] < amount) {
            reason = abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, from, expectedBalance[from], amount
            );
        }
        if (reason.length != 0) vm.expectRevert(reason);
        vm.prank(spender);
        bool ok = token.transferFrom(from, to, amount);
        if (reason.length == 0) {
            assertTrue(ok);
            _move(from, to, amount);
            _spend(from, spender, amount);
        }
    }

    function _move(address from, address to, uint256 amount) internal {
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function _spend(address from, address spender, uint256 amount) internal {
        if (expectedAllowance[from][spender] != type(uint256).max) expectedAllowance[from][spender] -= amount;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 4];
    }

    function _recipient(uint256 seed) internal view returns (address) {
        seed %= 6;
        if (seed == 4) return DEAD;
        if (seed == 5) return address(vault);
        return actors[seed];
    }

    function _notes(uint256 count, uint256 size) internal pure returns (bytes[] memory notes) {
        notes = new bytes[](count);
        for (uint256 i; i < count; ++i) {
            notes[i] = new bytes(size);
            notes[i][0] = bytes1(uint8(i + 1));
            notes[i][size - 1] = 0xff;
        }
    }
}
