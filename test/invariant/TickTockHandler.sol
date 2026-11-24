// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {TickTockState} from "../../src/base/TickTockState.sol";
import {OrderMath} from "../../src/libraries/OrderMath.sol";
import {TickTockHook} from "../../src/TickTockHook.sol";

/// @notice Random actions on TickTock pools for the invariant suite. Expected reverts are ignored; any other revert
/// is counted, and the invariants require the counts to stay at zero.
contract TickTockHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager internal immutable manager;
    PoolSwapTest internal immutable swapRouter;

    PoolKey[] internal _keys;
    TickTockHook[] internal _hooks;
    address[] internal _actors;

    struct Strategy {
        int24 sellLevel;
        uint8 spreadIndex;
    }

    /// Where each pool's first deposit lands. A pool far below 1:1 reaches v4's per-tick limit with small amounts.
    mapping(uint256 pool => int24) internal _homeTick;
    /// Strategies already used, per pool. Reusing them puts groups on both sides of one strategy, so they merge.
    mapping(uint256 pool => Strategy[]) internal _strategies;

    /// Every level a strategy touched, per pool: flips only ever move between a strategy's two levels.
    mapping(uint256 pool => int24[]) internal _levels;
    mapping(uint256 pool => mapping(int24 => bool)) internal _known;
    mapping(uint256 pool => mapping(int24 => mapping(uint8 => bool))) internal _knownStrategy;

    /// Swaps that reverted inside a TickTock hook's `afterSwap`.
    uint256 public afterSwapReverts;
    /// Reverts outside the expected list, from any action.
    uint256 public unexpectedReverts;
    bytes public lastUnexpected;

    mapping(bytes32 action => uint256) public successes;

    constructor(
        IPoolManager manager_,
        PoolSwapTest swapRouter_,
        PoolKey[] memory keys_,
        int24[] memory homeTicks_,
        address[] memory actors_
    ) {
        manager = manager_;
        swapRouter = swapRouter_;
        for (uint256 i = 0; i < keys_.length; ++i) {
            _keys.push(keys_[i]);
            _homeTick[i] = homeTicks_[i];
            TickTockHook hook = TickTockHook(address(keys_[i].hooks));
            bool seen;
            for (uint256 j = 0; j < _hooks.length; ++j) {
                if (_hooks[j] == hook) seen = true;
            }
            if (!seen) _hooks.push(hook);
        }
        _actors = actors_;

        // The handler swaps through the test router.
        for (uint256 i = 0; i < keys_.length; ++i) {
            for (uint256 c = 0; c < 2; ++c) {
                Currency currency = c == 0 ? keys_[i].currency0 : keys_[i].currency1;
                MockERC20(Currency.unwrap(currency)).mint(address(this), 2 ** 200);
                MockERC20(Currency.unwrap(currency)).approve(address(swapRouter_), type(uint256).max);
            }
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------------------------------------------------------

    function deposit(
        uint256 actorSeed,
        uint256 poolSeed,
        int256 offsetSeed,
        uint256 spreadSeed,
        bool startWithToken0,
        uint256 amountSeed
    ) external {
        uint256 p = poolSeed % _keys.length;
        PoolKey memory key = _keys[p];
        TickTockHook hook = TickTockHook(address(key.hooks));
        (uint24 levelSpacing, int24[] memory spreads) = hook.config();
        int24 spacing = int24(levelSpacing);

        uint8 k;
        int24 sellLevel;
        if (_strategies[p].length != 0 && spreadSeed % 2 == 0) {
            Strategy memory used = _strategies[p][(spreadSeed / 2) % _strategies[p].length];
            (sellLevel, k) = (used.sellLevel, used.spreadIndex);
        } else {
            k = uint8(spreadSeed % spreads.length);
            int24 center = _price(key) == 0 ? _homeTick[p] : _tick(key);
            sellLevel = (center / spacing) * spacing + int24(bound(offsetSeed, -20, 20)) * spacing;
        }
        // Spread evenly over orders of magnitude, so dust sits next to large orders.
        uint128 amount = uint128((10 ** bound(amountSeed % 1000, 3, 22)) * (1 + (amountSeed / 1000) % 9));
        address actor = _actors[actorSeed % _actors.length];

        vm.prank(actor);
        try hook.deposit(key, sellLevel, k, startWithToken0, amount, 0, actor, block.timestamp) {
            _remember(p, sellLevel);
            _remember(p, sellLevel - spreads[k]);
            if (!_knownStrategy[p][sellLevel][k]) {
                _knownStrategy[p][sellLevel][k] = true;
                _strategies[p].push(Strategy(sellLevel, k));
            }
            ++successes["deposit"];
        } catch (bytes memory reason) {
            bytes4 s = bytes4(reason);
            if (
                s != TickTockState.OrdersInTheWay.selector && s != TickTockState.LevelInRange.selector
                    && s != TickTockState.ZeroLiquidity.selector && s != TickTockState.InsufficientShares.selector
                    && s != TickTockState.TooMuchLiquidity.selector && s != Pool.TickLiquidityOverflow.selector
            ) _unexpected(reason);
        }
    }

    function withdraw(uint256 actorSeed, uint256 hookSeed, uint256 groupSeed, uint256 sharesSeed) external {
        TickTockHook hook = _hooks[hookSeed % _hooks.length];
        uint64 last = hook.lastGroupId();
        if (last == 0) return;
        uint64 groupId = uint64(groupSeed % last) + 1;
        address actor = _actors[actorSeed % _actors.length];
        uint256 balance = hook.sharesOf(actor, groupId);
        if (balance == 0) return;
        uint256 shares = bound(sharesSeed, 1, balance);

        vm.prank(actor);
        try hook.withdraw(groupId, shares, actor, block.timestamp) {
            ++successes["withdraw"];
        } catch (bytes memory reason) {
            // Converting a tiny amount of absorbed shares can round to zero.
            if (bytes4(reason) != TickTockState.ZeroShares.selector) _unexpected(reason);
        }
    }

    function swap(uint256 poolSeed, int256 ticksSeed) external {
        PoolKey memory key = _keys[poolSeed % _keys.length];
        uint160 price = _price(key);
        if (price == 0) return;
        int24 target = _clamp(_tick(key) + int24(bound(ticksSeed, -400, 400)));
        uint160 limit = TickMath.getSqrtPriceAtTick(target);
        if (limit == price) return;

        try swapRouter.swap(
            key,
            IPoolManager.SwapParams(limit < price, -int256(uint256(type(uint120).max)), limit),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            ++successes["swap"];
        } catch (bytes memory reason) {
            if (_isAfterSwapRevert(reason, key)) {
                ++afterSwapReverts;
                lastUnexpected = reason;
            } else {
                _unexpected(reason);
            }
        }
    }

    function flipLevel(uint256 poolSeed, uint256 levelSeed) external {
        uint256 p = poolSeed % _keys.length;
        if (_levels[p].length == 0) return;
        int24 level = _levels[p][levelSeed % _levels[p].length];
        try TickTockHook(address(_keys[p].hooks)).flipLevel(_keys[p], level) {
            ++successes["flipLevel"];
        } catch (bytes memory reason) {
            if (bytes4(reason) != TickTockState.NothingToFlip.selector) _unexpected(reason);
        }
    }

    /// Fills a known level to just under v4's per-tick limit, with an order on whichever side the price allows, so
    /// that flips into it must leave some of their amount unplaced.
    function fillTick(uint256 actorSeed, uint256 poolSeed, uint256 levelSeed, uint256 spreadSeed) external {
        uint256 p = poolSeed % _keys.length;
        PoolKey memory key = _keys[p];
        uint160 price = _price(key);
        if (price == 0 || _levels[p].length == 0) return;
        int24 level = _levels[p][levelSeed % _levels[p].length];
        TickTockHook hook = TickTockHook(address(key.hooks));
        (, int24[] memory spreads) = hook.config();
        uint8 k = uint8(spreadSeed % spreads.length);

        (uint128 lowerGross,) = manager.getTickLiquidity(key.toId(), level);
        (uint128 upperGross,) = manager.getTickLiquidity(key.toId(), level + 1);
        uint256 gross = lowerGross > upperGross ? lowerGross : upperGross;
        uint256 max = hook.MAX_TICK_LIQUIDITY();
        if (gross >= max) return;
        uint128 liquidity = uint128((max - gross) * 9_999 / 10_000);
        if (liquidity == 0) return;

        uint160 lower = TickMath.getSqrtPriceAtTick(level);
        uint160 upper = TickMath.getSqrtPriceAtTick(level + 1);
        bool ask = price <= lower;
        if (!ask && price < upper) return; // inside the level
        uint256 amount = ask
            ? OrderMath.amount0ForLiquidity(lower, upper, liquidity, true)
            : OrderMath.amount1ForLiquidity(lower, upper, liquidity, true);
        if (amount == 0 || amount > 1e29) return;
        int24 sellLevel = ask ? level : level + spreads[k];
        if (int256(sellLevel) + 1 > TickMath.MAX_TICK || int256(sellLevel) - spreads[k] < TickMath.MIN_TICK) return;

        address actor = _actors[actorSeed % _actors.length];
        vm.prank(actor);
        try hook.deposit(key, sellLevel, k, ask, uint128(amount), 0, actor, block.timestamp) {
            _remember(p, sellLevel);
            _remember(p, sellLevel - spreads[k]);
            ++successes["fillTick"];
        } catch (bytes memory reason) {
            bytes4 s = bytes4(reason);
            if (
                s != TickTockState.OrdersInTheWay.selector && s != TickTockState.LevelInRange.selector
                    && s != TickTockState.InsufficientShares.selector && s != TickTockState.TooMuchLiquidity.selector
                    && s != Pool.TickLiquidityOverflow.selector && s != TickTockState.LevelNotOnGrid.selector
            ) _unexpected(reason);
        }
    }

    /// Stops the price 85% to 100% of the way through a known level, from either side, then tries `flipLevel`.
    function partialFill(uint256 poolSeed, uint256 levelSeed, uint256 bpsSeed) external {
        uint256 p = poolSeed % _keys.length;
        PoolKey memory key = _keys[p];
        uint160 price = _price(key);
        if (price == 0 || _levels[p].length == 0) return;
        int24 level = _levels[p][levelSeed % _levels[p].length];
        uint160 lower = TickMath.getSqrtPriceAtTick(level);
        uint160 upper = TickMath.getSqrtPriceAtTick(level + 1);
        uint256 bps = bound(bpsSeed, 8_500, 10_000);
        // From below the level, asks sell as the price rises; from above, bids sell as it falls.
        uint160 target = price <= lower
            ? lower + uint160(uint256(upper - lower) * bps / 10_000)
            : upper - uint160(uint256(upper - lower) * bps / 10_000);
        if (target == price) return;

        try swapRouter.swap(
            key,
            IPoolManager.SwapParams(target < price, -int256(uint256(type(uint120).max)), target),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {}
        catch (bytes memory reason) {
            if (_isAfterSwapRevert(reason, key)) ++afterSwapReverts;
            else _unexpected(reason);
            return;
        }
        try TickTockHook(address(key.hooks)).flipLevel(key, level) {
            ++successes["partialFill"];
        } catch (bytes memory reason) {
            if (bytes4(reason) != TickTockState.NothingToFlip.selector) _unexpected(reason);
        }
    }

    function flipCrossed(uint256 poolSeed, uint256 opsSeed) external {
        uint256 p = poolSeed % _keys.length;
        if (_price(_keys[p]) == 0) return;
        try TickTockHook(address(_keys[p].hooks)).flipCrossed(_keys[p], bound(opsSeed, 0, 60)) {
            ++successes["flipCrossed"];
        } catch (bytes memory reason) {
            _unexpected(reason);
        }
    }

    function movePrice(uint256 poolSeed, int256 ticksSeed) external {
        uint256 p = poolSeed % _keys.length;
        PoolKey memory key = _keys[p];
        if (_price(key) == 0) return;
        int24 target = _clamp(_tick(key) + int24(bound(ticksSeed, -600, 600)));
        try TickTockHook(address(key.hooks)).movePrice(key, TickMath.getSqrtPriceAtTick(target)) {
            ++successes["movePrice"];
        } catch (bytes memory reason) {
            bytes4 s = bytes4(reason);
            if (s != TickTockState.OrdersInTheWay.selector && s != TickTockState.LevelInRange.selector) {
                _unexpected(reason);
            }
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views for the invariants
    // ---------------------------------------------------------------------------------------------------------------

    function poolCount() external view returns (uint256) {
        return _keys.length;
    }

    function keyAt(uint256 p) external view returns (PoolKey memory) {
        return _keys[p];
    }

    function hookCount() external view returns (uint256) {
        return _hooks.length;
    }

    function hookAt(uint256 i) external view returns (TickTockHook) {
        return _hooks[i];
    }

    function actors() external view returns (address[] memory) {
        return _actors;
    }

    function levelsOf(uint256 p) external view returns (int24[] memory) {
        return _levels[p];
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _remember(uint256 p, int24 level) internal {
        if (_known[p][level]) return;
        _known[p][level] = true;
        _levels[p].push(level);
    }

    function _unexpected(bytes memory reason) internal {
        ++unexpectedReverts;
        lastUnexpected = reason;
    }

    /// v4 wraps a hook's revert as `WrappedError(hook, selector, reason, HookCallFailed)`.
    function _isAfterSwapRevert(bytes memory reason, PoolKey memory key) internal pure returns (bool) {
        if (reason.length < 4 + 32 * 2 || bytes4(reason) != CustomRevert.WrappedError.selector) return false;
        address target;
        bytes4 selector;
        assembly ("memory-safe") {
            target := mload(add(reason, 36))
            selector := mload(add(reason, 68))
        }
        return target == address(key.hooks) && selector == IHooks.afterSwap.selector;
    }

    function _price(PoolKey memory key) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = manager.getSlot0(key.toId());
    }

    function _tick(PoolKey memory key) internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(key.toId());
    }

    function _clamp(int24 tick) internal pure returns (int24) {
        if (tick < -800_000) return -800_000;
        if (tick > 800_000) return 800_000;
        return tick;
    }
}
