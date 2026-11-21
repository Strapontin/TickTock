// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickTockState} from "../src/base/TickTockState.sol";
import {OrderMath} from "../src/libraries/OrderMath.sol";
import {TickTockEngine} from "../src/TickTockEngine.sol";
import {TickTockHook} from "../src/TickTockHook.sol";
import {TickTockTestBase} from "./utils/TickTockTestBase.sol";

/// @notice Flipping one level with `flipLevel` (DESIGN.md section 5.2). Swaps don't flip yet.
contract FlipsTest is TickTockTestBase {
    using PoolIdLibrary for PoolKey;

    TickTockHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public override {
        super.setUp();
        hook = _createHook(10, _spreads(10, 50, 100));
        poolKey = _key(hook, 0); // no fee, for exact amounts
        poolId = poolKey.toId();
        _fund(alice, hook);
        _fund(bob, hook);
        _fund(carol, hook);
    }

    function _flip(int24 level) internal {
        hook.flipLevel(poolKey, level);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // One level
    // ---------------------------------------------------------------------------------------------------------------

    function test_flipAsks_exactAmounts() public {
        (uint64 groupId, uint256 shares) = _deposit(hook, poolKey, alice, 100, 1, true, 1e18);
        uint256 askLiquidity = hook.getLevel(poolId, 100).askLiquidity;
        _swapToTick(poolKey, 101);

        vm.expectEmit(address(hook));
        emit TickTockState.LevelFlipped(poolId, 100, false, askLiquidity, false);
        _flip(100);

        // The asks left level 100 entirely.
        TickTockState.Level memory source = hook.getLevel(poolId, 100);
        assertEq(source.askLiquidity, 0);
        assertEq(source.askMask, 0);
        assertEq(hook.slotGroup(poolId, 100, false, 1), 0);
        assertEq(_positionLiquidity(hook, poolKey, 100), 0);

        // Their token1 now bids at 50, in the same strategy's bid slot, with the same shares.
        (uint160 lower, uint160 upper) = OrderMath.bounds(100);
        uint256 principal1 = OrderMath.amount1ForLiquidity(lower, upper, uint128(askLiquidity), false);
        (lower, upper) = OrderMath.bounds(50);
        uint256 bidLiquidity = OrderMath.liquidityForAmount1(lower, upper, principal1, false);
        uint256 used = OrderMath.amount1ForLiquidity(lower, upper, uint128(bidLiquidity), true);

        TickTockState.Group memory g = hook.getGroup(groupId);
        assertTrue(g.isBid);
        assertEq(g.sellLevel, 100);
        assertEq(g.liquidity, bidLiquidity);
        assertEq(g.pending1, principal1 - used, "rounding stays pending");
        assertEq(g.pending0, 0);
        assertEq(g.totalShares, shares);
        assertEq(hook.slotGroup(poolId, 50, true, 1), groupId);
        assertEq(hook.getLevel(poolId, 50).bidLiquidity, bidLiquidity);
        assertEq(hook.getLevel(poolId, 50).bidMask, 2);
        assertEq(_positionLiquidity(hook, poolKey, 50), bidLiquidity);

        // The pending dust is held as claims.
        assertEq(manager.balanceOf(address(hook), currency1.toId()), principal1 - used);
    }

    function test_flipBids() public {
        // Strategy (S = 100, spread 50): the bid sits at 50.
        (uint64 groupId,) = _deposit(hook, poolKey, bob, 100, 1, false, 1e18);
        uint256 bidLiquidity = hook.getLevel(poolId, 50).bidLiquidity;
        _swapToTick(poolKey, 50);
        _flip(50);

        (uint160 lower, uint160 upper) = OrderMath.bounds(50);
        uint256 principal0 = OrderMath.amount0ForLiquidity(lower, upper, uint128(bidLiquidity), false);
        (lower, upper) = OrderMath.bounds(100);
        uint256 askLiquidity = OrderMath.liquidityForAmount0(lower, upper, principal0, false);

        TickTockState.Group memory g = hook.getGroup(groupId);
        assertFalse(g.isBid);
        assertEq(g.liquidity, askLiquidity);
        assertEq(hook.slotGroup(poolId, 100, false, 1), groupId);
        assertEq(hook.getLevel(poolId, 50).bidMask, 0);
        assertEq(_positionLiquidity(hook, poolKey, 50), 0);
    }

    /// One round trip turns the token0 into about 1.0001^spread times as much.
    function test_roundTripGrowsBySpread() public {
        (uint64 groupId,) = _deposit(hook, poolKey, alice, 100, 1, true, 1e18);
        _roundTrip();

        (uint256 amount0, uint256 amount1) = hook.positionOf(alice, groupId);
        assertApproxEqRel(amount0, _afterRoundTrips(1e18, 1), 1e9);
        assertLe(amount1, 1, "only token1 dust");
        (uint256 out0,) = _withdrawAll(hook, alice, groupId);
        assertEq(out0, amount0);
    }

    function test_severalRoundTripsCompound() public {
        (uint64 groupId,) = _deposit(hook, poolKey, alice, 100, 1, true, 1e18);
        for (uint256 i = 0; i < 4; ++i) {
            _roundTrip();
        }
        (uint256 amount0,) = hook.positionOf(alice, groupId);
        assertApproxEqRel(amount0, _afterRoundTrips(1e18, 4), 1e9);
    }

    /// With a fee, the fees are compounded too, so a round trip earns more than the spread alone.
    function test_feesCompoundOnFlip() public {
        poolKey = _key(hook, 3000);
        poolId = poolKey.toId();
        (uint64 groupId,) = _deposit(hook, poolKey, alice, 100, 1, true, 1e18);
        _swapToTick(poolKey, 101);
        _flip(100);

        // Everything was re-posted: the fees didn't stay pending.
        TickTockState.Group memory g = hook.getGroup(groupId);
        (uint160 lower, uint160 upper) = OrderMath.bounds(50);
        uint256 bidToken1 = OrderMath.amount1ForLiquidity(lower, upper, g.liquidity, false);
        (lower, upper) = OrderMath.bounds(100);
        uint256 principal1 = OrderMath.amount1ForLiquidity(lower, upper, uint128(_askLiquidity(100, 1e18)), false);
        // The swap paid 0.3% of its input on top of the principal.
        assertApproxEqRel(bidToken1, principal1 * 1e6 / (1e6 - 3000), 1e12);
        assertLe(g.pending1, 1);
        assertEq(g.pending0, 0, "an upward swap pays its fee in token1 only");

        _swapToTick(poolKey, 50);
        _flip(50);
        (uint256 amount0,) = hook.positionOf(alice, groupId);
        assertGt(amount0, _afterRoundTrips(1e18, 1) * 1005 / 1000);
    }

    /// Each spread at a level flips to its own destination, with its share of the level.
    function test_severalSpreadsAtOneLevel() public {
        (uint64 a,) = _deposit(hook, poolKey, alice, 100, 0, true, 1e18);
        (uint64 b,) = _deposit(hook, poolKey, bob, 100, 1, true, 2e18);
        (uint64 c,) = _deposit(hook, poolKey, carol, 100, 2, true, 3e18);
        uint256 total = hook.getLevel(poolId, 100).askLiquidity;
        _swapToTick(poolKey, 101);
        _flip(100);

        (uint160 lower, uint160 upper) = OrderMath.bounds(100);
        uint256 principal1 = OrderMath.amount1ForLiquidity(lower, upper, uint128(total), false);
        _assertBidFrom(a, 90, 0, principal1, _askLiquidity(100, 1e18), total);
        _assertBidFrom(b, 50, 1, principal1, _askLiquidity(100, 2e18), total);
        _assertBidFrom(c, 0, 2, principal1, _askLiquidity(100, 3e18), total);
        assertEq(hook.getLevel(poolId, 100).askMask, 0);
    }

    function _assertBidFrom(uint64 groupId, int24 level, uint8 k, uint256 principal1, uint256 share, uint256 total)
        internal
        view
    {
        uint256 amount1 = FullMath.mulDiv(principal1, share, total);
        (uint160 lower, uint160 upper) = OrderMath.bounds(level);
        assertEq(hook.getGroup(groupId).liquidity, OrderMath.liquidityForAmount1(lower, upper, amount1, false));
        assertEq(hook.slotGroup(poolId, level, true, k), groupId);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Deposits and refusals
    // ---------------------------------------------------------------------------------------------------------------

    /// A deposit into a crossed level flips it first: the crossed orders get their trade.
    function test_depositFlipsACrossedTargetLevel() public {
        (uint64 aliceGroup,) = _deposit(hook, poolKey, alice, 100, 1, true, 1e18);
        _swapToTick(poolKey, 101);

        (uint64 bobGroup,) = _deposit(hook, poolKey, bob, 100, 1, true, 1e18);
        assertTrue(bobGroup != aliceGroup);
        assertEq(hook.slotGroup(poolId, 100, false, 1), bobGroup);
        assertEq(hook.slotGroup(poolId, 50, true, 1), aliceGroup);
        assertTrue(hook.getGroup(aliceGroup).isBid);
        assertEq(_price(poolKey), _sqrt(100));
    }

    function test_flipLevelRefusals() public {
        _deposit(hook, poolKey, alice, 100, 1, true, 1e18);

        // Not crossed: the price is at the ask's lower edge.
        vm.expectRevert(TickTockState.NothingToFlip.selector);
        _flip(100);
        // Inside the level: partial flips come later.
        (uint160 lower, uint160 upper) = OrderMath.bounds(100);
        _swapTo(poolKey, lower + (upper - lower) / 2);
        vm.expectRevert(TickTockState.NothingToFlip.selector);
        _flip(100);
        // Empty or off-grid levels.
        vm.expectRevert(TickTockState.NothingToFlip.selector);
        _flip(200);
        vm.expectRevert(TickTockState.NothingToFlip.selector);
        _flip(105);

        vm.expectRevert(TickTockState.PoolNotFound.selector);
        hook.flipLevel(_key(hook, 500), 100);
    }

    function test_engineRefusesDirectCalls() public {
        TickTockEngine engine = TickTockEngine(hook.engine());
        vm.expectRevert(TickTockState.NotDelegateCall.selector);
        engine.flipSide(poolKey, 100, false);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // v4's per-tick limit
    // ---------------------------------------------------------------------------------------------------------------

    function test_maxTickLiquidityMatchesV4() public view {
        assertEq(hook.MAX_TICK_LIQUIDITY(), Pool.tickSpacingToMaxLiquidityPerTick(1));
    }

    /// A destination near the limit takes what fits. The rest stays pending in its token, is never treated as
    /// traded, and is placed again at the group's next flip to that side.
    function test_tickLimitPlacesWhatFitsAndKeepsTheRest() public {
        // At low prices a few wei of token1 buy a lot of liquidity, so the limit is easy to reach.
        int24 bidLevel = -600_000;
        int24 sellLevel = bidLevel + 50; // spread index 1

        // Bob fills the bid level almost to the limit, from another strategy (spread index 0).
        (uint160 lower, uint160 upper) = OrderMath.bounds(bidLevel);
        uint256 room = 1e21;
        uint256 bobAmount = OrderMath.amount1ForLiquidity(lower, upper, uint128(hook.MAX_TICK_LIQUIDITY() - room), true);
        (uint64 bobGroup,) = _deposit(hook, poolKey, bob, bidLevel + 10, 0, false, uint128(bobAmount));
        uint256 roomLeft = hook.MAX_TICK_LIQUIDITY() - hook.getLevel(poolId, bidLevel).bidLiquidity;

        // Alice's ask converts into more token1 than fits.
        (uint64 aliceGroup,) = _deposit(hook, poolKey, alice, sellLevel, 1, true, 1e30);
        _swapToTick(poolKey, sellLevel + 1);
        _flip(sellLevel);

        TickTockState.Group memory g = hook.getGroup(aliceGroup);
        assertEq(g.liquidity, roomLeft, "fills the room exactly");
        assertGt(g.pending1, 0, "the rest stays pending");
        assertEq(hook.slotGroup(poolId, bidLevel, true, 1), aliceGroup);
        // Nothing was lost: placed plus pending is what the asks converted into.
        (uint160 sellLower, uint160 sellUpper) = OrderMath.bounds(sellLevel);
        uint256 principal1 =
            OrderMath.amount1ForLiquidity(sellLower, sellUpper, uint128(_askLiquidity(sellLevel, 1e30)), false);
        uint256 placed = OrderMath.amount1ForLiquidity(lower, upper, g.liquidity, true);
        assertEq(placed + g.pending1, principal1);

        // Bob leaves, then the price goes down through the bids and back up through the asks.
        _withdrawAll(hook, bob, bobGroup);
        _swapToTick(poolKey, bidLevel);
        _flip(bidLevel);
        g = hook.getGroup(aliceGroup);
        assertFalse(g.isBid);
        assertGt(g.pending1, 0, "the unplaced token1 rides along, untraded");
        _swapToTick(poolKey, sellLevel + 1);
        _flip(sellLevel);

        g = hook.getGroup(aliceGroup);
        assertTrue(g.isBid);
        assertLe(g.pending1, 1, "now everything fits");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// Up through the ask at 100, flip, down through the bid at 50, flip.
    function _roundTrip() internal {
        _swapToTick(poolKey, 101);
        _flip(100);
        _swapToTick(poolKey, 50);
        _flip(50);
    }

    /// `amount0 * (1.0001^spread)^n`, with the exact tick-math ratio of fill prices at 100 and 50.
    function _afterRoundTrips(uint256 amount0, uint256 n) internal pure returns (uint256) {
        (uint160 sellLower, uint160 sellUpper) = OrderMath.bounds(100);
        (uint160 buyLower, uint160 buyUpper) = OrderMath.bounds(50);
        for (uint256 i = 0; i < n; ++i) {
            amount0 = FullMath.mulDiv(FullMath.mulDiv(amount0, sellLower, buyLower), sellUpper, buyUpper);
        }
        return amount0;
    }
}
