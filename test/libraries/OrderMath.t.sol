// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {OrderMath} from "../../src/libraries/OrderMath.sol";

contract OrderMathTest is Test {
    uint256 internal constant REL_1E_6 = 1e12; // 1e-6 in assertApproxEqRel's 1e18 units

    function test_bounds() public pure {
        (uint160 lower, uint160 upper) = OrderMath.bounds(0);
        assertEq(lower, FixedPoint96.Q96);
        assertEq(upper, TickMath.getSqrtPriceAtTick(1));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Liquidity and amounts
    // ---------------------------------------------------------------------------------------------------------------

    /// Liquidity bought with token0 never costs more than the amount, and is within 1e-6 of the best possible.
    function testFuzz_liquidityForAmount0(int24 levelSeed, uint256 amount0) public pure {
        int24 level = _level(levelSeed);
        amount0 = bound(amount0, 1, type(uint128).max);
        (uint160 lower, uint160 upper) = OrderMath.bounds(level);

        uint256 liquidity = OrderMath.liquidityForAmount0(lower, upper, amount0, false);
        vm.assume(liquidity > 0 && liquidity <= type(uint128).max);

        uint256 cost = SqrtPriceMath.getAmount0Delta(lower, upper, uint128(liquidity), true);
        assertLe(cost, amount0, "overspends");
        if (liquidity >= 1e9) assertApproxEqRel(cost, amount0, REL_1E_6, "imprecise");

        uint256 liquidityUp = OrderMath.liquidityForAmount0(lower, upper, amount0, true);
        assertGe(liquidityUp, liquidity);
        // One unit of the first quotient is worth sqrtUpper / Q96 liquidity units.
        assertLe(liquidityUp - liquidity, upper / FixedPoint96.Q96 + 2);
    }

    /// Liquidity bought with token1 never costs more than the amount, and is within 1e-6 of the best possible.
    function testFuzz_liquidityForAmount1(int24 levelSeed, uint256 amount1) public pure {
        int24 level = _level(levelSeed);
        amount1 = bound(amount1, 1, type(uint128).max);
        (uint160 lower, uint160 upper) = OrderMath.bounds(level);

        uint256 liquidity = OrderMath.liquidityForAmount1(lower, upper, amount1, false);
        vm.assume(liquidity > 0 && liquidity <= type(uint128).max);

        uint256 cost = SqrtPriceMath.getAmount1Delta(lower, upper, uint128(liquidity), true);
        assertLe(cost, amount1, "overspends");
        if (liquidity >= 1e9) assertApproxEqRel(cost, amount1, REL_1E_6, "imprecise");

        uint256 liquidityUp = OrderMath.liquidityForAmount1(lower, upper, amount1, true);
        assertGe(liquidityUp, liquidity);
        assertLe(liquidityUp - liquidity, 1);
    }

    /// A fully converted level trades at its fill price, sqrtLower * sqrtUpper.
    function testFuzz_fillPrice(int24 levelSeed, uint128 liquidity) public pure {
        int24 level = _level(levelSeed);
        liquidity = uint128(bound(liquidity, 1e18, type(uint128).max));
        (uint160 lower, uint160 upper) = OrderMath.bounds(level);

        uint256 amount0 = OrderMath.amount0ForLiquidity(lower, upper, liquidity, false);
        uint256 amount1 = OrderMath.amount1ForLiquidity(lower, upper, liquidity, false);
        vm.assume(amount0 >= 1e12 && amount1 >= 1e12);

        uint256 expected1 = FullMath.mulDiv(FullMath.mulDiv(amount0, lower, FixedPoint96.Q96), upper, FixedPoint96.Q96);
        assertApproxEqRel(amount1, expected1, REL_1E_6);
    }

    /// An ask sold at S and bought back at S - spread returns 1.0001^spread times the token0.
    function testFuzz_roundTrip(int24 sellSeed, uint24 spreadSeed, uint256 amount0) public pure {
        int24 spread = int24(uint24(bound(spreadSeed, 1, 20_000)));
        int24 sell = int24(bound(sellSeed, TickMath.MIN_TICK + spread, TickMath.MAX_TICK - 1));
        int24 buy = sell - spread;
        amount0 = bound(amount0, 1, type(uint128).max);

        (uint160 sellLower, uint160 sellUpper) = OrderMath.bounds(sell);
        (uint160 buyLower, uint160 buyUpper) = OrderMath.bounds(buy);

        uint256 askLiquidity = OrderMath.liquidityForAmount0(sellLower, sellUpper, amount0, false);
        vm.assume(askLiquidity >= 1e12 && askLiquidity <= type(uint128).max);
        uint256 amount1 = OrderMath.amount1ForLiquidity(sellLower, sellUpper, uint128(askLiquidity), false);

        uint256 bidLiquidity = OrderMath.liquidityForAmount1(buyLower, buyUpper, amount1, false);
        vm.assume(bidLiquidity >= 1e12 && bidLiquidity <= type(uint128).max);
        uint256 amount0Back = OrderMath.amount0ForLiquidity(buyLower, buyUpper, uint128(bidLiquidity), false);

        // 1.0001^spread = (sqrtPrice(sell) * sqrtPrice(sell + 1)) / (sqrtPrice(buy) * sqrtPrice(buy + 1)).
        uint256 expected = FullMath.mulDiv(FullMath.mulDiv(amount0, sellLower, buyLower), sellUpper, buyUpper);
        // Every step rounds down, so the result never exceeds the exact value, which this bounds from above.
        uint256 exactUp =
            FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(amount0, sellLower, buyLower), sellUpper, buyUpper);
        assertLe(amount0Back, exactUp, "round trip creates value");
        // Precision needs whole-wei rounding on both legs to be negligible.
        if (amount0 >= 1e9 && amount1 >= 1e9) assertApproxEqRel(amount0Back, expected, REL_1E_6);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Values and sizes
    // ---------------------------------------------------------------------------------------------------------------

    function testFuzz_valueOfLiquidityIsItself(int24 levelSeed, uint128 liquidity) public pure {
        (uint160 lower, uint160 upper) = OrderMath.bounds(_level(levelSeed));
        assertEq(OrderMath.value(lower, upper, liquidity, 0, 0, false), liquidity);
        assertEq(OrderMath.value(lower, upper, liquidity, 0, 0, true), liquidity);
    }

    /// Pending tokens are worth the liquidity they came from, whichever side they're on.
    function testFuzz_valueOfPending(int24 levelSeed, uint128 liquidity) public pure {
        (uint160 lower, uint160 upper) = OrderMath.bounds(_level(levelSeed));
        liquidity = uint128(bound(liquidity, 1e15, type(uint128).max));

        uint256 amount0 = OrderMath.amount0ForLiquidity(lower, upper, liquidity, false);
        uint256 amount1 = OrderMath.amount1ForLiquidity(lower, upper, liquidity, false);
        vm.assume(amount0 >= 1e12 && amount1 >= 1e12);

        uint256 value0 = OrderMath.value(lower, upper, 0, amount0, 0, false);
        uint256 value1 = OrderMath.value(lower, upper, 0, 0, amount1, false);
        assertLe(value0, liquidity);
        assertLe(value1, liquidity);
        assertApproxEqRel(value0, liquidity, REL_1E_6);
        assertApproxEqRel(value1, liquidity, REL_1E_6);

        assertGe(OrderMath.value(lower, upper, 0, amount0, amount1, true), value0 + value1);
    }

    /// Sizes are proportional to the amounts a level converts into, with the same factor at every level.
    function testFuzz_sizes(int24 levelSeed, uint128 liquidity) public pure {
        (uint160 lower, uint160 upper) = OrderMath.bounds(_level(levelSeed));
        liquidity = uint128(bound(liquidity, 1e18, type(uint112).max));

        uint256 amount1 = OrderMath.amount1ForLiquidity(lower, upper, liquidity, false);
        uint256 amount0 = OrderMath.amount0ForLiquidity(lower, upper, liquidity, false);
        vm.assume(amount0 >= 1e12 && amount1 >= 1e12);

        // amount1 = askSize * (upper - lower) / lower and amount0 = bidSize * (upper - lower) / upper.
        uint256 fromAskSize = FullMath.mulDiv(OrderMath.askSize(lower, liquidity), upper - lower, lower);
        uint256 fromBidSize = FullMath.mulDiv(OrderMath.bidSize(lower, liquidity), upper - lower, upper);
        assertApproxEqRel(fromAskSize, amount1, 1e14); // 1e-4: TickMath rounds tiny sqrt prices
        assertApproxEqRel(fromBidSize, amount0, 1e14);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Crossings
    // ---------------------------------------------------------------------------------------------------------------

    function test_crossings_insideLevel() public pure {
        uint160 price = TickMath.getSqrtPriceAtTick(10) + 1;
        (int24 t, int24 highestAsk, int24 lowestBid) = OrderMath.crossings(price, 10);
        assertEq(t, 10);
        assertEq(highestAsk, 9);
        assertEq(lowestBid, 11);
    }

    function test_crossings_onBoundary() public pure {
        uint160 price = TickMath.getSqrtPriceAtTick(10);
        // After an upward swap or an initialize, v4 reports tick 10.
        (int24 t, int24 highestAsk, int24 lowestBid) = OrderMath.crossings(price, 10);
        assertEq(t, 10);
        assertEq(highestAsk, 9);
        assertEq(lowestBid, 10);
        // After a downward swap that stops exactly there, v4 reports tick 9. The result is the same.
        (t, highestAsk, lowestBid) = OrderMath.crossings(price, 9);
        assertEq(t, 10);
        assertEq(highestAsk, 9);
        assertEq(lowestBid, 10);
    }

    /// The crossing bounds agree with the sqrt-price definitions of section 5.1 at any price.
    function testFuzz_crossingsMatchDefinition(int24 tickSeed, uint256 offsetSeed, bool reportLower, int8 levelOffset)
        public
        pure
    {
        int24 tick = int24(bound(tickSeed, TickMath.MIN_TICK + 1, TickMath.MAX_TICK - 2));
        uint160 lower = TickMath.getSqrtPriceAtTick(tick);
        uint160 upper = TickMath.getSqrtPriceAtTick(tick + 1);
        uint160 price = uint160(bound(offsetSeed, lower, upper - 1));

        // v4 reports tick - 1 only when a downward swap stops exactly on a boundary.
        int24 slot0Tick = (reportLower && price == lower) ? tick - 1 : tick;
        (int24 t, int24 highestAsk, int24 lowestBid) = OrderMath.crossings(price, slot0Tick);
        assertEq(t, tick);

        int24 level = tick + int24(levelOffset);
        vm.assume(level >= TickMath.MIN_TICK && level < TickMath.MAX_TICK);
        bool askCrossed = price >= TickMath.getSqrtPriceAtTick(level + 1);
        bool bidCrossed = price <= TickMath.getSqrtPriceAtTick(level);
        assertEq(level <= highestAsk, askCrossed, "ask crossing");
        assertEq(level >= lowestBid, bidCrossed, "bid crossing");
    }

    function test_soldBps_endpoints() public pure {
        (uint160 lower, uint160 upper) = OrderMath.bounds(-5000);
        assertEq(OrderMath.askSoldBps(lower, upper, lower), 0);
        assertEq(OrderMath.askSoldBps(lower, upper, upper), OrderMath.BPS);
        assertEq(OrderMath.bidSoldBps(lower, upper, upper), 0);
        assertEq(OrderMath.bidSoldBps(lower, upper, lower), OrderMath.BPS);
    }

    /// Sold shares match the amounts v4 would hold at that price, rounded down.
    function testFuzz_soldBpsMatchAmounts(int24 levelSeed, uint256 priceSeed) public pure {
        (uint160 lower, uint160 upper) = OrderMath.bounds(_level(levelSeed));
        uint160 price = uint160(bound(priceSeed, lower, upper));
        uint128 liquidity = 1e30;

        uint256 initial0 = SqrtPriceMath.getAmount0Delta(lower, upper, liquidity, false);
        uint256 left0 = SqrtPriceMath.getAmount0Delta(price, upper, liquidity, false);
        uint256 expectedAskSold = OrderMath.BPS - FullMath.mulDivRoundingUp(left0, OrderMath.BPS, initial0);
        uint256 askSold = OrderMath.askSoldBps(lower, upper, price);
        assertLe(askSold, expectedAskSold + 1);
        assertGe(askSold + 1, expectedAskSold);

        uint256 initial1 = SqrtPriceMath.getAmount1Delta(lower, upper, liquidity, false);
        uint256 left1 = SqrtPriceMath.getAmount1Delta(lower, price, liquidity, false);
        uint256 expectedBidSold = OrderMath.BPS - FullMath.mulDivRoundingUp(left1, OrderMath.BPS, initial1);
        uint256 bidSold = OrderMath.bidSoldBps(lower, upper, price);
        assertLe(bidSold, expectedBidSold + 1);
        assertGe(bidSold + 1, expectedBidSold);
    }

    function _level(int24 seed) internal pure returns (int24) {
        return int24(bound(seed, TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
    }
}
