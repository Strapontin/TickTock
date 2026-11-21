// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title OrderMath
/// @notice Math for one-tick orders: each order level `L` is the range `[L, L+1)`.
/// @dev Prices are sqrt prices in Q64.96, token1 per token0. `sqrtLower` and `sqrtUpper` are the range's bounds.
library OrderMath {
    /// @notice Basis points in 100%.
    uint256 internal constant BPS = 10_000;

    /// @notice The sqrt prices bounding level `level`'s range.
    function bounds(int24 level) internal pure returns (uint160 sqrtLower, uint160 sqrtUpper) {
        sqrtLower = TickMath.getSqrtPriceAtTick(level);
        sqrtUpper = TickMath.getSqrtPriceAtTick(level + 1);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Liquidity and amounts
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice The liquidity that `amount0` of token0 buys over the range, as an ask (price below the range).
    /// @dev `amount0 * sqrtLower * sqrtUpper / (Q96 * (sqrtUpper - sqrtLower))`, dividing by the range width first.
    /// v4-periphery's LiquidityAmounts computes `sqrtLower * sqrtUpper / Q96` first instead, which floors to a
    /// handful of units at low prices and can lose most of the value. Here the first quotient is at least about
    /// 20,000 times `amount0`, so the relative error stays below 1 / (20,000 * amount0) at any price.
    function liquidityForAmount0(uint160 sqrtLower, uint160 sqrtUpper, uint256 amount0, bool roundUp)
        internal
        pure
        returns (uint256)
    {
        if (roundUp) {
            uint256 perWidthUp = FullMath.mulDivRoundingUp(amount0, sqrtLower, sqrtUpper - sqrtLower);
            return FullMath.mulDivRoundingUp(perWidthUp, sqrtUpper, FixedPoint96.Q96);
        }
        uint256 perWidth = FullMath.mulDiv(amount0, sqrtLower, sqrtUpper - sqrtLower);
        return FullMath.mulDiv(perWidth, sqrtUpper, FixedPoint96.Q96);
    }

    /// @notice The liquidity that `amount1` of token1 buys over the range, as a bid (price above the range).
    function liquidityForAmount1(uint160 sqrtLower, uint160 sqrtUpper, uint256 amount1, bool roundUp)
        internal
        pure
        returns (uint256)
    {
        if (roundUp) return FullMath.mulDivRoundingUp(amount1, FixedPoint96.Q96, sqrtUpper - sqrtLower);
        return FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtUpper - sqrtLower);
    }

    /// @notice The token0 held by `liquidity` over the whole range (an ask, or a fully converted bid).
    function amount0ForLiquidity(uint160 sqrtLower, uint160 sqrtUpper, uint128 liquidity, bool roundUp)
        internal
        pure
        returns (uint256)
    {
        return SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, roundUp);
    }

    /// @notice The token1 held by `liquidity` over the whole range (a bid, or a fully converted ask).
    function amount1ForLiquidity(uint160 sqrtLower, uint160 sqrtUpper, uint128 liquidity, bool roundUp)
        internal
        pure
        returns (uint256)
    {
        return SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, roundUp);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Values and sizes
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice A group's value in liquidity units of its level: its liquidity, plus its pending tokens converted to
    /// liquidity over the same range. `pending0` counts as an ask there, `pending1` as a bid.
    /// @dev Both conversions use the level's own fill price, so the value can't be moved by the pool's live price.
    function value(
        uint160 sqrtLower,
        uint160 sqrtUpper,
        uint256 liquidity,
        uint256 pending0,
        uint256 pending1,
        bool roundUp
    ) internal pure returns (uint256) {
        return liquidity + liquidityForAmount0(sqrtLower, sqrtUpper, pending0, roundUp)
            + liquidityForAmount1(sqrtLower, sqrtUpper, pending1, roundUp);
    }

    /// @notice The size of a level's asks, for comparing levels: proportional to the token1 they convert into.
    function askSize(uint160 sqrtLower, uint256 liquidity) internal pure returns (uint256) {
        return FullMath.mulDiv(liquidity, sqrtLower, FixedPoint96.Q96);
    }

    /// @notice The size of a level's bids, for comparing levels: proportional to the token0 they convert into.
    function bidSize(uint160 sqrtLower, uint256 liquidity) internal pure returns (uint256) {
        return FullMath.mulDiv(liquidity, FixedPoint96.Q96, sqrtLower);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Crossings
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice The crossing bounds at a price (DESIGN.md section 5.1).
    /// @param sqrtPriceX96 The pool's sqrt price.
    /// @param slot0Tick The pool's tick. v4 leaves it one below `T` when a downward swap stops exactly on a tick.
    /// @return t The tick with `sqrtPrice(t) <= sqrtPriceX96 < sqrtPrice(t + 1)`.
    /// @return highestCrossedAsk Asks at a level `L` are fully converted iff `L <= highestCrossedAsk`.
    /// @return lowestCrossedBid Bids at a level `L` are fully converted iff `L >= lowestCrossedBid`.
    function crossings(uint160 sqrtPriceX96, int24 slot0Tick)
        internal
        pure
        returns (int24 t, int24 highestCrossedAsk, int24 lowestCrossedBid)
    {
        bool onBoundary;
        if (TickMath.getSqrtPriceAtTick(slot0Tick + 1) == sqrtPriceX96) {
            t = slot0Tick + 1;
            onBoundary = true;
        } else {
            t = slot0Tick;
            onBoundary = TickMath.getSqrtPriceAtTick(t) == sqrtPriceX96;
        }
        highestCrossedAsk = t - 1;
        lowestCrossedBid = onBoundary ? t : t + 1;
    }

    /// @notice The share of an ask's token0 already sold when the price is inside its range, in basis points,
    /// rounded down.
    function askSoldBps(uint160 sqrtLower, uint160 sqrtUpper, uint160 sqrtPriceX96) internal pure returns (uint256) {
        // Unsold share = remaining0 / initial0 = (sqrtUpper - sqrtP) * sqrtLower / ((sqrtUpper - sqrtLower) * sqrtP).
        uint256 unsold = FullMath.mulDivRoundingUp(
            FullMath.mulDivRoundingUp(sqrtUpper - sqrtPriceX96, sqrtLower, sqrtPriceX96), BPS, sqrtUpper - sqrtLower
        );
        return unsold >= BPS ? 0 : BPS - unsold;
    }

    /// @notice The share of a bid's token1 already sold when the price is inside its range, in basis points,
    /// rounded down.
    function bidSoldBps(uint160 sqrtLower, uint160 sqrtUpper, uint160 sqrtPriceX96) internal pure returns (uint256) {
        // Sold share = (sqrtUpper - sqrtP) / (sqrtUpper - sqrtLower).
        return FullMath.mulDiv(sqrtUpper - sqrtPriceX96, BPS, sqrtUpper - sqrtLower);
    }
}
