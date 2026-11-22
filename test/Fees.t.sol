// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {OrderMath} from "../src/libraries/OrderMath.sol";
import {TickTockHook} from "../src/TickTockHook.sol";
import {TickTockTestBase} from "./utils/TickTockTestBase.sol";

contract FeesTest is TickTockTestBase {
    using PoolIdLibrary for PoolKey;

    int24 internal constant LEVEL = 100;
    uint256 internal constant FEE_PIPS = 3000;

    TickTockHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public override {
        super.setUp();
        hook = _createHook(10, _spreads(10, 50, 100));
        poolKey = _key(hook, uint24(FEE_PIPS));
        poolId = poolKey.toId();
        _fund(alice, hook);
        _fund(bob, hook);
    }

    /// The price goes 99% of the way through the level and comes back, so nothing flips: the swaps pay fees in
    /// token1, then token0.
    function _roundTrip() internal returns (uint256 input1, uint256 input0) {
        (uint160 lower, uint160 upper) = OrderMath.bounds(LEVEL);
        BalanceDelta up = _swapTo(poolKey, upper - (upper - lower) / 100);
        BalanceDelta down = _swapTo(poolKey, lower);
        input1 = uint256(int256(-up.amount1()));
        input0 = uint256(int256(-down.amount0()));
    }

    function _value(uint256 amount0, uint256 amount1) internal pure returns (uint256) {
        (uint160 lower, uint160 upper) = OrderMath.bounds(LEVEL);
        return OrderMath.value(lower, upper, 0, amount0, amount1, false);
    }

    function test_oneGroupEarnsAllTheFees() public {
        (uint64 groupId,) = _deposit(hook, poolKey, alice, LEVEL, 0, true, 1e18);
        (uint256 input1, uint256 input0) = _roundTrip();

        (uint256 amount0, uint256 amount1) = _withdrawAll(hook, alice, groupId);
        // The order un-filled back to token0. Each swap paid FEE_PIPS of its input to the level.
        assertApproxEqRel(amount1, input1 * FEE_PIPS / 1e6, 1e12, "token1 fees");
        assertApproxEqRel(amount0 - 1e18, input0 * FEE_PIPS / 1e6, 1e12, "token0 fees");
    }

    /// `positionOf` counts the fees the position earned but hasn't collected yet.
    function test_positionOfIncludesUncollectedFees() public {
        (uint64 groupId,) = _deposit(hook, poolKey, alice, LEVEL, 0, true, 1e18);
        _roundTrip();

        (uint256 expected0, uint256 expected1) = hook.positionOf(alice, groupId);
        assertGt(expected1, 0);
        (uint256 amount0, uint256 amount1) = _withdrawAll(hook, alice, groupId);
        assertEq(amount0, expected0);
        assertEq(amount1, expected1);
    }

    /// A group created after fees were earned at its level gets none of them.
    function test_newGroupDoesNotShareEarlierFees() public {
        (uint64 aliceGroup,) = _deposit(hook, poolKey, alice, LEVEL, 0, true, 1e18);
        _roundTrip();
        (uint64 bobGroup,) = _deposit(hook, poolKey, bob, LEVEL, 1, true, 1e18); // same level, other spread
        assertTrue(bobGroup != aliceGroup);

        (uint256 bob0, uint256 bob1) = _withdrawAll(hook, bob, bobGroup);
        assertApproxEqAbs(bob0, 1e18, 2);
        assertEq(bob1, 0);
        (, uint256 alice1) = _withdrawAll(hook, alice, aliceGroup);
        assertGt(alice1, 0);
    }

    /// Groups at the same level share its fees by liquidity.
    function test_groupsAtOneLevelSplitByLiquidity() public {
        (uint64 aliceGroup,) = _deposit(hook, poolKey, alice, LEVEL, 0, true, 1e18);
        (uint64 bobGroup,) = _deposit(hook, poolKey, bob, LEVEL, 1, true, 3e18);
        _roundTrip();

        (uint256 alice0, uint256 alice1) = _withdrawAll(hook, alice, aliceGroup);
        (uint256 bob0, uint256 bob1) = _withdrawAll(hook, bob, bobGroup);
        assertApproxEqRel(bob1, 3 * alice1, 1e12);
        assertApproxEqRel(bob0 - 3e18, 3 * (alice0 - 1e18), 1e12);
    }

    /// A late joiner buys a fair slice of the group, pending fees included, and from then on every unit of value
    /// earns the same: both holders' values grow by the same factor.
    function test_lateJoinerAndEarlyHolderGrowAlike() public {
        (uint64 groupId,) = _deposit(hook, poolKey, alice, LEVEL, 0, true, 1e18);
        _roundTrip();
        (uint256 a0, uint256 a1) = hook.positionOf(alice, groupId);
        uint256 aliceBefore = _value(a0, a1);

        _deposit(hook, poolKey, bob, LEVEL, 0, true, 1e18);
        assertEq(hook.slotGroup(poolId, LEVEL, false, 0), groupId);
        (uint256 b0, uint256 b1) = hook.positionOf(bob, groupId);
        uint256 bobBefore = _value(b0, b1);
        // Bob's slice is worth what he paid, rounding aside.
        assertApproxEqRel(bobBefore, _askLiquidity(LEVEL, 1e18), 1e9);

        _roundTrip();
        (a0, a1) = _withdrawAll(hook, alice, groupId);
        (b0, b1) = _withdrawAll(hook, bob, groupId);
        uint256 aliceAfter = _value(a0, a1);
        uint256 bobAfter = _value(b0, b1);

        assertGt(aliceAfter, aliceBefore);
        assertGt(bobAfter, bobBefore);
        // aliceAfter / aliceBefore == bobAfter / bobBefore
        assertApproxEqRel(aliceAfter * bobBefore, bobAfter * aliceBefore, 1e9);
    }

    /// Fees collected for the hook are held as claims on the pool manager, never as loose tokens.
    function test_feesAreHeldAsClaims() public {
        _deposit(hook, poolKey, alice, LEVEL, 0, true, 1e18);
        _deposit(hook, poolKey, bob, LEVEL, 1, true, 1e18);
        _roundTrip();
        // Bob's withdrawal collects the level's fees, including Alice's, which stay with the hook.
        _withdrawAll(hook, bob, 2);

        assertGt(manager.balanceOf(address(hook), currency0.toId()), 0);
        assertGt(manager.balanceOf(address(hook), currency1.toId()), 0);
        assertEq(currency0.balanceOf(address(hook)), 0);
        assertEq(currency1.balanceOf(address(hook)), 0);

        // Once Alice withdraws too, only rounding dust is left.
        _withdrawAll(hook, alice, 1);
        assertLe(manager.balanceOf(address(hook), currency0.toId()), 2);
        assertLe(manager.balanceOf(address(hook), currency1.toId()), 2);
    }
}
