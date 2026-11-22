// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickTockState} from "./base/TickTockState.sol";
import {HookConfig} from "./libraries/HookConfig.sol";
import {LevelBitmap} from "./libraries/LevelBitmap.sol";
import {OrderMath} from "./libraries/OrderMath.sol";

/// @title TickTockEngine
/// @notice The flip logic of TickTock hooks, split out of `TickTockHook` to keep it under the contract size limit.
/// @dev Only ever runs through the hook's `delegatecall`, on the hook clone's storage, so its pool calls come from
/// the clone. The hook settles the balance changes afterwards. Calling it directly reverts.
contract TickTockEngine is TickTockState {
    using LevelBitmap for mapping(int16 => uint256);
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    /// @dev One flipped group's arrival at its destination slot.
    struct Placement {
        uint160 sqrtLower;
        uint160 sqrtUpper;
        /// The arriving group's amount in the destination token, its pending tokens in that token included.
        uint256 amount;
        /// The waiting group's pending tokens in the destination token, placed in the same operation.
        uint256 compounded;
        /// The liquidity added.
        uint256 liquidity;
        /// What couldn't be placed, from rounding or v4's per-tick limit.
        uint256 leftover;
    }

    /// @dev This contract's own address, to refuse direct calls.
    address private immutable _self;

    constructor(IPoolManager poolManager_) TickTockState(poolManager_) {
        _self = address(this);
    }

    /// @notice Flips the crossed levels on one side, in price order from that side's cursor, within a budget of
    /// liquidity operations, then updates both cursors (DESIGN.md section 5.3).
    /// @param asks True to scan asks (the price rose), false to scan bids (it fell).
    /// @param budget The most liquidity operations to spend. A level is flipped completely or not at all.
    /// @param skipDivisor A level is skipped when its size times this is below the largest crossed level's size.
    /// @return spent The liquidity operations spent.
    function scan(PoolKey calldata key, bool asks, uint256 budget, uint256 skipDivisor)
        external
        returns (uint256 spent)
    {
        if (address(this) == _self) revert NotDelegateCall();
        PoolId poolId = key.toId();
        PoolState storage pool = _pools[poolId];
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
        (int24 t, int24 highestCrossedAsk, int24 lowestCrossedBid) = OrderMath.crossings(sqrtPriceX96, tick);

        bool stopped;
        int24 stopLevel;
        if (asks) {
            (spent, stopped, stopLevel) =
                _scanSide(key, poolId, false, pool.askCursor, highestCrossedAsk, budget, skipDivisor);
            pool.askCursor = stopped ? stopLevel : t;
            if (t > pool.bidCursor) pool.bidCursor = t;
        } else {
            (spent, stopped, stopLevel) =
                _scanSide(key, poolId, true, pool.bidCursor, lowestCrossedBid, budget, skipDivisor);
            pool.bidCursor = stopped ? stopLevel : t;
            if (t < pool.askCursor) pool.askCursor = t;
        }
    }

    /// @notice Flips one fully crossed side of a level. The hook checks that the side is crossed first.
    /// @return ops The liquidity operations spent.
    function flipSide(PoolKey calldata key, int24 levelTick, bool bids) external returns (uint256 ops) {
        if (address(this) == _self) revert NotDelegateCall();
        return _flipSide(key, key.toId(), _config(), levelTick, bids);
    }

    /// @dev Scans the crossed levels of one side between `from` (the cursor) and `to` (the last crossed level).
    /// The first pass only reads them to find the largest size; the second flips or skips them in price order and
    /// stops at the first level the remaining budget can't flip completely.
    /// @return spent The liquidity operations spent.
    /// @return stopped Whether the budget ran out before the end of the range.
    /// @return stopLevel The first level the budget didn't reach, when stopped.
    function _scanSide(
        PoolKey memory key,
        PoolId poolId,
        bool bids,
        int24 from,
        int24 to,
        uint256 budget,
        uint256 skipDivisor
    ) internal returns (uint256 spent, bool stopped, int24 stopLevel) {
        HookConfig.Config memory cfg = _config();
        mapping(int16 => uint256) storage bitmap = bids ? _bidBitmap[poolId] : _askBitmap[poolId];

        uint256 largest;
        (int24 level, bool found) = _next(bitmap, bids, from, to, cfg.levelSpacing);
        while (found) {
            uint256 size = _size(poolId, level, bids);
            if (size > largest) largest = size;
            (level, found) =
                _next(bitmap, bids, bids ? level - cfg.levelSpacing : level + cfg.levelSpacing, to, cfg.levelSpacing);
        }

        (level, found) = _next(bitmap, bids, from, to, cfg.levelSpacing);
        while (found) {
            if (_size(poolId, level, bids) * skipDivisor < largest) {
                emit LevelSkipped(poolId, level, bids);
            } else {
                Level storage l = _levels[poolId][level];
                uint256 cost = bids
                    ? (l.bidLiquidity != 0 ? 1 : 0) + _popcount(l.bidMask)
                    : (l.askLiquidity != 0 ? 1 : 0) + _popcount(l.askMask);
                if (cost > budget - spent) return (spent, true, level);
                spent += _flipSide(key, poolId, cfg, level, bids);
            }
            (level, found) =
                _next(bitmap, bids, bids ? level - cfg.levelSpacing : level + cfg.levelSpacing, to, cfg.levelSpacing);
        }
    }

    /// @dev The next level with orders on that side, going up from `from` to `to` for asks, down for bids.
    function _next(mapping(int16 => uint256) storage bitmap, bool bids, int24 from, int24 to, int24 spacing)
        internal
        view
        returns (int24, bool)
    {
        return bids ? bitmap.nextDown(from, to, spacing) : bitmap.nextUp(from, to, spacing);
    }

    /// @dev A level side's size, for comparing levels (DESIGN.md section 2).
    function _size(PoolId poolId, int24 levelTick, bool bids) internal view returns (uint256) {
        Level storage l = _levels[poolId][levelTick];
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(levelTick);
        return bids ? OrderMath.bidSize(sqrtLower, l.bidLiquidity) : OrderMath.askSize(sqrtLower, l.askLiquidity);
    }

    function _popcount(uint8 x) internal pure returns (uint256 count) {
        for (; x != 0; x &= x - 1) {
            ++count;
        }
    }

    /// @dev Flips one converted side of a level: removes its liquidity, then re-posts each group's share, plus its
    /// pending tokens in the new token, at the opposite slot of its strategy (DESIGN.md section 5.2). In a partial
    /// flip (the price inside the level), the unsold part of each share goes to the group's pending tokens and is
    /// re-posted when the group comes back to this side (section 5.4).
    /// @param bids True to flip the level's bids into asks, false to flip its asks into bids.
    /// @return ops The liquidity operations spent: one removal plus one addition per destination.
    function _flipSide(PoolKey memory key, PoolId poolId, HookConfig.Config memory cfg, int24 levelTick, bool bids)
        internal
        returns (uint256 ops)
    {
        Level storage level = _levels[poolId][levelTick];
        (uint256 sideLiquidity, uint8 mask) =
            bids ? (uint256(level.bidLiquidity), level.bidMask) : (uint256(level.askLiquidity), level.askMask);

        // Asks convert into token1 and bids into token0; `unsold` is the rest of a partial flip. The removal's fees
        // accrue over the level's whole liquidity, before the side leaves it.
        uint256 principal;
        uint256 unsold;
        if (sideLiquidity != 0) {
            BalanceDelta delta = _modifyLevel(key, level, levelTick, -sideLiquidity.toInt256());
            uint256 amount0 = uint256(int256(delta.amount0()));
            uint256 amount1 = uint256(int256(delta.amount1()));
            (principal, unsold) = bids ? (amount0, amount1) : (amount1, amount0);
            ops = 1;
        }
        if (bids) {
            (level.bidLiquidity, level.bidMask) = (0, 0);
            _bidBitmap[poolId].clear(levelTick, cfg.levelSpacing);
        } else {
            (level.askLiquidity, level.askMask) = (0, 0);
            _askBitmap[poolId].clear(levelTick, cfg.levelSpacing);
        }

        for (uint8 k = 0; k < cfg.spreadCount; ++k) {
            // forge-lint: disable-next-line(incorrect-shift)
            if (mask & (1 << k) == 0) continue;
            int24 sellLevel = bids ? levelTick + cfg.spreads[k] : levelTick;
            uint64[16] storage strategy = _strategyGroups[poolId][sellLevel];
            uint256 index = _slotIndex(k, bids);
            uint64 groupId = strategy[index];
            strategy[index] = 0;

            Group storage g = _groups[groupId];
            // The snapshot moves to the destination level in `_place`.
            _creditFees(g, level, false);
            uint256 amount = sideLiquidity == 0 ? 0 : FullMath.mulDiv(principal, g.liquidity, sideLiquidity);
            uint256 rest = unsold == 0 ? 0 : FullMath.mulDiv(unsold, g.liquidity, sideLiquidity);
            g.liquidity = 0;
            if (bids) {
                amount += g.pending0;
                g.pending0 = 0;
                g.pending1 += rest.toUint128();
            } else {
                amount += g.pending1;
                g.pending1 = 0;
                g.pending0 += rest.toUint128();
            }
            int24 destination = bids ? sellLevel : levelTick - cfg.spreads[k];
            ops += _place(key, poolId, cfg.levelSpacing, sellLevel, destination, !bids, k, groupId, amount);
        }
        emit LevelFlipped(poolId, levelTick, bids, sideLiquidity, unsold != 0);
    }

    /// @dev Places a flipped group in its destination slot, merging it with the group already there if any.
    /// @param isBid The destination side.
    /// @param amount The group's tokens in the destination side's token.
    /// @return ops 1 if liquidity was added, else 0.
    function _place(
        PoolKey memory key,
        PoolId poolId,
        int24 spacing,
        int24 sellLevel,
        int24 destination,
        bool isBid,
        uint8 k,
        uint64 groupId,
        uint256 amount
    ) internal returns (uint256 ops) {
        Level storage level = _levels[poolId][destination];
        uint64[16] storage strategy = _strategyGroups[poolId][sellLevel];
        uint256 index = _slotIndex(k, isBid);
        uint64 waitingId = strategy[index];

        Placement memory pl;
        (pl.sqrtLower, pl.sqrtUpper) = OrderMath.bounds(destination);
        pl.amount = amount;
        if (waitingId != 0) {
            Group storage waiting = _groups[waitingId];
            pl.compounded = isBid ? waiting.pending1 : waiting.pending0;
        }
        uint256 total = pl.amount + pl.compounded;

        uint256 wanted = isBid
            ? OrderMath.liquidityForAmount1(pl.sqrtLower, pl.sqrtUpper, total, false)
            : OrderMath.liquidityForAmount0(pl.sqrtLower, pl.sqrtUpper, total, false);
        uint256 room = _tickRoom(poolId, level, destination, spacing);
        pl.liquidity = wanted < room ? wanted : room;
        uint256 used;
        if (pl.liquidity != 0) {
            BalanceDelta delta = _modifyLevel(key, level, destination, pl.liquidity.toInt256());
            used = uint256(-int256(isBid ? delta.amount1() : delta.amount0()));
            ops = 1;
        }
        pl.leftover = total - used;
        if (wanted > room) emit AmountUnplaced(groupId, destination, pl.leftover);

        if (waitingId == 0) {
            Group storage g = _groups[groupId];
            g.liquidity = pl.liquidity.toUint128();
            if (isBid) g.pending1 += pl.leftover.toUint128();
            else g.pending0 += pl.leftover.toUint128();
            g.isBid = isBid;
            g.feeGrowthLast0X128 = level.feeGrowth0X128;
            g.feeGrowthLast1X128 = level.feeGrowth1X128;
            strategy[index] = groupId;
            _addToMask(poolId, level, destination, spacing, isBid, k);
        } else {
            strategy[index] = _merge(level, pl, isBid, groupId, waitingId);
        }
        // The level's position is under v4's per-tick limit, below 2^108, so the sum fits.
        if (isBid) level.bidLiquidity += uint112(pl.liquidity);
        else level.askLiquidity += uint112(pl.liquidity);
    }

    /// @dev Merges an arriving group with the group waiting in the same slot. The older one survives (DESIGN.md
    /// section 6), absorbs the other's holders through `mergedShares`, and holds the combined tokens.
    /// @return survivorId The surviving group.
    function _merge(Level storage level, Placement memory pl, bool isBid, uint64 arrivingId, uint64 waitingId)
        internal
        returns (uint64 survivorId)
    {
        Group storage arriving = _groups[arrivingId];
        Group storage waiting = _groups[waitingId];
        // The waiting group's liquidity was in the position when its fees were collected.
        _creditFees(waiting, level);

        // Values in liquidity units of this level, before the merge. The waiting group's compounded tokens are still
        // in its pending balance here, and the arriving group's amount counts as pending in the destination token.
        bool arrivingSurvives = arrivingId < waitingId;
        uint256 arrivingValue = OrderMath.value(
            pl.sqrtLower,
            pl.sqrtUpper,
            0,
            isBid ? arriving.pending0 : pl.amount,
            isBid ? pl.amount : arriving.pending1,
            arrivingSurvives
        );
        uint256 waitingValue = OrderMath.value(
            pl.sqrtLower, pl.sqrtUpper, waiting.liquidity, waiting.pending0, waiting.pending1, !arrivingSurvives
        );

        (Group storage survivor, Group storage absorbed) = arrivingSurvives ? (arriving, waiting) : (waiting, arriving);
        uint256 survivorValue = arrivingSurvives ? arrivingValue : waitingValue;
        uint256 absorbedValue = arrivingSurvives ? waitingValue : arrivingValue;
        uint256 newShares = FullMath.mulDiv(absorbedValue, survivor.totalShares + 1, survivorValue + 1);

        // Combined tokens: the waiting group's liquidity plus what was just added, the leftover in the destination
        // token, and both groups' pending tokens in the other token.
        uint128 liquidity = waiting.liquidity + pl.liquidity.toUint128();
        uint128 pending0;
        uint128 pending1;
        if (isBid) {
            pending0 = arriving.pending0 + waiting.pending0;
            pending1 = waiting.pending1 - pl.compounded.toUint128() + pl.leftover.toUint128();
        } else {
            pending0 = waiting.pending0 - pl.compounded.toUint128() + pl.leftover.toUint128();
            pending1 = arriving.pending1 + waiting.pending1;
        }

        survivor.liquidity = liquidity;
        survivor.pending0 = pending0;
        survivor.pending1 = pending1;
        survivor.isBid = isBid;
        survivor.totalShares += newShares;
        survivor.feeGrowthLast0X128 = level.feeGrowth0X128;
        survivor.feeGrowthLast1X128 = level.feeGrowth1X128;

        absorbed.liquidity = 0;
        absorbed.pending0 = 0;
        absorbed.pending1 = 0;
        absorbed.mergedInto = arrivingSurvives ? arrivingId : waitingId;
        absorbed.mergedShares = newShares;

        survivorId = absorbed.mergedInto;
        emit GroupsMerged(survivorId, arrivingSurvives ? waitingId : arrivingId, newShares);
    }

    /// @dev How much liquidity a level's position can still add under v4's per-tick limit, at both of its ticks.
    /// Only the hook provides liquidity, so with a level spacing above 1, where no two levels share a tick, the
    /// level's own liquidity is exactly what its ticks hold. With spacing 1, neighbors share ticks: ask v4.
    function _tickRoom(PoolId poolId, Level storage level, int24 levelTick, int24 spacing)
        internal
        view
        returns (uint256)
    {
        uint256 gross;
        if (spacing > 1) {
            gross = uint256(level.askLiquidity) + level.bidLiquidity;
        } else {
            (uint128 lowerGross,) = poolManager.getTickLiquidity(poolId, levelTick);
            (uint128 upperGross,) = poolManager.getTickLiquidity(poolId, levelTick + 1);
            gross = lowerGross > upperGross ? lowerGross : upperGross;
        }
        return gross >= MAX_TICK_LIQUIDITY ? 0 : MAX_TICK_LIQUIDITY - gross;
    }
}
