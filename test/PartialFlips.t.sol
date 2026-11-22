// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickTockState} from "../src/base/TickTockState.sol";
import {OrderMath} from "../src/libraries/OrderMath.sol";
import {TickTockHook} from "../src/TickTockHook.sol";
import {TickTockTestBase} from "./utils/TickTockTestBase.sol";

/// @notice `flipLevel` on a level the price stopped inside (DESIGN.md section 5.4). Strategy (S = 100, spread 50):
/// the ask slot is at 100 and the bid slot at 50.
contract PartialFlipsTest is TickTockTestBase {
    using PoolIdLibrary for PoolKey;

    TickTockHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;
    uint160 internal lower100;
    uint160 internal upper100;

    function setUp() public override {
        super.setUp();
        hook = _createHook(10, _spreads(10, 50, 100));
        poolKey = _key(hook, 0);
        poolId = poolKey.toId();
        _fund(alice, hook);
        _fund(bob, hook);
        (lower100, upper100) = OrderMath.bounds(100);
    }

    /// The price at which the ask at 100 has sold `bps` of its token0, roughly.
    function _askPriceAt(uint256 bps) internal view returns (uint160) {
        return lower100 + uint160((uint256(upper100 - lower100) * bps) / 10_000);
    }

    function _value(int24 level, uint256 amount0, uint256 amount1) internal pure returns (uint256) {
        (uint160 lower, uint160 upper) = OrderMath.bounds(level);
        return OrderMath.value(lower, upper, 0, amount0, amount1, false);
    }

    /// The threshold is exact: one wei of price below it is refused, at it the level flips.
    function test_thresholdBoundary() public {
        (uint64 groupId,) = _deposit(hook, poolKey, alice, 100, 1, true, 1e18);

        // The lowest price at which the asks have sold at least 90%.
        uint160 lo = lower100;
        uint160 hi = upper100;
        while (hi - lo > 1) {
            uint160 mid = lo + (hi - lo) / 2;
            if (OrderMath.askSoldBps(lower100, upper100, mid) >= hook.PARTIAL_FLIP_THRESHOLD_BPS()) hi = mid;
            else lo = mid;
        }

        _swapTo(poolKey, hi - 1);
        vm.expectRevert(TickTockState.NothingToFlip.selector);
        hook.flipLevel(poolKey, 100);

        _swapTo(poolKey, hi);
        hook.flipLevel(poolKey, 100);
        assertTrue(hook.getGroup(groupId).isBid);
    }

    function test_refusedBelowTheThreshold() public {
        _deposit(hook, poolKey, alice, 100, 1, true, 1e18);
        _swapTo(poolKey, _askPriceAt(8_950));
        vm.expectRevert(TickTockState.NothingToFlip.selector);
        hook.flipLevel(poolKey, 100);
    }

    /// A level 99.99% sold flips: the sold token1 bids at 50, the unsold token0 waits in pending, and nothing is lost.
    function test_askAt9999() public {
        (uint64 groupId,) = _deposit(hook, poolKey, alice, 100, 1, true, 1e18);
        _swapTo(poolKey, upper100 - (upper100 - lower100) / 10_000);
        (uint256 before0, uint256 before1) = hook.positionOf(alice, groupId);
        assertGt(before0, 0);
        assertGt(before1, 0);

        uint256 askLiquidity = hook.getLevel(poolId, 100).askLiquidity;
        vm.expectEmit(address(hook));
        emit TickTockState.LevelFlipped(poolId, 100, false, askLiquidity, true);
        hook.flipLevel(poolKey, 100);

        TickTockState.Group memory g = hook.getGroup(groupId);
        assertTrue(g.isBid);
        assertEq(hook.slotGroup(poolId, 50, true, 1), groupId);
        assertEq(hook.getLevel(poolId, 100).askMask, 0);
        assertEq(_positionLiquidity(hook, poolKey, 100), 0);
        assertEq(g.pending0, before0, "the unsold token0 waits");

        (uint256 after0, uint256 after1) = hook.positionOf(alice, groupId);
        assertEq(after0, before0);
        assertApproxEqAbs(after1, before1, 2, "the sold token1 is re-posted whole");
    }

    function test_bidAt9999() public {
        (uint64 groupId,) = _deposit(hook, poolKey, bob, 100, 1, false, 1e18); // bid at 50
        (uint160 lower, uint160 upper) = OrderMath.bounds(50);
        _swapTo(poolKey, lower + (upper - lower) / 10_000);
        (uint256 before0, uint256 before1) = hook.positionOf(bob, groupId);

        hook.flipLevel(poolKey, 50);
        TickTockState.Group memory g = hook.getGroup(groupId);
        assertFalse(g.isBid);
        assertEq(hook.slotGroup(poolId, 100, false, 1), groupId);
        assertEq(g.pending1, before1, "the unsold token1 waits");

        (uint256 after0, uint256 after1) = hook.positionOf(bob, groupId);
        assertApproxEqAbs(after0, before0, 2);
        assertEq(after1, before1);
    }

    /// The unsold remainder is re-posted the next time the group comes back to that side.
    function test_unsoldRemainderIsRepostedOnReturn() public {
        (uint64 groupId,) = _deposit(hook, poolKey, alice, 100, 1, true, 1e18);
        _swapTo(poolKey, _askPriceAt(9_500));
        hook.flipLevel(poolKey, 100);
        uint256 waiting0 = hook.getGroup(groupId).pending0;
        assertGt(waiting0, 0);

        // Down through the bid at 50: the group asks at 100 again, with the token0 it bought plus the remainder.
        _swapToTick(poolKey, 50);
        TickTockState.Group memory g = hook.getGroup(groupId);
        assertFalse(g.isBid);
        assertLe(g.pending0, 1, "everything was re-posted");
        (uint256 amount0,) = hook.positionOf(alice, groupId);
        assertGt(amount0, waiting0);
    }

    /// Value is the same before and after a partial flip, measured at the level's own price.
    function testFuzz_partialFlipConservesValue(uint256 bpsSeed, uint128 amount) public {
        uint256 bps = bound(bpsSeed, 9_000, 9_999);
        amount = uint128(bound(amount, 1e12, 1e27));
        (uint64 groupId,) = _deposit(hook, poolKey, alice, 100, 1, true, amount);
        uint160 price = _askPriceAt(bps);
        vm.assume(OrderMath.askSoldBps(lower100, upper100, price) >= hook.PARTIAL_FLIP_THRESHOLD_BPS());
        _swapTo(poolKey, price);

        (uint256 before0, uint256 before1) = hook.positionOf(alice, groupId);
        hook.flipLevel(poolKey, 100);
        (uint256 after0, uint256 after1) = hook.positionOf(alice, groupId);

        assertLe(_value(100, after0, after1), _value(100, before0, before1));
        assertApproxEqAbs(_value(100, after0, after1), _value(100, before0, before1), 1e6);
        assertApproxEqRel(_value(100, after0, after1), _value(100, before0, before1), 1e9);
    }

    /// Only `flipLevel` flips partly filled levels: swaps and deposits leave them alone.
    function test_swapsAndDepositsDoNotFlipPartly() public {
        (uint64 groupId,) = _deposit(hook, poolKey, alice, 100, 1, true, 1e18);
        _swapTo(poolKey, upper100 - 1);
        assertFalse(hook.getGroup(groupId).isBid);

        vm.expectRevert(TickTockState.LevelInRange.selector);
        _deposit(hook, poolKey, bob, 100, 1, true, 1e18);
        assertFalse(hook.getGroup(groupId).isBid);
    }
}
