// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {HookConfig} from "../libraries/HookConfig.sol";
import {LevelBitmap} from "../libraries/LevelBitmap.sol";

/// @title TickTockState
/// @notice The storage, types, events and errors shared by `TickTockHook` and `TickTockEngine`, plus the helpers
/// both use.
/// @dev The hook runs the engine's code with `delegatecall`, on the clone's storage, so both contracts must have the
/// exact same storage layout. All storage lives here: derived contracts must not declare any state variables.
abstract contract TickTockState {
    using LevelBitmap for mapping(int16 => uint256);
    using SafeCast for uint256;

    // ---------------------------------------------------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice One order level `[L, L+1)`. The hook owns one v4 position per level, holding both sides.
    struct Level {
        uint112 askLiquidity;
        uint112 bidLiquidity;
        /// @dev Bit k is set when the ask (or bid) slot for spread k at this level holds a group.
        uint8 askMask;
        uint8 bidMask;
        /// @dev Set the first time the level holds a group, never cleared. It keeps the word non-zero once the level
        /// empties, so the next round trip through it writes a used word instead of a fresh one.
        bool used;
        /// @dev Fees per unit of the level's liquidity, as in v4. Wraps on overflow.
        uint256 feeGrowth0X128;
        uint256 feeGrowth1X128;
    }

    /// @notice The users sharing one slot.
    struct Group {
        uint128 liquidity;
        uint128 pending0;
        uint128 pending1;
        /// @dev Set when the group was absorbed by a merge. Its `totalShares` is then frozen.
        uint64 mergedInto;
        /// @dev The current slot: the strategy `(sellLevel, spreadIndex)` and its side.
        int24 sellLevel;
        uint8 spreadIndex;
        bool isBid;
        PoolId poolId;
        uint256 totalShares;
        uint256 feeGrowthLast0X128;
        uint256 feeGrowthLast1X128;
        /// @dev Shares the survivor minted for this group's holders, when absorbed.
        uint256 mergedShares;
    }

    /// @notice A pool's key (tick spacing 1 and this hook are implied) and its scan cursors.
    struct PoolState {
        Currency currency0;
        Currency currency1;
        uint24 fee;
        int24 askCursor;
        int24 bidCursor;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Constants, immutables and storage
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice v4's liquidity limit per tick with tick spacing 1: `type(uint128).max / numTicks`, where
    /// `numTicks = MAX_TICK - MIN_TICK + 1`.
    uint256 public constant MAX_TICK_LIQUIDITY = type(uint128).max / 1_774_545;

    /// @notice The v4 pool manager.
    IPoolManager public immutable poolManager;

    /// @notice The id of the last group created. Ids only increase, so a lower id is an older group.
    uint64 public lastGroupId;

    /// @notice A user's shares in a group.
    mapping(address user => mapping(uint64 groupId => uint256)) public sharesOf;

    mapping(PoolId => PoolState) internal _pools;
    mapping(PoolId => mapping(int24 level => Level)) internal _levels;
    /// @dev The groups in each strategy's two slots, by sell level: index `2k` is the ask slot at the sell level,
    /// `2k + 1` the bid slot at `sellLevel - spreads[k]`. Both slots of a strategy share a storage word, so a flip
    /// between them rewrites one word instead of writing a fresh one.
    mapping(PoolId => mapping(int24 sellLevel => uint64[16])) internal _strategyGroups;
    mapping(PoolId => mapping(int16 => uint256)) internal _askBitmap;
    mapping(PoolId => mapping(int16 => uint256)) internal _bidBitmap;
    mapping(uint64 groupId => Group) internal _groups;

    // ---------------------------------------------------------------------------------------------------------------
    // Events and errors
    // ---------------------------------------------------------------------------------------------------------------

    event Deposit(
        PoolId indexed poolId,
        uint64 indexed groupId,
        address indexed recipient,
        address sender,
        int24 sellLevel,
        uint8 spreadIndex,
        bool startWithToken0,
        uint256 amount,
        uint256 liquidity,
        uint256 shares
    );
    event Withdraw(
        uint64 indexed groupId,
        address indexed owner,
        address recipient,
        uint256 shares,
        uint256 amount0,
        uint256 amount1
    );
    /// @param bids True when bids flipped into asks, false when asks flipped into bids.
    event LevelFlipped(PoolId indexed poolId, int24 indexed level, bool bids, uint256 liquidity, bool partialFill);
    event GroupsMerged(uint64 indexed survivor, uint64 indexed absorbed, uint256 newShares);
    /// @notice A scan passed over a crossed level that was small next to the largest one crossed with it. Anyone can
    /// flip it with `flipLevel`.
    event LevelSkipped(PoolId indexed poolId, int24 indexed level, bool bids);
    /// @notice A flip couldn't place `amount` at `level` because of v4's per-tick limit. It stays pending.
    event AmountUnplaced(uint64 indexed groupId, int24 level, uint256 amount);
    event SharesConverted(
        address indexed owner, uint64 indexed fromGroup, uint64 indexed toGroup, uint256 fromShares, uint256 toShares
    );

    /// @notice The implementation was called directly instead of through a clone.
    error NotAClone();
    /// @notice The engine was called directly instead of through the hook.
    error NotDelegateCall();
    /// @notice A pool callback came from someone other than the pool manager.
    error NotPoolManager();
    /// @notice Pools are only created by the hook, on the first deposit.
    error PoolCreationRestricted();
    /// @notice Only the hook provides liquidity in its pools.
    error LiquidityRestricted();
    /// @notice Donations are blocked.
    error DonationsBlocked();
    /// @notice A callback whose permission flag is off was called.
    error HookNotImplemented();
    error DeadlinePassed();
    error ZeroAmount();
    error ZeroShares();
    error InvalidRecipient();
    /// @notice The key's hook isn't this one, or its tick spacing isn't 1.
    error InvalidPoolKey();
    error DynamicFeeNotSupported();
    error InvalidSpreadIndex();
    error LevelNotOnGrid();
    /// @notice One of the strategy's two levels is outside v4's tick bounds.
    error StrategyOutOfBounds();
    error PoolNotFound();
    /// @notice The amount is too small to buy any liquidity.
    error ZeroLiquidity();
    /// @notice The amount buys more liquidity than one tick can hold.
    error TooMuchLiquidity();
    error InsufficientShares();
    /// @notice Orders sit between the price and where the deposit needs it.
    error OrdersInTheWay();
    /// @notice The price is inside the level, which holds orders.
    error LevelInRange();
    /// @notice ETH was sent for a token that isn't native.
    error UnexpectedValue();
    error InsufficientValue();
    /// @notice The level has no fully crossed side.
    error NothingToFlip();

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Shared helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The clone's config. Under `delegatecall`, `address(this)` is the clone, whose code holds the args.
    function _config() internal view returns (HookConfig.Config memory) {
        return HookConfig.decode(LibClone.argsOnClone(address(this)));
    }

    /// @dev Changes a level's position and adds the fees it collected to the level's fee growth, over the liquidity
    /// the level had before the change. Returns the principal part of the hook's balance change.
    function _modifyLevel(PoolKey memory key, Level storage level, int24 levelTick, int256 liquidityDelta)
        internal
        returns (BalanceDelta principal)
    {
        uint256 liquidityBefore = uint256(level.askLiquidity) + level.bidLiquidity;
        (BalanceDelta callerDelta, BalanceDelta fees) = poolManager.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams(levelTick, levelTick + 1, liquidityDelta, 0), ""
        );
        if (liquidityBefore != 0) {
            // Fees are never negative. Growth wraps on overflow, as in v4.
            uint256 fees0 = uint256(int256(fees.amount0()));
            uint256 fees1 = uint256(int256(fees.amount1()));
            unchecked {
                if (fees0 != 0) level.feeGrowth0X128 += FullMath.mulDiv(fees0, FixedPoint128.Q128, liquidityBefore);
                if (fees1 != 0) level.feeGrowth1X128 += FullMath.mulDiv(fees1, FixedPoint128.Q128, liquidityBefore);
            }
        }
        principal = callerDelta - fees;
    }

    /// @dev Credits a group the fees its liquidity earned at its level since it was last credited, and moves its
    /// snapshot to the level's current growth.
    function _creditFees(Group storage g, Level storage level) internal {
        _creditFees(g, level, true);
    }

    /// @param snapshot False when the group is leaving the level and its snapshot is about to be overwritten.
    function _creditFees(Group storage g, Level storage level, bool snapshot) internal {
        uint256 growth0 = level.feeGrowth0X128;
        uint256 growth1 = level.feeGrowth1X128;
        uint256 liquidity = g.liquidity;
        if (liquidity != 0) {
            // Growth differences wrap, as in v4. The additions are checked: a pending balance must never wrap.
            uint256 delta0;
            uint256 delta1;
            unchecked {
                delta0 = growth0 - g.feeGrowthLast0X128;
                delta1 = growth1 - g.feeGrowthLast1X128;
            }
            g.pending0 += FullMath.mulDiv(delta0, liquidity, FixedPoint128.Q128).toUint128();
            g.pending1 += FullMath.mulDiv(delta1, liquidity, FixedPoint128.Q128).toUint128();
        }
        if (snapshot) {
            g.feeGrowthLast0X128 = growth0;
            g.feeGrowthLast1X128 = growth1;
        }
    }

    /// @dev Where a slot's group id lives in its strategy's word.
    function _slotIndex(uint8 k, bool isBid) internal pure returns (uint256) {
        return 2 * uint256(k) + (isBid ? 1 : 0);
    }

    /// @dev Marks a slot as holding a group, and the level as holding that side.
    function _addToMask(PoolId poolId, Level storage level, int24 levelTick, int24 spacing, bool isBid, uint8 k)
        internal
    {
        // forge-lint: disable-next-line(incorrect-shift)
        uint8 bit = uint8(1 << k);
        if (isBid) {
            if (level.bidMask == 0) _bidBitmap[poolId].set(levelTick, spacing);
            level.bidMask |= bit;
        } else {
            if (level.askMask == 0) _askBitmap[poolId].set(levelTick, spacing);
            level.askMask |= bit;
        }
        level.used = true;
    }
}
