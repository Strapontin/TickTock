// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickTockState} from "../../src/base/TickTockState.sol";
import {OrderMath} from "../../src/libraries/OrderMath.sol";
import {TickTockHook} from "../../src/TickTockHook.sol";
import {TickTockTestBase} from "../utils/TickTockTestBase.sol";
import {TickTockHandler} from "./TickTockHandler.sol";

/// @notice The setup shared by the invariant suite and its coverage guard: three pools, two of which share one hook
/// (so they share its ERC-6909 claims), the third with a second config starting far below 1:1, where small amounts
/// reach v4's per-tick limit. Plus the end-of-run check that everyone can withdraw everything.
abstract contract TickTockInvariantSetup is StdInvariant, TickTockTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    TickTockHandler internal handler;

    function setUp() public override {
        super.setUp();
        TickTockHook wide = _createHook(10, _spreads(10, 50, 100));
        TickTockHook tight = _createHook(1, _spreads(1, 3));

        PoolKey[] memory keys = new PoolKey[](3);
        keys[0] = PoolKey(currency0, currency1, 3000, 1, IHooks(address(wide)));
        keys[1] = PoolKey(currency0, currency1, 500, 1, IHooks(address(wide)));
        keys[2] = PoolKey(currency0, currency1, 0, 1, IHooks(address(tight)));

        address[] memory actors = new address[](4);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        actors[3] = makeAddr("dave");
        for (uint256 i = 0; i < actors.length; ++i) {
            _fund(actors[i], wide);
            _fund(actors[i], tight);
        }

        int24[] memory homeTicks = new int24[](3);
        homeTicks[2] = -600_000;
        handler = new TickTockHandler(manager, swapRouter, keys, homeTicks, actors);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = TickTockHandler.deposit.selector;
        selectors[1] = TickTockHandler.withdraw.selector;
        selectors[2] = TickTockHandler.swap.selector;
        selectors[3] = TickTockHandler.flipLevel.selector;
        selectors[4] = TickTockHandler.flipCrossed.selector;
        selectors[5] = TickTockHandler.movePrice.selector;
        selectors[6] = TickTockHandler.partialFill.selector;
        selectors[7] = TickTockHandler.fillTick.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // At the end of each run
    // ---------------------------------------------------------------------------------------------------------------

    /// Everyone can withdraw everything, in any state the run reached, and the hook never runs short. Afterwards
    /// nothing users own is stuck:
    /// - Claims no group owns are rounding dust from splitting amounts between groups.
    /// - What groups still hold belongs to shares nobody owns. Converting absorbed shares rounds down, so that's
    ///   less than one share per holder per merge. Measured in wei it can look large where a token is nearly
    ///   worthless (far from a 1:1 price), so it's bounded in shares instead.
    function _withdrawEveryoneAndCheck() internal {
        uint256 snapshot = vm.snapshotState();
        address[] memory actors = handler.actors();
        for (uint256 h = 0; h < handler.hookCount(); ++h) {
            TickTockHook hook = handler.hookAt(h);
            for (uint64 id = 1; id <= hook.lastGroupId(); ++id) {
                for (uint256 a = 0; a < actors.length; ++a) {
                    uint256 shares = hook.sharesOf(actors[a], id);
                    if (shares == 0) continue;
                    vm.prank(actors[a]);
                    try hook.withdraw(id, shares, actors[a], block.timestamp) {}
                    catch (bytes memory reason) {
                        // Converting dust from an absorbed group can round to zero shares, and then there's
                        // nothing to withdraw.
                        if (bytes4(reason) != TickTockState.ZeroShares.selector) {
                            assertTrue(false, "a full withdrawal reverted");
                        }
                    }
                }
            }
            _checkOnlyDustLeft(hook, actors.length);
        }
        vm.revertToState(snapshot);
    }

    function _checkOnlyDustLeft(TickTockHook hook, uint256 holders) internal view {
        uint64 last = hook.lastGroupId();
        uint256[] memory merges = new uint256[](last + 1);
        uint256 pending0;
        uint256 pending1;
        for (uint64 id = 1; id <= last; ++id) {
            TickTockState.Group memory g = hook.getGroup(id);
            if (g.mergedInto != 0) ++merges[g.mergedInto];
            pending0 += g.pending0;
            pending1 += g.pending1;
        }
        assertLe(manager.balanceOf(address(hook), currency0.toId()) - pending0, 1e4, "unowned claims0 are dust");
        assertLe(manager.balanceOf(address(hook), currency1.toId()) - pending1, 1e4, "unowned claims1 are dust");
        for (uint64 id = 1; id <= last; ++id) {
            TickTockState.Group memory g = hook.getGroup(id);
            if (g.mergedInto == 0) assertLe(g.totalShares, merges[id] * holders, "only rounding shares are left");
        }
    }
}

