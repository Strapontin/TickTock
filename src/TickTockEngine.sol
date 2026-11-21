// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
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

    /// @notice Flips one fully crossed side of a level. The hook checks that the side is crossed first.
    /// @return ops The liquidity operations spent.
    function flipSide(PoolKey calldata key, int24 levelTick, bool bids) external returns (uint256 ops) {
        if (address(this) == _self) revert NotDelegateCall();
        return _flipSide(key, key.toId(), _config(), levelTick, bids);
    }

    /// @dev Flips one fully converted side of a level: removes its liquidity, then re-posts each group's share,
    /// plus its pending tokens in the new token, at the opposite slot of its strategy (DESIGN.md section 5.2).
    /// @param bids True to flip the level's bids into asks, false to flip its asks into bids.
    /// @return ops The liquidity operations spent: one removal plus one addition per destination.
    function _flipSide(PoolKey memory key, PoolId poolId, HookConfig.Config memory cfg, int24 levelTick, bool bids)
        internal
        returns (uint256 ops)
    {
        Level storage level = _levels[poolId][levelTick];
        (uint256 sideLiquidity, uint8 mask) =
            bids ? (uint256(level.bidLiquidity), level.bidMask) : (uint256(level.askLiquidity), level.askMask);

        // The side is fully converted: asks into token1, bids into token0. The removal's fees accrue over the
        // level's whole liquidity, before the side leaves it.
        uint256 principal;
        if (sideLiquidity != 0) {
            BalanceDelta delta = _modifyLevel(key, level, levelTick, -sideLiquidity.toInt256());
            principal = uint256(int256(bids ? delta.amount0() : delta.amount1()));
            ops = 1;
        }
        if (bids) {
            (level.bidLiquidity, level.bidMask) = (0, 0);
            _bidBitmap[poolId].clear(levelTick, cfg.levelSpacing);
        } else {
            (level.askLiquidity, level.askMask) = (0, 0);
            _askBitmap[poolId].clear(levelTick, cfg.levelSpacing);
        }

        uint64[16] storage slots = _slotGroups[poolId][levelTick];
        for (uint8 k = 0; k < cfg.spreadCount; ++k) {
            // forge-lint: disable-next-line(incorrect-shift)
            if (mask & (1 << k) == 0) continue;
            uint256 index = (bids ? BID_SLOTS : 0) + k;
            uint64 groupId = slots[index];
            slots[index] = 0;

            Group storage g = _groups[groupId];
            _creditFees(g, level);
            uint256 amount = sideLiquidity == 0 ? 0 : FullMath.mulDiv(principal, g.liquidity, sideLiquidity);
            g.liquidity = 0;
            if (bids) {
                amount += g.pending0;
                g.pending0 = 0;
            } else {
                amount += g.pending1;
                g.pending1 = 0;
            }
            int24 destination = bids ? levelTick + cfg.spreads[k] : levelTick - cfg.spreads[k];
            ops += _place(key, poolId, cfg.levelSpacing, destination, !bids, k, groupId, amount);
        }
        emit LevelFlipped(poolId, levelTick, bids, sideLiquidity, false);
    }

    /// @dev Places a flipped group in its destination slot, merging it with the group already there if any.
    /// @param isBid The destination side.
    /// @param amount The group's tokens in the destination side's token.
    /// @return ops 1 if liquidity was added, else 0.
    function _place(
        PoolKey memory key,
        PoolId poolId,
        int24 spacing,
        int24 destination,
        bool isBid,
        uint8 k,
        uint64 groupId,
        uint256 amount
    ) internal returns (uint256 ops) {
        Level storage level = _levels[poolId][destination];
        uint256 index = (isBid ? BID_SLOTS : 0) + k;
        uint64 waitingId = _slotGroups[poolId][destination][index];

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
        uint256 room = _tickRoom(poolId, destination);
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
            _slotGroups[poolId][destination][index] = groupId;
            _addToMask(poolId, level, destination, spacing, isBid, k);
        } else {
            uint64 survivor = _merge(level, pl, isBid, groupId, waitingId);
            _slotGroups[poolId][destination][index] = survivor;
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
    function _tickRoom(PoolId poolId, int24 levelTick) internal view returns (uint256) {
        (uint128 lowerGross,) = poolManager.getTickLiquidity(poolId, levelTick);
        (uint128 upperGross,) = poolManager.getTickLiquidity(poolId, levelTick + 1);
        uint256 gross = lowerGross > upperGross ? lowerGross : upperGross;
        return gross >= MAX_TICK_LIQUIDITY ? 0 : MAX_TICK_LIQUIDITY - gross;
    }
}
