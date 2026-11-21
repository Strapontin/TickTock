// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {TickTockState} from "./base/TickTockState.sol";
import {TickTockEngine} from "./TickTockEngine.sol";
import {HookConfig} from "./libraries/HookConfig.sol";
import {LevelBitmap} from "./libraries/LevelBitmap.sol";
import {OrderMath} from "./libraries/OrderMath.sol";

/// @title TickTockHook
/// @notice A Uniswap v4 hook for double-sided limit orders that repeat forever. See docs/DESIGN.md.
/// @dev The factory deploys this contract once as an implementation, then one minimal clone per config. The pool
/// manager and the swap budget are immutables of the implementation, shared by every clone of one factory. The
/// config (level spacing and spreads) is each clone's immutable args. The implementation refuses every call that
/// doesn't come through a clone.
contract TickTockHook is TickTockState, IHooks, IUnlockCallback, ReentrancyGuardTransient {
    using CurrencyLibrary for Currency;
    using LevelBitmap for mapping(int16 => uint256);
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    enum Action {
        Deposit,
        Withdraw,
        MovePrice,
        FlipLevel
    }

    struct DepositParams {
        PoolKey key;
        int24 sellLevel;
        uint8 spreadIndex;
        bool isBid;
        int24 level;
        int24 levelSpacing;
        uint128 amount;
        uint256 minShares;
        address recipient;
        address payer;
        uint256 value;
    }

    struct DepositResult {
        uint64 groupId;
        uint256 shares;
        uint256 liquidity;
        uint256 paid;
    }

    struct WithdrawParams {
        address owner;
        uint64 groupId;
        uint256 shares;
        address recipient;
    }

    /// @notice The most liquidity operations one swap's `afterSwap` may spend.
    uint16 public immutable maxOpsPerSwap;

    /// @notice The flip logic, run with `delegatecall` on this hook's storage.
    address public immutable engine;

    /// @dev This contract's own address, to tell the implementation apart from its clones.
    address private immutable _implementation;

    // ---------------------------------------------------------------------------------------------------------------
    // Construction and access
    // ---------------------------------------------------------------------------------------------------------------

    constructor(IPoolManager poolManager_, uint16 maxOpsPerSwap_) TickTockState(poolManager_) {
        maxOpsPerSwap = maxOpsPerSwap_;
        engine = address(new TickTockEngine(poolManager_));
        _implementation = address(this);
    }

    modifier onlyClone() {
        _checkClone();
        _;
    }

    modifier onlyPoolManager() {
        _checkPoolManager();
        _;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // User functions
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Places one side of a strategy, creating the pool if needed (DESIGN.md section 7).
    /// @param sellLevel The strategy's sell level `S`.
    /// @param spreadIndex The strategy's spread, as an index in the menu.
    /// @param startWithToken0 True to ask at `S` with token0; false to bid at `S - spreads[spreadIndex]` with token1.
    /// @param amount The most token to pay. The deposit pays what v4 asks for the liquidity it buys.
    /// @param minShares The fewest shares to accept.
    function deposit(
        PoolKey calldata key,
        int24 sellLevel,
        uint8 spreadIndex,
        bool startWithToken0,
        uint128 amount,
        uint256 minShares,
        address recipient,
        uint256 deadline
    ) external payable onlyClone nonReentrant returns (uint64 groupId, uint256 shares) {
        _checkDeadline(deadline);
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert InvalidRecipient();
        _checkPoolKey(key);
        Currency payCurrency = startWithToken0 ? key.currency0 : key.currency1;
        if (msg.value != 0 && !payCurrency.isAddressZero()) revert UnexpectedValue();

        HookConfig.Config memory cfg = _config();
        bool isBid = !startWithToken0;
        int24 level = _strategyLevel(cfg, sellLevel, spreadIndex, isBid);

        DepositResult memory result = abi.decode(
            poolManager.unlock(
                abi.encode(
                    Action.Deposit,
                    abi.encode(
                        DepositParams({
                            key: key,
                            sellLevel: sellLevel,
                            spreadIndex: spreadIndex,
                            isBid: isBid,
                            level: level,
                            levelSpacing: cfg.levelSpacing,
                            amount: amount,
                            minShares: minShares,
                            recipient: recipient,
                            payer: msg.sender,
                            value: msg.value
                        })
                    )
                )
            ),
            (DepositResult)
        );

        if (msg.value > result.paid) SafeTransferLib.safeTransferETH(msg.sender, msg.value - result.paid);

        emit Deposit(
            key.toId(),
            result.groupId,
            recipient,
            msg.sender,
            sellLevel,
            spreadIndex,
            startWithToken0,
            result.paid,
            result.liquidity,
            result.shares
        );
        return (result.groupId, result.shares);
    }

    /// @notice Withdraws shares from a group, in or out of range (DESIGN.md section 8).
    /// @param groupId The group the shares were minted in. If it was absorbed by a merge, the caller's whole balance
    /// in it is converted first, and `shares` is still counted in this group's units.
    function withdraw(uint64 groupId, uint256 shares, address recipient, uint256 deadline)
        external
        onlyClone
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        _checkDeadline(deadline);
        if (shares == 0) revert ZeroShares();
        if (recipient == address(0)) revert InvalidRecipient();

        (uint64 liveGroupId, uint256 liveShares) = _resolveShares(msg.sender, groupId, shares);
        if (liveShares == 0) revert ZeroShares();

        (amount0, amount1) = abi.decode(
            poolManager.unlock(
                abi.encode(
                    Action.Withdraw,
                    abi.encode(
                        WithdrawParams({
                            owner: msg.sender, groupId: liveGroupId, shares: liveShares, recipient: recipient
                        })
                    )
                )
            ),
            (uint256, uint256)
        );
        emit Withdraw(liveGroupId, msg.sender, recipient, liveShares, amount0, amount1);
    }

    /// @notice Moves a pool's price through empty space. Reverts if any liquidity is in the way.
    /// @dev For walking back a price pushed far away, in chunks that each fit in a transaction.
    function movePrice(PoolKey calldata key, uint160 targetSqrtPriceX96) external onlyClone nonReentrant {
        if (_pools[key.toId()].currency1.isAddressZero()) revert PoolNotFound();
        poolManager.unlock(abi.encode(Action.MovePrice, abi.encode(key, targetSqrtPriceX96)));
    }

    /// @notice Flips a level whose orders are fully crossed but weren't flipped by a swap: a skipped level, or one
    /// the swap budget didn't reach (DESIGN.md section 5.4). Anyone can call it.
    function flipLevel(PoolKey calldata key, int24 level) external onlyClone nonReentrant {
        if (_pools[key.toId()].currency1.isAddressZero()) revert PoolNotFound();
        poolManager.unlock(abi.encode(Action.FlipLevel, abi.encode(key, level)));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Action action, bytes memory payload) = abi.decode(data, (Action, bytes));
        if (action == Action.Deposit) return abi.encode(_deposit(abi.decode(payload, (DepositParams))));
        if (action == Action.Withdraw) {
            (uint256 amount0, uint256 amount1) = _withdraw(abi.decode(payload, (WithdrawParams)));
            return abi.encode(amount0, amount1);
        }
        if (action == Action.FlipLevel) {
            (PoolKey memory flipKey, int24 levelTick) = abi.decode(payload, (PoolKey, int24));
            if (_flipIfCrossed(flipKey, flipKey.toId(), _config(), levelTick) == 0) revert NothingToFlip();
            _settleDeltas(flipKey.currency0);
            _settleDeltas(flipKey.currency1);
            return "";
        }
        (PoolKey memory key, uint160 target) = abi.decode(payload, (PoolKey, uint160));
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        if (sqrtPriceX96 != target) _movePrice(key, _pools[key.toId()], sqrtPriceX96, target, false);
        return "";
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice This hook's config.
    function config() external view onlyClone returns (uint24 levelSpacing, int24[] memory spreads) {
        HookConfig.Config memory c = _config();
        levelSpacing = uint24(c.levelSpacing);
        spreads = new int24[](c.spreadCount);
        for (uint256 i = 0; i < c.spreadCount; ++i) {
            spreads[i] = c.spreads[i];
        }
    }

    function getLevel(PoolId poolId, int24 level) external view returns (Level memory) {
        return _levels[poolId][level];
    }

    function getGroup(uint64 groupId) external view returns (Group memory) {
        return _groups[groupId];
    }

    /// @notice A pool's state. A zero `currency1` means the pool doesn't exist.
    function getPool(PoolId poolId) external view returns (PoolState memory) {
        return _pools[poolId];
    }

    /// @notice The group in a slot, or 0 if the slot is empty.
    function slotGroup(PoolId poolId, int24 level, bool isBid, uint8 spreadIndex) external view returns (uint64) {
        return _slotGroups[poolId][level][(isBid ? BID_SLOTS : 0) + spreadIndex];
    }

    /// @notice The live group holding a group's shares: itself, or the group that absorbed it.
    function resolveGroup(uint64 groupId) external view returns (uint64) {
        uint64 survivor = _groups[groupId].mergedInto;
        return survivor == 0 ? groupId : survivor;
    }

    /// @notice What a user's shares in a group are worth now: their part of the group's position at the current
    /// price, of its pending tokens, and of the fees it has earned but not yet collected.
    function positionOf(address user, uint64 groupId)
        external
        view
        onlyClone
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 shares = sharesOf[user][groupId];
        Group storage g = _groups[groupId];
        if (g.mergedInto != 0) {
            shares = FullMath.mulDiv(shares, g.mergedShares, g.totalShares);
            g = _groups[g.mergedInto];
        }
        if (shares == 0) return (0, 0);

        int24 levelTick = _groupLevel(_config(), g);
        Level storage level = _levels[g.poolId][levelTick];
        (uint256 growth0, uint256 growth1) = _projectedFeeGrowth(g.poolId, levelTick, level);
        uint256 pending0;
        uint256 pending1;
        unchecked {
            pending0 = g.pending0 + FullMath.mulDiv(growth0 - g.feeGrowthLast0X128, g.liquidity, FixedPoint128.Q128);
            pending1 = g.pending1 + FullMath.mulDiv(growth1 - g.feeGrowthLast1X128, g.liquidity, FixedPoint128.Q128);
        }

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(g.poolId);
        (uint160 sqrtLower, uint160 sqrtUpper) = OrderMath.bounds(levelTick);
        uint128 liquidity = FullMath.mulDiv(shares, g.liquidity, g.totalShares).toUint128();
        (amount0, amount1) = OrderMath.amountsForLiquidity(sqrtLower, sqrtUpper, sqrtPriceX96, liquidity);
        amount0 += FullMath.mulDiv(shares, pending0, g.totalShares);
        amount1 += FullMath.mulDiv(shares, pending1, g.totalShares);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // v4 hook callbacks
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    /// @dev The hook's own `initialize` calls skip this callback (v4 `noSelfCall`), so only the hook creates pools.
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert PoolCreationRestricted();
    }

    /// @inheritdoc IHooks
    /// @dev The hook's own liquidity calls skip this callback, so only outside LPs are refused.
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert LiquidityRestricted();
    }

    /// @inheritdoc IHooks
    /// @dev Flips arrive in a later step. Until then, crossed levels stay as they are.
    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        onlyClone
        onlyPoolManager
        nonReentrant
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, 0);
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert DonationsBlocked();
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Deposits and withdrawals
    // ---------------------------------------------------------------------------------------------------------------

    function _deposit(DepositParams memory p) internal returns (DepositResult memory r) {
        PoolId poolId = p.key.toId();
        PoolState storage pool = _pools[poolId];
        (uint160 sqrtLower, uint160 sqrtUpper) = OrderMath.bounds(p.level);

        // Create the pool at the order's edge, or put the price on the order's side of the level.
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) {
            sqrtPriceX96 = p.isBid ? sqrtUpper : sqrtLower;
            int24 tick = poolManager.initialize(p.key, sqrtPriceX96);
            (int24 t,,) = OrderMath.crossings(sqrtPriceX96, tick);
            _pools[poolId] = PoolState({
                currency0: p.key.currency0, currency1: p.key.currency1, fee: p.key.fee, askCursor: t, bidCursor: t
            });
        } else {
            // A crossed target level is flipped first, so its orders get their trade (DESIGN.md section 7, step 3).
            _flipIfCrossed(p.key, poolId, _config(), p.level);
            bool insideLevel = sqrtPriceX96 > sqrtLower && sqrtPriceX96 < sqrtUpper;
            if (p.isBid && sqrtPriceX96 < sqrtUpper) _movePrice(p.key, pool, sqrtPriceX96, sqrtUpper, insideLevel);
            if (!p.isBid && sqrtPriceX96 > sqrtLower) _movePrice(p.key, pool, sqrtPriceX96, sqrtLower, insideLevel);
        }

        r.liquidity = p.isBid
            ? OrderMath.liquidityForAmount1(sqrtLower, sqrtUpper, p.amount, false)
            : OrderMath.liquidityForAmount0(sqrtLower, sqrtUpper, p.amount, false);
        if (r.liquidity == 0) revert ZeroLiquidity();
        // v4 caps a tick at about 2^107 with tick spacing 1. Checking here gives a clear error before v4's casts.
        if (r.liquidity > type(uint112).max) revert TooMuchLiquidity();

        Level storage level = _levels[poolId][p.level];
        BalanceDelta principal = _modifyLevel(p.key, level, p.level, r.liquidity.toInt256());

        uint256 slotIndex = (p.isBid ? BID_SLOTS : 0) + p.spreadIndex;
        r.groupId = _slotGroups[poolId][p.level][slotIndex];
        Group storage g;
        if (r.groupId == 0) {
            r.groupId = ++lastGroupId;
            g = _groups[r.groupId];
            g.poolId = poolId;
            g.sellLevel = p.sellLevel;
            g.spreadIndex = p.spreadIndex;
            g.isBid = p.isBid;
            g.feeGrowthLast0X128 = level.feeGrowth0X128;
            g.feeGrowthLast1X128 = level.feeGrowth1X128;
            _slotGroups[poolId][p.level][slotIndex] = r.groupId;
            _addToMask(poolId, level, p.level, p.levelSpacing, p.isBid, p.spreadIndex);
        } else {
            g = _groups[r.groupId];
            _creditFees(g, level);
        }

        // Value rounds up and shares round down, in favor of existing holders. The `+ 1`s are virtual shares.
        uint256 value = OrderMath.value(sqrtLower, sqrtUpper, g.liquidity, g.pending0, g.pending1, true);
        r.shares = FullMath.mulDiv(r.liquidity, g.totalShares + 1, value + 1);
        if (r.shares == 0 || r.shares < p.minShares) revert InsufficientShares();

        g.liquidity += r.liquidity.toUint128();
        g.totalShares += r.shares;
        sharesOf[p.recipient][r.groupId] += r.shares;
        if (p.isBid) level.bidLiquidity += uint112(r.liquidity);
        else level.askLiquidity += uint112(r.liquidity);

        // v4 accepted the liquidity, so the level is under its per-tick cap of about 2^107: the casts above fit.
        r.paid = uint256(-int256(p.isBid ? principal.amount1() : principal.amount0()));
        _pay(p.isBid ? p.key.currency1 : p.key.currency0, p.payer, r.paid, p.value);
        _settleDeltas(p.key.currency0);
        _settleDeltas(p.key.currency1);
    }

    function _withdraw(WithdrawParams memory p) internal returns (uint256 amount0, uint256 amount1) {
        Group storage g = _groups[p.groupId];
        PoolId poolId = g.poolId;
        PoolKey memory key = _poolKey(_pools[poolId]);
        HookConfig.Config memory cfg = _config();
        int24 levelTick = _groupLevel(cfg, g);
        Level storage level = _levels[poolId][levelTick];

        uint256 totalShares = g.totalShares;
        uint256 liquidity = FullMath.mulDiv(p.shares, g.liquidity, totalShares);
        BalanceDelta principal;
        // Even with nothing to remove, touching the position collects its fees.
        if (uint256(level.askLiquidity) + level.bidLiquidity != 0) {
            principal = _modifyLevel(key, level, levelTick, -liquidity.toInt256());
        }
        _creditFees(g, level);

        uint256 pendingOut0 = FullMath.mulDiv(p.shares, g.pending0, totalShares);
        uint256 pendingOut1 = FullMath.mulDiv(p.shares, g.pending1, totalShares);
        // `shares <= totalShares`, so each amount is at most the field it comes out of and the casts fit.
        // forge-lint: disable-start(unsafe-typecast)
        g.pending0 -= uint128(pendingOut0);
        g.pending1 -= uint128(pendingOut1);
        g.liquidity -= uint128(liquidity);
        g.totalShares = totalShares - p.shares;
        sharesOf[p.owner][p.groupId] -= p.shares;
        if (g.isBid) level.bidLiquidity -= uint112(liquidity);
        else level.askLiquidity -= uint112(liquidity);
        // forge-lint: disable-end(unsafe-typecast)
        if (g.totalShares == 0) _freeSlot(poolId, level, levelTick, cfg.levelSpacing, g);

        // A removal only ever yields tokens, so the principal's amounts are non-negative.
        amount0 = uint256(int256(principal.amount0())) + pendingOut0;
        amount1 = uint256(int256(principal.amount1())) + pendingOut1;
        if (amount0 != 0) poolManager.take(key.currency0, p.recipient, amount0);
        if (amount1 != 0) poolManager.take(key.currency1, p.recipient, amount1);
        _settleDeltas(key.currency0);
        _settleDeltas(key.currency1);
    }

    /// @dev Converts the owner's whole balance in an absorbed group into the survivor's shares (one hop at most,
    /// DESIGN.md section 6), and returns the group and share amount to withdraw.
    function _resolveShares(address owner, uint64 groupId, uint256 shares) internal returns (uint64, uint256) {
        Group storage g = _groups[groupId];
        uint256 balance = sharesOf[owner][groupId];
        if (shares > balance) revert InsufficientShares();
        uint64 survivor = g.mergedInto;
        if (survivor == 0) return (groupId, shares);

        uint256 converted = FullMath.mulDiv(balance, g.mergedShares, g.totalShares);
        sharesOf[owner][groupId] = 0;
        sharesOf[owner][survivor] += converted;
        emit SharesConverted(owner, groupId, survivor, balance, converted);
        return (survivor, shares == balance ? converted : FullMath.mulDiv(shares, g.mergedShares, g.totalShares));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Flips and merges
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Flips whichever side of a level is fully crossed, if either is.
    /// @return ops The liquidity operations spent, 0 if nothing flipped.
    function _flipIfCrossed(PoolKey memory key, PoolId poolId, HookConfig.Config memory cfg, int24 levelTick)
        internal
        returns (uint256 ops)
    {
        if (levelTick % cfg.levelSpacing != 0) return 0;
        Level storage level = _levels[poolId][levelTick];
        if (level.askMask == 0 && level.bidMask == 0) return 0;
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
        (, int24 highestCrossedAsk, int24 lowestCrossedBid) = OrderMath.crossings(sqrtPriceX96, tick);
        if (level.askMask != 0 && levelTick <= highestCrossedAsk) return _engineFlip(key, levelTick, false);
        if (level.bidMask != 0 && levelTick >= lowestCrossedBid) return _engineFlip(key, levelTick, true);
        return 0;
    }

    /// @dev Runs `TickTockEngine.flipSide` on this hook's storage.
    function _engineFlip(PoolKey memory key, int24 levelTick, bool bids) internal returns (uint256 ops) {
        (bool success, bytes memory result) =
            engine.delegatecall(abi.encodeCall(TickTockEngine.flipSide, (key, levelTick, bids)));
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
        return abi.decode(result, (uint256));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Positions, fees and settlement
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev A level's fee growth including the fees its position earned but hasn't collected yet.
    function _projectedFeeGrowth(PoolId poolId, int24 levelTick, Level storage level)
        internal
        view
        returns (uint256 growth0, uint256 growth1)
    {
        growth0 = level.feeGrowth0X128;
        growth1 = level.feeGrowth1X128;
        uint256 liquidity = uint256(level.askLiquidity) + level.bidLiquidity;
        if (liquidity == 0) return (growth0, growth1);

        (, uint256 last0, uint256 last1) =
            poolManager.getPositionInfo(poolId, address(this), levelTick, levelTick + 1, bytes32(0));
        (uint256 inside0, uint256 inside1) = poolManager.getFeeGrowthInside(poolId, levelTick, levelTick + 1);
        unchecked {
            uint256 owed0 = FullMath.mulDiv(inside0 - last0, liquidity, FixedPoint128.Q128);
            uint256 owed1 = FullMath.mulDiv(inside1 - last1, liquidity, FixedPoint128.Q128);
            growth0 += FullMath.mulDiv(owed0, FixedPoint128.Q128, liquidity);
            growth1 += FullMath.mulDiv(owed1, FixedPoint128.Q128, liquidity);
        }
    }

    /// @dev Pays the pool manager `amount` of `currency` from `payer`, or from the ETH sent with the call.
    function _pay(Currency currency, address payer, uint256 amount, uint256 value) internal {
        if (amount == 0) return;
        if (currency.isAddressZero()) {
            if (value < amount) revert InsufficientValue();
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            SafeTransferLib.safeTransferFrom(Currency.unwrap(currency), payer, address(poolManager), amount);
            poolManager.settle();
        }
    }

    /// @dev Zeroes the hook's balance change in a currency: a credit is minted as ERC-6909 claims, a debt is paid
    /// by burning claims (DESIGN.md section 5.2, step 6).
    function _settleDeltas(Currency currency) internal {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (delta > 0) poolManager.mint(address(this), currency.toId(), uint256(delta));
        // forge-lint: disable-next-line(unsafe-typecast)
        else if (delta < 0) poolManager.burn(address(this), currency.toId(), uint256(-delta));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Price moves
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Moves the price to `target` with a 1-wei swap, which must reach it at no cost: any liquidity in the way
    /// would either stop it or trade (DESIGN.md section 7, step 4). Then updates the cursor on the far side.
    function _movePrice(PoolKey memory key, PoolState storage pool, uint160 from, uint160 target, bool insideLevel)
        internal
    {
        bool down = target < from;
        BalanceDelta delta = poolManager.swap(key, IPoolManager.SwapParams(down, -1, target), "");
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(key.toId());
        if (BalanceDelta.unwrap(delta) != 0 || sqrtPriceX96 != target) {
            if (insideLevel) revert LevelInRange();
            revert OrdersInTheWay();
        }
        (int24 t,,) = OrderMath.crossings(sqrtPriceX96, tick);
        if (down) {
            if (t < pool.askCursor) pool.askCursor = t;
        } else if (t > pool.bidCursor) {
            pool.bidCursor = t;
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Slots
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Empties a group's slot. The group is never reused: the next deposit there gets a new id.
    function _freeSlot(PoolId poolId, Level storage level, int24 levelTick, int24 spacing, Group storage g) internal {
        uint8 k = g.spreadIndex;
        // forge-lint: disable-next-line(incorrect-shift)
        uint8 bit = uint8(1 << k);
        if (g.isBid) {
            _slotGroups[poolId][levelTick][BID_SLOTS + k] = 0;
            level.bidMask &= ~bit;
            if (level.bidMask == 0) _bidBitmap[poolId].clear(levelTick, spacing);
        } else {
            _slotGroups[poolId][levelTick][k] = 0;
            level.askMask &= ~bit;
            if (level.askMask == 0) _askBitmap[poolId].clear(levelTick, spacing);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Validates a strategy and returns the level of the side being placed (DESIGN.md section 7, step 1).
    function _strategyLevel(HookConfig.Config memory cfg, int24 sellLevel, uint8 spreadIndex, bool isBid)
        internal
        pure
        returns (int24)
    {
        if (spreadIndex >= cfg.spreadCount) revert InvalidSpreadIndex();
        if (sellLevel % cfg.levelSpacing != 0) revert LevelNotOnGrid();
        int24 spread = cfg.spreads[spreadIndex];
        if (int256(sellLevel) + 1 > TickMath.MAX_TICK || int256(sellLevel) - spread < TickMath.MIN_TICK) {
            revert StrategyOutOfBounds();
        }
        return isBid ? sellLevel - spread : sellLevel;
    }

    function _groupLevel(HookConfig.Config memory cfg, Group storage g) internal view returns (int24) {
        return g.isBid ? g.sellLevel - cfg.spreads[g.spreadIndex] : g.sellLevel;
    }

    function _poolKey(PoolState storage pool) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: pool.currency0,
            currency1: pool.currency1,
            fee: pool.fee,
            tickSpacing: 1,
            hooks: IHooks(address(this))
        });
    }

    function _checkPoolKey(PoolKey calldata key) internal view {
        if (address(key.hooks) != address(this) || key.tickSpacing != 1) revert InvalidPoolKey();
        if (key.fee.isDynamicFee()) revert DynamicFeeNotSupported();
    }

    function _checkDeadline(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert DeadlinePassed();
    }

    function _checkClone() internal view {
        if (address(this) == _implementation) revert NotAClone();
    }

    function _checkPoolManager() internal view {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    /// @dev v4 needs transient storage on every chain it runs on, so the lock always uses it. Solady's default
    /// falls back to regular storage outside Ethereum mainnet.
    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }
}
