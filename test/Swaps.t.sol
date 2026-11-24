// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickTockState} from "../src/base/TickTockState.sol";
import {OrderMath} from "../src/libraries/OrderMath.sol";
import {TickTockHook} from "../src/TickTockHook.sol";
import {TickTockTestBase} from "./utils/TickTockTestBase.sol";

/// @notice Flips done by swaps: the budget, the skip rule and the cursors (DESIGN.md section 5.3). The test factory's
/// budget is 24 operations, so a level with one spread (1 removal + 1 addition) costs 2 and 12 fit in one swap.
contract SwapsTest is TickTockTestBase {
    using PoolIdLibrary for PoolKey;

    TickTockHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public override {
        super.setUp();
        hook = _createHook(10, _spreads(10, 50, 100));
        poolKey = _key(hook, 0);
        poolId = poolKey.toId();
        _fund(alice, hook);
        _fund(bob, hook);
        _fund(carol, hook);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // One level
    // ---------------------------------------------------------------------------------------------------------------

    function test_upwardSwapFlipsTheAsksItCrosses() public {
        (uint64 groupId,) = _deposit(hook, poolKey, alice, 100, 1, true, 1e18);
        _swapToTick(poolKey, 101);

        assertTrue(hook.getGroup(groupId).isBid);
        assertEq(hook.slotGroup(poolId, 50, true, 1), groupId);
        assertEq(hook.getPool(poolId).askCursor, 101);
        assertEq(hook.getPool(poolId).bidCursor, 101);
    }

    function test_downwardSwapFlipsTheBidsItCrosses() public {
        (uint64 groupId,) = _deposit(hook, poolKey, bob, 100, 1, false, 1e18); // bid at 50
        _swapToTick(poolKey, 50);

        assertFalse(hook.getGroup(groupId).isBid);
        assertEq(hook.slotGroup(poolId, 100, false, 1), groupId);
        assertEq(hook.getPool(poolId).bidCursor, 50);
        assertEq(hook.getPool(poolId).askCursor, 50);
    }

    function test_swapStoppingInsideALevelDoesNotFlipIt() public {
        (uint64 groupId,) = _deposit(hook, poolKey, alice, 100, 1, true, 1e18);
        (, uint160 upper) = OrderMath.bounds(100);
        _swapTo(poolKey, upper - 1);

        assertFalse(hook.getGroup(groupId).isBid);
        assertEq(hook.getPool(poolId).askCursor, 100, "the next scan starts at the level the price is in");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Budget and leftovers
    // ---------------------------------------------------------------------------------------------------------------

    /// 20 asks of the same size at 100, 110, ..., 290, one spread each. Returns their groups.
    function _twentyAsks() internal returns (uint64[20] memory groups) {
        for (uint256 i = 0; i < 20; ++i) {
            (groups[i],) = _deposit(hook, poolKey, alice, int24(int256(100 + 10 * i)), 0, true, 1e18);
        }
    }

    function _flipped(uint64 groupId) internal view returns (bool) {
        return hook.getGroup(groupId).isBid;
    }

    /// Levels of similar size are never skipped: the budget flips the first 12, the other 8 wait, and
    /// `flipCrossed` finishes them.
    function test_budgetLeavesLeftoversForFlipCrossed() public {
        uint64[20] memory groups = _twentyAsks();
        vm.recordLogs();
        _swapToTick(poolKey, 300);
        assertEq(_count(vm.getRecordedLogs(), TickTockState.LevelSkipped.selector), 0, "nothing skipped");

        for (uint256 i = 0; i < 20; ++i) {
            assertEq(_flipped(groups[i]), i < 12);
        }
        assertEq(hook.getPool(poolId).askCursor, 220, "the first level the budget didn't reach");

        assertEq(hook.flipCrossed(poolKey, 100), 16);
        for (uint256 i = 0; i < 20; ++i) {
            assertTrue(_flipped(groups[i]));
        }
        assertEq(hook.getPool(poolId).askCursor, 300);
        assertEq(hook.flipCrossed(poolKey, 100), 0, "nothing left");
    }

    function test_nextSwapInTheSameDirectionPicksUpLeftovers() public {
        uint64[20] memory groups = _twentyAsks();
        _swapToTick(poolKey, 300);
        _swapToTick(poolKey, 310); // through empty space
        for (uint256 i = 0; i < 20; ++i) {
            assertTrue(_flipped(groups[i]));
        }
        assertEq(hook.getPool(poolId).askCursor, 310);
    }

    /// A level the budget didn't reach is still a normal position: if the price comes back, it un-fills at the same
    /// price and the user loses nothing. The next swap up flips it.
    function test_leftoverUnfillsWhenThePriceComesBack() public {
        uint64[20] memory groups = _twentyAsks();
        _swapToTick(poolKey, 300);
        _swapToTick(poolKey, 215); // back down through the 8 leftovers, above the new bids

        assertEq(hook.getPool(poolId).askCursor, 215);
        (uint256 amount0, uint256 amount1) = hook.positionOf(alice, groups[15]);
        assertApproxEqAbs(amount0, 1e18, 2, "the order is whole again");
        assertEq(amount1, 0);

        _swapToTick(poolKey, 300);
        for (uint256 i = 0; i < 20; ++i) {
            assertTrue(_flipped(groups[i]));
        }
    }

    /// The same with bids, going down: the highest 12 flip, the lowest 8 wait.
    function test_budgetOnTheBidSide() public {
        uint64[20] memory groups;
        for (uint256 i = 0; i < 20; ++i) {
            // Bid at 100 + 10i, strategy sell level 10 above it.
            (groups[i],) = _deposit(hook, poolKey, bob, int24(int256(110 + 10 * i)), 0, false, 1e18);
        }
        _swapToTick(poolKey, 99);

        for (uint256 i = 0; i < 20; ++i) {
            assertEq(!hook.getGroup(groups[i]).isBid, i >= 8);
        }
        assertEq(hook.getPool(poolId).bidCursor, 170);
        assertEq(hook.flipCrossed(poolKey, 100), 16);
        assertEq(hook.getPool(poolId).bidCursor, 99);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Skipping small levels
    // ---------------------------------------------------------------------------------------------------------------

    /// Dust on the 15 levels nearest the price would use up the budget (4 operations each) if it were flipped. It's
    /// small next to the real order crossed with it, so it's skipped, and the real order flips in the same swap.
    function test_dustIsSkippedAndTheRealOrderFlips() public {
        uint64[15] memory dust;
        for (uint256 i = 0; i < 15; ++i) {
            for (uint8 k = 0; k < 3; ++k) {
                (uint64 g,) = _deposit(hook, poolKey, bob, int24(int256(100 + 10 * i)), k, true, 1e10);
                if (k == 0) dust[i] = g;
            }
        }
        (uint64 real,) = _deposit(hook, poolKey, alice, 250, 0, true, 1e18);

        vm.recordLogs();
        _swapToTick(poolKey, 251);
        assertEq(_count(vm.getRecordedLogs(), TickTockState.LevelSkipped.selector), 15);

        assertTrue(_flipped(real));
        for (uint256 i = 0; i < 15; ++i) {
            assertFalse(_flipped(dust[i]), "dust still crossed");
        }
        assertEq(hook.getPool(poolId).askCursor, 251, "the scan passed over the dust");

        // Anyone can flip a skipped level.
        hook.flipLevel(poolKey, 100);
        assertTrue(_flipped(dust[0]));
        assertEq(hook.getLevel(poolId, 100).askMask, 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Cursors after the hook's own price moves
    // ---------------------------------------------------------------------------------------------------------------

    function test_movePriceDownKeepsLowerAsksInTheScan() public {
        (uint64 a,) = _deposit(hook, poolKey, alice, 100, 1, true, 1e18);
        hook.movePrice(poolKey, _sqrt(-500));
        (uint64 b,) = _deposit(hook, poolKey, bob, -400, 1, true, 1e18);

        _swapToTick(poolKey, 101);
        assertTrue(_flipped(a));
        assertTrue(_flipped(b));
    }

    function test_movePriceUpKeepsHigherBidsInTheScan() public {
        (uint64 a,) = _deposit(hook, poolKey, alice, 100, 1, false, 1e18); // bid at 50
        hook.movePrice(poolKey, _sqrt(500));
        (uint64 b,) = _deposit(hook, poolKey, bob, 450, 1, false, 1e18); // bid at 400

        _swapToTick(poolKey, 50);
        assertFalse(hook.getGroup(a).isBid);
        assertFalse(hook.getGroup(b).isBid);
    }

    function test_depositNudgeKeepsTheNewAskInTheScan() public {
        (uint64 a,) = _deposit(hook, poolKey, alice, 100, 1, true, 1e18);
        (uint64 b,) = _deposit(hook, poolKey, bob, 60, 1, true, 1e18); // nudges the price down to 60
        _swapToTick(poolKey, 101);
        assertTrue(_flipped(a));
        assertTrue(_flipped(b));
    }

    function test_flipCrossedRefusesUnknownPools() public {
        vm.expectRevert(TickTockState.PoolNotFound.selector);
        hook.flipCrossed(poolKey, 10);
    }

    function _count(Vm.Log[] memory logs, bytes32 topic) internal view returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == topic) ++n;
        }
    }
}
