// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickTockState} from "../src/base/TickTockState.sol";
import {OrderMath} from "../src/libraries/OrderMath.sol";
import {TickTockHook} from "../src/TickTockHook.sol";
import {TickTockTestBase} from "./utils/TickTockTestBase.sol";

/// @notice Merges between the two sides of one strategy (DESIGN.md section 6). Strategy (S = 100, spread 50): the
/// ask slot is at 100 and the bid slot at 50.
contract MergesTest is TickTockTestBase {
    using PoolIdLibrary for PoolKey;

    TickTockHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;
    address internal dave = makeAddr("dave");

    function setUp() public override {
        super.setUp();
        hook = _createHook(10, _spreads(10, 50, 100));
        poolKey = _key(hook, 0);
        poolId = poolKey.toId();
        _fund(alice, hook);
        _fund(bob, hook);
        _fund(carol, hook);
        _fund(dave, hook);
    }

    function _ask(address user, uint128 amount) internal returns (uint64 groupId) {
        (groupId,) = _deposit(hook, poolKey, user, 100, 1, true, amount);
    }

    function _bid(address user, uint128 amount) internal returns (uint64 groupId) {
        (groupId,) = _deposit(hook, poolKey, user, 100, 1, false, amount);
    }

    function _up() internal {
        _swapToTick(poolKey, 101);
        hook.flipLevel(poolKey, 100);
    }

    function _down() internal {
        _swapToTick(poolKey, 50);
        hook.flipLevel(poolKey, 50);
    }

    /// The token1 an ask of `amount0` at 100 converts into.
    function _sold(uint256 amount0) internal pure returns (uint256) {
        (uint160 lower, uint160 upper) = OrderMath.bounds(100);
        return OrderMath.amount1ForLiquidity(lower, upper, uint128(_askLiquidity(100, amount0)), false);
    }

    function test_waitingOlderGroupSurvives() public {
        uint64 bobGroup = _bid(bob, 1e18);
        uint64 aliceGroup = _ask(alice, 1e18);
        uint256 bobShares = hook.sharesOf(bob, bobGroup);

        _swapToTick(poolKey, 101);
        vm.expectEmit(true, true, false, false, address(hook));
        emit TickTockState.GroupsMerged(bobGroup, aliceGroup, 0);
        hook.flipLevel(poolKey, 100);

        TickTockState.Group memory survivor = hook.getGroup(bobGroup);
        TickTockState.Group memory absorbed = hook.getGroup(aliceGroup);
        assertEq(hook.slotGroup(poolId, 50, true, 1), bobGroup);
        assertEq(survivor.mergedInto, 0);
        assertEq(absorbed.mergedInto, bobGroup);
        assertEq(hook.resolveGroup(aliceGroup), bobGroup);
        assertEq(survivor.totalShares, bobShares + absorbed.mergedShares);
        assertEq(absorbed.liquidity, 0);
        assertEq(absorbed.pending0 + absorbed.pending1, 0);

        // Each side keeps its value: Alice's sold token0, Bob's token1.
        (uint256 alice0, uint256 alice1) = hook.positionOf(alice, aliceGroup);
        (uint256 bob0, uint256 bob1) = hook.positionOf(bob, bobGroup);
        assertEq(alice0 + bob0, 0);
        assertApproxEqAbs(alice1, _sold(1e18), 3);
        assertApproxEqAbs(bob1, 1e18, 3);

        // Withdrawing through the absorbed id converts Alice's shares on the way.
        uint256 aliceShares = hook.sharesOf(alice, aliceGroup);
        vm.expectEmit(true, true, true, false, address(hook));
        emit TickTockState.SharesConverted(alice, aliceGroup, bobGroup, aliceShares, 0);
        (, uint256 out1) = _withdrawAll(hook, alice, aliceGroup);
        assertEq(out1, alice1);
        assertEq(hook.sharesOf(alice, aliceGroup), 0);
        assertEq(hook.sharesOf(alice, bobGroup), 0);

        (, out1) = _withdrawAll(hook, bob, bobGroup);
        assertEq(out1, bob1);
        assertEq(hook.slotGroup(poolId, 50, true, 1), 0, "the slot is free once everyone left");
    }

    function test_arrivingOlderGroupSurvives() public {
        uint64 aliceGroup = _ask(alice, 1e18);
        uint64 bobGroup = _bid(bob, 1e18);
        _up();

        assertEq(hook.slotGroup(poolId, 50, true, 1), aliceGroup);
        assertTrue(hook.getGroup(aliceGroup).isBid);
        assertEq(hook.getGroup(aliceGroup).mergedInto, 0);
        assertEq(hook.getGroup(bobGroup).mergedInto, aliceGroup);

        (, uint256 bob1) = _withdrawAll(hook, bob, bobGroup);
        (, uint256 alice1) = _withdrawAll(hook, alice, aliceGroup);
        assertApproxEqAbs(bob1, 1e18, 3);
        assertApproxEqAbs(alice1, _sold(1e18), 3);
    }

    /// A partial withdrawal through an absorbed id converts the whole balance, then withdraws the part asked for.
    function test_partialWithdrawalFromAnAbsorbedGroup() public {
        uint64 bobGroup = _bid(bob, 1e18);
        uint64 aliceGroup = _ask(alice, 1e18);
        _up();

        uint256 aliceShares = hook.sharesOf(alice, aliceGroup);
        (, uint256 total1) = hook.positionOf(alice, aliceGroup);
        vm.prank(alice);
        (, uint256 half1) = hook.withdraw(aliceGroup, aliceShares / 2, alice, block.timestamp);

        assertApproxEqRel(half1, total1 / 2, 1e12);
        assertEq(hook.sharesOf(alice, aliceGroup), 0);
        uint256 rest = hook.sharesOf(alice, bobGroup);
        assertGt(rest, 0);
        vm.prank(alice);
        (, uint256 rest1) = hook.withdraw(bobGroup, rest, alice, block.timestamp);
        assertApproxEqAbs(half1 + rest1, total1, 3);
    }

    /// Repeated cycles of new groups merging into the same strategy never chain: every absorbed group points
    /// straight at the oldest one, which is never absorbed itself.
    function test_repeatedMergesStayOneHop() public {
        uint64 g1 = _bid(bob, 1e18);
        uint64 g2 = _ask(alice, 1e18);
        _up(); // g2 merges into g1, at the bid slot
        _down(); // g1 flips to the ask slot

        uint64 g3 = _bid(carol, 1e18);
        _up(); // g1 arrives at the bid slot, absorbs g3
        _down();

        uint64 g4 = _bid(dave, 1e18);
        _up(); // and g4

        assertEq(hook.getGroup(g1).mergedInto, 0);
        assertEq(hook.getGroup(g2).mergedInto, g1);
        assertEq(hook.getGroup(g3).mergedInto, g1);
        assertEq(hook.getGroup(g4).mergedInto, g1);
        assertEq(hook.slotGroup(poolId, 50, true, 1), g1);

        // Everyone gets out, and only rounding dust stays behind.
        _withdrawAll(hook, alice, g2);
        _withdrawAll(hook, carol, g3);
        _withdrawAll(hook, dave, g4);
        _withdrawAll(hook, bob, g1);
        assertEq(_positionLiquidity(hook, poolKey, 50), 0);
        assertEq(_positionLiquidity(hook, poolKey, 100), 0);
        assertLe(manager.balanceOf(address(hook), currency0.toId()), 10);
        assertLe(manager.balanceOf(address(hook), currency1.toId()), 10);
    }

    /// Value is conserved across a merge cycle: what everyone takes out matches what their tokens became.
    function test_mergeConservesValue() public {
        uint64 g1 = _bid(bob, 1e18);
        uint64 g2 = _ask(alice, 1e18);
        _up();
        _down(); // the merged group bought token0 at 50 with everything
        (uint160 lower, uint160 upper) = OrderMath.bounds(50);
        uint256 merged1 = 1e18 + _sold(1e18);
        uint256 expected0 = OrderMath.amount0ForLiquidity(lower, upper, uint128(_bidLiquidity(50, merged1)), false);

        (uint256 alice0,) = _withdrawAll(hook, alice, g2);
        (uint256 bob0,) = _withdrawAll(hook, bob, g1);
        assertApproxEqAbs(alice0 + bob0, expected0, 10);
        // Shares split it by what each brought in.
        assertApproxEqRel(alice0 * 1e18, bob0 * _sold(1e18), 1e12);
    }
}
