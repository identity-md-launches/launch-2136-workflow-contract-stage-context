// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {MnemoVault} from "src/MnemoVault.sol";
import {MnemoModelHandler} from "./helpers/MnemoModelHandler.sol";

/// @notice Model-based tests for the approved write, burn, access and fixed-supply guarantees.
/// @dev Only the 15 listed handlers are fuzz targets. Expected reverts are asserted inside them;
/// any unexpected revert fails the campaign, instead of silently discarding an operation.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract MnemoVaultStatefulTest is Test {
    LaunchToken internal token;
    MnemoVault internal vault;
    MnemoModelHandler internal handler;
    address[4] internal actors;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        token = new LaunchToken();
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("model actor ", vm.toString(i)));
        }
        vault = new MnemoVault(address(token), actors[0]);
        for (uint256 i; i < 4; ++i) {
            token.transfer(actors[i], 1e27 / 4);
            vm.prank(actors[i]);
            token.approve(address(vault), type(uint256).max);
        }
        handler = new MnemoModelHandler(token, vault, actors);
        for (uint256 i; i < 4; ++i) {
            handler.registerKey(i, bytes32(i + 1));
        }
        handler.grant(0, 1, false);
        handler.grant(2, 3, false);
        handler.writeSelf(0, 1, 1);
        handler.writeAsAgent(2, 3, 2, 1);
        // Seed direct donations so zero-custody or dead-balance-equals-burn assumptions cannot pass.
        handler.transfer(3, 4, 1);
        handler.transfer(3, 5, 1);

        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = MnemoModelHandler.writeSelf.selector;
        selectors[1] = MnemoModelHandler.writeAsAgent.selector;
        selectors[2] = MnemoModelHandler.invalidWrite.selector;
        selectors[3] = MnemoModelHandler.forget.selector;
        selectors[4] = MnemoModelHandler.rotate.selector;
        selectors[5] = MnemoModelHandler.registerKey.selector;
        selectors[6] = MnemoModelHandler.grant.selector;
        selectors[7] = MnemoModelHandler.revoke.selector;
        selectors[8] = MnemoModelHandler.setStamp.selector;
        selectors[9] = MnemoModelHandler.nominateOwner.selector;
        selectors[10] = MnemoModelHandler.acceptOwner.selector;
        selectors[11] = MnemoModelHandler.forbiddenAdmin.selector;
        selectors[12] = MnemoModelHandler.approve.selector;
        selectors[13] = MnemoModelHandler.transfer.selector;
        selectors[14] = MnemoModelHandler.transferFrom.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_balancesAllowancesAndFixedSupply() public view {
        uint256 sum;
        uint256 paid;
        for (uint256 i; i < 4; ++i) {
            address actor = actors[i];
            assertEq(token.balanceOf(actor), handler.expectedBalance(actor), "actor balance");
            sum += token.balanceOf(actor);
            paid += handler.stampsPaid(actor);
            assertEq(
                token.allowance(actor, address(vault)),
                handler.expectedAllowance(actor, address(vault)),
                "vault allowance"
            );
            for (uint256 j; j < 4; ++j) {
                assertEq(
                    token.allowance(actor, actors[j]), handler.expectedAllowance(actor, actors[j]), "peer allowance"
                );
            }
        }
        assertEq(token.balanceOf(DEAD), handler.expectedBalance(DEAD), "stamps plus direct burn donations");
        assertEq(token.balanceOf(address(vault)), handler.expectedBalance(address(vault)), "direct vault donations");
        sum += token.balanceOf(DEAD) + token.balanceOf(address(vault));
        assertEq(sum, 1e27, "sum of every reachable token balance");
        assertEq(token.totalSupply(), 1e27, "fixed supply even after stamp burns");
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(vault.burnedTotal(), handler.expectedBurned(), "historical burn accounting");
        assertEq(vault.burnedTotal(), paid, "only the actual writers pay");
        assertGe(token.balanceOf(DEAD), paid, "direct donations are not vault revenue");
        assertGe(paid, vault.notesTotal() * 100e18);
        assertLe(paid, vault.notesTotal() * 100_000e18);
    }

    function invariant_notesHaveUniqueIdsAndOnlyOwnersCanForgetThem() public view {
        uint256 total = handler.expectedNotes();
        uint256 live;
        assertEq(vault.notesTotal(), total);
        assertEq(vault.noteOwnerOf(0), address(0));
        assertEq(vault.noteOwnerOf(total + 1), address(0));
        // Includes forgotten ids forever: a later write must never resurrect one.
        for (uint256 id = 1; id <= total; ++id) {
            address expected = handler.expectedNoteOwner(id);
            assertEq(vault.noteOwnerOf(id), expected, "live and forgotten note ownership");
            if (expected != address(0)) ++live;
        }
        assertEq(live, handler.expectedLive());
        assertEq(live + handler.successfulForgets(), total);
    }

    function invariant_grantsEpochsKeysAndAdminAreIndependent() public view {
        assertEq(vault.owner(), handler.expectedOwner());
        assertTrue(vault.owner() != address(0));
        assertEq(vault.pendingOwner(), handler.expectedPendingOwner());
        assertEq(vault.stamp(), handler.expectedStamp());
        assertGe(vault.stamp(), 100e18);
        assertLe(vault.stamp(), 100_000e18);
        for (uint256 i; i < 4; ++i) {
            assertEq(vault.epochOf(actors[i]), handler.expectedEpoch(actors[i]));
            assertEq(vault.keyOf(actors[i]), handler.expectedKey(actors[i]));
            for (uint256 j; j < 4; ++j) {
                assertEq(vault.isGranted(actors[i], actors[j]), handler.expectedGrant(actors[i], actors[j]));
            }
        }
    }

    /// @dev A fixed replay demonstrates reachable successful and failed branches before fuzzing.
    function test_modelReplayCoversRevokeRegrantAllowanceFailureAndOwnerHandoff() public {
        handler.forget(0, 1, true, true); // Duplicate rolls back the first deletion.
        _checkAll();
        handler.forget(0, 1, true, false);
        _checkAll();
        handler.rotate(0);
        handler.invalidWrite(0, 0);
        handler.writeSelf(0, 16, 2048);
        _checkAll();
        handler.revoke(0, 1);
        handler.writeAsAgent(0, 1, 1, 1);
        _checkAll();
        handler.grant(0, 1, false);
        handler.approve(1, 4, 0, false);
        handler.writeAsAgent(0, 1, 1, 1);
        _checkAll();
        handler.approve(1, 4, 2_000e18, false);
        handler.writeAsAgent(0, 1, 1, 1);
        _checkAll();
        handler.nominateOwner(1, false);
        handler.acceptOwner(1, true);
        handler.forbiddenAdmin(0, 0);
        handler.setStamp(100_000e18, false);
        handler.writeSelf(0, 2, 1);
        _checkAll();
        handler.approve(0, 2, 100, false);
        handler.transferFrom(0, 2, 3, 100);
        handler.transferFrom(0, 2, 3, 1);
        handler.registerKey(1, bytes32(0));
        handler.setStamp(type(uint256).max, true);
        _checkAll();
        assertGt(handler.successfulWrites(), 2);
        assertEq(handler.successfulForgets(), 1);
        assertGe(handler.rejectedWrites(), 3);
        assertEq(vault.owner(), actors[1]);
    }

    function _checkAll() internal view {
        invariant_balancesAllowancesAndFixedSupply();
        invariant_notesHaveUniqueIdsAndOnlyOwnersCanForgetThem();
        invariant_grantsEpochsKeysAndAdminAreIndependent();
    }
}
