// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {MnemoVault} from "src/MnemoVault.sol";

/// @dev Test actors are local fixtures, never deployment configuration.
abstract contract MnemoTestFixture is Test {
    LaunchToken internal token;
    MnemoVault internal vault;
    address internal factory = makeAddr("test factory");
    address internal admin = makeAddr("test launch owner");
    address internal alice = makeAddr("test alice");
    address internal bob = makeAddr("test bob");
    address internal agent = makeAddr("test agent");
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant STAMP = 2_000e18;
    uint256 internal constant FUNDS = 10_000_000e18;

    event Noted(address indexed owner, uint256 indexed id, uint32 epoch, bytes ciphertext);
    event Forgotten(address indexed owner, uint256 indexed id);
    event Rotated(address indexed owner, uint32 epoch);
    event Granted(address indexed owner, address indexed agent, uint32 epoch, bytes sealedKey);
    event Revoked(address indexed owner, address indexed agent);
    event KeyRegistered(address indexed account, bytes32 key);
    event StampChanged(uint256 oldStamp, uint256 newStamp);
    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public virtual {
        vm.prank(factory);
        token = new LaunchToken();
        vm.prank(factory);
        vault = new MnemoVault(address(token), admin);
        address[3] memory actors = [alice, bob, agent];
        for (uint256 i; i < actors.length; ++i) {
            vm.prank(factory);
            token.transfer(actors[i], FUNDS);
            vm.prank(actors[i]);
            token.approve(address(vault), type(uint256).max);
        }
    }

    function _notes(uint256 count, uint256 length) internal pure returns (bytes[] memory notes) {
        notes = new bytes[](count);
        for (uint256 i; i < count; ++i) {
            notes[i] = new bytes(length);
            if (length != 0) {
                notes[i][0] = bytes1(uint8(i + 1));
                notes[i][length - 1] = 0xff;
            }
        }
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _grant(address owner_, address agent_) internal {
        vm.prank(agent_);
        vault.register(keccak256(abi.encode(agent_)));
        vm.prank(owner_);
        vault.grant(agent_, hex"123456");
    }

    function _write(address payer, bool delegated, bytes[] memory notes, uint32 epoch) internal returns (uint256) {
        vm.prank(payer);
        if (delegated) return vault.writeFor(alice, notes, epoch);
        return vault.write(notes, epoch);
    }

    function _assertPristineAccounting() internal view {
        assertEq(vault.notesTotal(), 0);
        assertEq(vault.burnedTotal(), 0);
        assertEq(vault.noteOwnerOf(1), address(0));
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(alice), FUNDS);
        assertEq(token.balanceOf(agent), FUNDS);
    }
}