/// @notice Invariants under random deposits, withdrawals, swaps, flips and price moves (DESIGN.md section 11).
/// Runs are deep rather than many: merges, skips and per-tick limits need a built-up order book.
/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 150
/// forge-config: ci.invariant.runs = 128
/// forge-config: ci.invariant.depth = 250
contract TickTockInvariantsTest is TickTockInvariantSetup {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ---------------------------------------------------------------------------------------------------------------
    // After every action
    // ---------------------------------------------------------------------------------------------------------------

    function invariant_afterSwapNeverReverts() public view {
        assertEq(handler.afterSwapReverts(), 0, string(handler.lastUnexpected()));
    }

    function invariant_noUnexpectedReverts() public view {
        assertEq(handler.unexpectedReverts(), 0, string(handler.lastUnexpected()));
    }

    /// Each level's v4 position holds exactly its groups' liquidity, and every slot agrees with its group.
    function invariant_levelsMatchTheirGroups() public view {
        for (uint256 p = 0; p < handler.poolCount(); ++p) {
            PoolKey memory key = handler.keyAt(p);
            TickTockHook hook = TickTockHook(address(key.hooks));
            int24[] memory levels = handler.levelsOf(p);
            for (uint256 i = 0; i < levels.length; ++i) {
                _checkLevel(hook, key, levels[i]);
            }
        }
    }

    function _checkLevel(TickTockHook hook, PoolKey memory key, int24 level) internal view {
        PoolId poolId = key.toId();
        (, int24[] memory spreads) = hook.config();
        TickTockState.Level memory l = hook.getLevel(poolId, level);
        (uint128 position,,) = manager.getPositionInfo(poolId, address(hook), level, level + 1, bytes32(0));
        assertEq(position, uint256(l.askLiquidity) + l.bidLiquidity, "position == asks + bids");

        uint256 asks;
        uint256 bids;
        for (uint8 k = 0; k < spreads.length; ++k) {
            uint64 askGroup = hook.slotGroup(poolId, level, false, k);
            assertEq((l.askMask >> k) & 1 == 1, askGroup != 0, "ask mask == ask slot");
            if (askGroup != 0) asks += _checkGroup(hook, poolId, l, askGroup, level, k, false);

            uint64 bidGroup = hook.slotGroup(poolId, level, true, k);
            assertEq((l.bidMask >> k) & 1 == 1, bidGroup != 0, "bid mask == bid slot");
            if (bidGroup != 0) bids += _checkGroup(hook, poolId, l, bidGroup, level + spreads[k], k, true);
        }
        assertEq(asks, l.askLiquidity, "asks == sum of ask groups");
        assertEq(bids, l.bidLiquidity, "bids == sum of bid groups");
    }

    function _checkGroup(
        TickTockHook hook,
        PoolId poolId,
        TickTockState.Level memory l,
        uint64 groupId,
        int24 sellLevel,
        uint8 k,
        bool isBid
    ) internal view returns (uint256) {
        TickTockState.Group memory g = hook.getGroup(groupId);
        assertEq(g.mergedInto, 0, "a slot holds a live group");
        assertGt(g.totalShares, 0, "a slot's group has shares");
        assertEq(PoolId.unwrap(g.poolId), PoolId.unwrap(poolId), "group pool");
        assertEq(g.sellLevel, sellLevel, "group strategy");
        assertEq(g.spreadIndex, k, "group spread");
        assertEq(g.isBid, isBid, "group side");
        // A fee snapshot from another level would show as a huge wrapped difference.
        unchecked {
            assertLt(l.feeGrowth0X128 - g.feeGrowthLast0X128, 2 ** 200, "fee snapshot 0 belongs to this level");
            assertLt(l.feeGrowth1X128 - g.feeGrowthLast1X128, 2 ** 200, "fee snapshot 1 belongs to this level");
        }
        return g.liquidity;
    }

    /// The hook's claims cover every group's pending tokens, per currency, across the pools that share them.
    function invariant_claimsCoverPending() public view {
        for (uint256 h = 0; h < handler.hookCount(); ++h) {
            TickTockHook hook = handler.hookAt(h);
            uint256 pending0;
            uint256 pending1;
            for (uint64 id = 1; id <= hook.lastGroupId(); ++id) {
                TickTockState.Group memory g = hook.getGroup(id);
                pending0 += g.pending0;
                pending1 += g.pending1;
            }
            // Every pool in the suite trades currency0 against currency1.
            assertGe(manager.balanceOf(address(hook), currency0.toId()), pending0, "claims0 >= pending0");
            assertGe(manager.balanceOf(address(hook), currency1.toId()), pending1, "claims1 >= pending1");
            assertEq(Currency.unwrap(currency0).code.length > 0, true);
        }
    }

    /// Absorbed groups point straight at a live group, and live groups' holders never own more than their shares.
    function invariant_mergesStayOneHop() public view {
        address[] memory actors = handler.actors();
        for (uint256 h = 0; h < handler.hookCount(); ++h) {
            TickTockHook hook = handler.hookAt(h);
            for (uint64 id = 1; id <= hook.lastGroupId(); ++id) {
                TickTockState.Group memory g = hook.getGroup(id);
                if (g.mergedInto != 0) {
                    assertLt(g.mergedInto, id, "the older group survives");
                    assertEq(hook.getGroup(g.mergedInto).mergedInto, 0, "one hop");
                    assertEq(g.liquidity + g.pending0 + g.pending1, 0, "absorbed groups hold nothing");
                }
                uint256 owned;
                for (uint256 a = 0; a < actors.length; ++a) {
                    owned += hook.sharesOf(actors[a], id);
                }
                assertLe(owned, g.totalShares, "shares owned <= total shares");
            }
        }
    }

    /// `askCursor <= T <= bidCursor` (DESIGN.md section 5.3).
    function invariant_cursorsBracketThePrice() public view {
        for (uint256 p = 0; p < handler.poolCount(); ++p) {
            PoolKey memory key = handler.keyAt(p);
            (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(key.toId());
            if (sqrtPriceX96 == 0) continue;
            (int24 t,,) = OrderMath.crossings(sqrtPriceX96, tick);
            TickTockState.PoolState memory pool = TickTockHook(address(key.hooks)).getPool(key.toId());
            assertLe(pool.askCursor, t, "askCursor <= T");
            assertGe(pool.bidCursor, t, "bidCursor >= T");
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // At the end of each run
    // ---------------------------------------------------------------------------------------------------------------

    function afterInvariant() public {
        _withdrawEveryoneAndCheck();
    }
}
