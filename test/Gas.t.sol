// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {OrderMath} from "../src/libraries/OrderMath.sol";
import {TickTockHook} from "../src/TickTockHook.sol";
import {TickTockTestBase} from "./utils/TickTockTestBase.sol";

/// @notice Gas of the main operations, recorded in `snapshots/TickTock.json`. Each test builds its order book, then
/// measures one call. The config has the full menu of 8 spreads (10 to 80 ticks) and the factory's budget is 24
/// operations. Numbers use the test PoolManager, compiled with 200 optimizer runs instead of the deployed 44,444,444,
/// so v4's share is a little higher than on mainnet.
contract GasTest is TickTockTestBase {
    string internal constant GROUP = "TickTock";

    TickTockHook internal hook;
    PoolKey internal poolKey;

    function setUp() public override {
        super.setUp();
        int24[] memory spreads = new int24[](8);
        for (uint256 i = 0; i < 8; ++i) {
            spreads[i] = int24(int256(10 * (i + 1)));
        }
        hook = _createHook(10, spreads);
        poolKey = _key(hook, 3000);
        _fund(alice, hook);
        _fund(bob, hook);

        // Warm the pool as a live one would be: it exists, the hook holds claims, fee growth is non-zero.
        _deposit(hook, poolKey, alice, 5000, 0, true, 1e18);
        _swapToTick(poolKey, 5001);
        _swapToTick(poolKey, 4990);
        hook.movePrice(poolKey, _sqrt(0));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Swaps
    // ---------------------------------------------------------------------------------------------------------------

    function test_swap_crossesNoLevel() public {
        _deposit(hook, poolKey, alice, 100, 0, true, 1e18);
        _swapToTick(poolKey, 50);
        vm.snapshotGasLastCall(GROUP, "swap: crosses no level");
    }

    function test_swap_stopsInsideALevel() public {
        _deposit(hook, poolKey, alice, 100, 0, true, 1e18);
        (uint160 lower, uint160 upper) = OrderMath.bounds(100);
        _swapTo(poolKey, lower + (upper - lower) / 2);
        vm.snapshotGasLastCall(GROUP, "swap: stops inside a level");
    }

    function test_swap_flipsOneSpread() public {
        _deposit(hook, poolKey, alice, 100, 0, true, 1e18);
        _swapToTick(poolKey, 101);
        vm.snapshotGasLastCall(GROUP, "swap: flips 1 level, 1 spread (2 ops)");
    }

    function test_swap_flipsEightSpreads() public {
        _eightAsksAt(100);
        _swapToTick(poolKey, 101);
        vm.snapshotGasLastCall(GROUP, "swap: flips 1 level, 8 spreads (9 ops)");
    }

    /// The busiest level: every ask slot full, and every destination already holding a group to merge with.
    function test_swap_flipsEightSpreadsWithMerges() public {
        _eightBidsBelow(100);
        _eightAsksAt(100);
        _swapToTick(poolKey, 101);
        vm.snapshotGasLastCall(GROUP, "swap: flips 1 level, 8 spreads, 8 merges (9 ops)");
    }

    function test_swap_budgetOnOneSpreadLevels() public {
        for (int24 level = 100; level < 230; level += 10) {
            _deposit(hook, poolKey, alice, level, 0, true, 1e18);
        }
        _swapToTick(poolKey, 300);
        vm.snapshotGasLastCall(GROUP, "swap: budget spent on 1-spread levels (12 levels, 24 ops)");
    }

    /// The worst case per swap: the budget spent on 8-spread levels, each flipping into 8 fresh destinations (fresh
    /// destinations cost more than merges: v4 initializes their ticks and positions). Two fit in 24 operations.
    function test_swap_budgetOnBusiestLevels() public {
        _eightAsksAt(200);
        _eightAsksAt(300);
        _swapToTick(poolKey, 301);
        vm.snapshotGasLastCall(GROUP, "swap: budget spent on 8-spread levels (2 levels, 18 ops)");
    }

    /// A round trip back into a level its strategy used before.
    function test_swap_flipsBackIntoAUsedLevel() public {
        _deposit(hook, poolKey, alice, 100, 0, true, 1e18);
        _swapToTick(poolKey, 101); // to the bid at 90
        _swapToTick(poolKey, 90); // back to the ask at 100
        vm.snapshotGasLastCall(GROUP, "swap: flips 1 level back into a used level, 1 spread (2 ops)");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Users and keepers
    // ---------------------------------------------------------------------------------------------------------------

    function test_deposit_createsPool() public {
        _deposit(hook, _key(hook, 500), alice, 100, 0, true, 1e18);
        vm.snapshotGasLastCall(GROUP, "deposit: creates the pool");
    }

    function test_deposit_newGroup() public {
        _deposit(hook, poolKey, alice, 100, 0, true, 1e18);
        vm.snapshotGasLastCall(GROUP, "deposit: new group");
    }

    function test_deposit_existingGroup() public {
        _deposit(hook, poolKey, alice, 100, 0, true, 1e18);
        _deposit(hook, poolKey, bob, 100, 0, true, 1e18);
        vm.snapshotGasLastCall(GROUP, "deposit: existing group");
    }

    function test_withdraw_all() public {
        (uint64 groupId,) = _deposit(hook, poolKey, alice, 100, 0, true, 1e18);
        _withdrawAll(hook, alice, groupId);
        vm.snapshotGasLastCall(GROUP, "withdraw: all, out of range");
    }

    function test_flipLevel_partial() public {
        _deposit(hook, poolKey, alice, 100, 0, true, 1e18);
        (uint160 lower, uint160 upper) = OrderMath.bounds(100);
        _swapTo(poolKey, upper - (upper - lower) / 20);
        hook.flipLevel(poolKey, 100);
        vm.snapshotGasLastCall(GROUP, "flipLevel: 95% filled, 1 spread");
    }

    function test_flipCrossed_leftovers() public {
        for (int24 level = 100; level < 300; level += 10) {
            _deposit(hook, poolKey, alice, level, 0, true, 1e18);
        }
        _swapToTick(poolKey, 300);
        hook.flipCrossed(poolKey, 100);
        vm.snapshotGasLastCall(GROUP, "flipCrossed: 8 leftover levels, 1 spread");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _eightAsksAt(int24 level) internal {
        for (uint8 k = 0; k < 8; ++k) {
            _deposit(hook, poolKey, alice, level, k, true, 1e18);
        }
    }

    /// One bid per spread, in the bid slots of the strategies selling at `sellLevel`. Highest first, so each nudge
    /// moves the price up through empty space only.
    function _eightBidsBelow(int24 sellLevel) internal {
        for (uint8 k = 0; k < 8; ++k) {
            _deposit(hook, poolKey, bob, sellLevel, k, false, 1e18);
        }
    }
}
