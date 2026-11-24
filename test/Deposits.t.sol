// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {OrderMath} from "../src/libraries/OrderMath.sol";
import {TickTockHook} from "../src/TickTockHook.sol";
import {TickTockState} from "../src/base/TickTockState.sol";
import {TickTockTestBase} from "./utils/TickTockTestBase.sol";

contract DepositsTest is TickTockTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    TickTockHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public override {
        super.setUp();
        hook = _createHook(10, _spreads(10, 50, 100));
        poolKey = _key(hook, 3000);
        poolId = poolKey.toId();
        _fund(alice, hook);
        _fund(bob, hook);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Pool creation
    // ---------------------------------------------------------------------------------------------------------------

    function test_firstAskCreatesPoolAtItsLowerEdge() public {
        uint256 balanceBefore = _balance(currency0, alice);
        (uint64 groupId, uint256 shares) = _deposit(hook, poolKey, alice, 100, 0, true, 1e18);

        assertEq(_price(poolKey), _sqrt(100));
        uint256 liquidity = _askLiquidity(100, 1e18);
        assertEq(groupId, 1);
        assertEq(shares, liquidity, "first shares equal liquidity");
        assertEq(hook.sharesOf(alice, groupId), shares);
        assertEq(_positionLiquidity(hook, poolKey, 100), liquidity);

        TickTockState.Level memory level = hook.getLevel(poolId, 100);
        assertEq(level.askLiquidity, liquidity);
        assertEq(level.askMask, 1);
        assertEq(hook.slotGroup(poolId, 100, false, 0), groupId);

        TickTockState.PoolState memory pool = hook.getPool(poolId);
        assertEq(pool.askCursor, 100);
        assertEq(pool.bidCursor, 100);

        // Pays what v4 asks for the liquidity: at most the amount, and within a wei of it.
        uint256 paid = balanceBefore - _balance(currency0, alice);
        (uint160 lower, uint160 upper) = OrderMath.bounds(100);
        assertEq(paid, OrderMath.amount0ForLiquidity(lower, upper, uint128(liquidity), true));
        assertLe(paid, 1e18);
        assertApproxEqAbs(paid, 1e18, 1);
    }

    function test_firstBidCreatesPoolAtItsUpperEdge() public {
        uint256 balanceBefore = _balance(currency1, alice);
        // Strategy (S = 100, spread 50): the bid sits at 50.
        (uint64 groupId,) = _deposit(hook, poolKey, alice, 100, 1, false, 1e18);

        assertEq(_price(poolKey), _sqrt(51));
        assertEq(hook.getLevel(poolId, 50).bidLiquidity, _bidLiquidity(50, 1e18));
        assertEq(hook.getLevel(poolId, 50).bidMask, 2);
        assertEq(hook.slotGroup(poolId, 50, true, 1), groupId);
        assertApproxEqAbs(balanceBefore - _balance(currency1, alice), 1e18, 1);

        TickTockState.Group memory g = hook.getGroup(groupId);
        assertEq(g.sellLevel, 100);
        assertEq(g.spreadIndex, 1);
        assertTrue(g.isBid);
    }

    function test_depositsIntoTheSameSlotShareAGroup() public {
        (uint64 aliceGroup, uint256 aliceShares) = _deposit(hook, poolKey, alice, 100, 0, true, 1e18);
        (uint64 bobGroup, uint256 bobShares) = _deposit(hook, poolKey, bob, 100, 0, true, 3e18);

        assertEq(bobGroup, aliceGroup);
        assertEq(bobShares, _askLiquidity(100, 3e18));
        assertApproxEqRel(bobShares, 3 * aliceShares, 1e9);
        assertEq(hook.getGroup(aliceGroup).totalShares, aliceShares + bobShares);
    }

    function test_differentSlotsGetDifferentGroups() public {
        (uint64 a,) = _deposit(hook, poolKey, alice, 100, 0, true, 1e18);
        (uint64 b,) = _deposit(hook, poolKey, alice, 100, 1, true, 1e18); // same level, other spread
        (uint64 c,) = _deposit(hook, poolKey, alice, 200, 0, true, 1e18); // other level
        assertEq(a, 1);
        assertEq(b, 2);
        assertEq(c, 3);
        assertEq(hook.getLevel(poolId, 100).askMask, 3);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Price moves
    // ---------------------------------------------------------------------------------------------------------------

    function test_askBelowThePriceMovesItDownForFree() public {
        _deposit(hook, poolKey, alice, 100, 0, true, 1e18);
        uint256 balanceBefore = _balance(currency0, bob);
        _deposit(hook, poolKey, bob, 50, 0, true, 1e18);

        assertEq(_price(poolKey), _sqrt(50));
        assertEq(hook.getPool(poolId).askCursor, 50);
        assertEq(hook.getPool(poolId).bidCursor, 100);
        assertApproxEqAbs(balanceBefore - _balance(currency0, bob), 1e18, 1, "only the order is paid");
    }

    function test_bidAboveThePriceMovesItUpForFree() public {
        _deposit(hook, poolKey, alice, 10, 0, false, 1e18); // bid at 0, price at sqrtPrice(1)
        _deposit(hook, poolKey, bob, 60, 0, false, 1e18); // bid at 50

        assertEq(_price(poolKey), _sqrt(51));
        assertEq(hook.getPool(poolId).bidCursor, 51);
        assertEq(hook.getPool(poolId).askCursor, 1);
    }

    function test_ordersInTheWay() public {
        _deposit(hook, poolKey, alice, 100, 0, true, 1e18); // ask at 100, price at its lower edge
        // A bid at 150 needs the price above 151, through the ask.
        vm.expectRevert(TickTockState.OrdersInTheWay.selector);
        _deposit(hook, poolKey, bob, 160, 0, false, 1e18);
    }

    function test_levelInRange() public {
        _deposit(hook, poolKey, alice, 100, 0, true, 1e18);
        (uint160 lower, uint160 upper) = OrderMath.bounds(100);
        _swapTo(poolKey, lower + (upper - lower) / 2);

        vm.expectRevert(TickTockState.LevelInRange.selector);
        _deposit(hook, poolKey, bob, 100, 0, true, 1e18);
    }

    /// One wei can be enough to push the price through a dust order. The nudge must then refuse, rather than trade
    /// the dust and leave it crossed without a flip.
    function test_nudgeThatWouldTradeDustIsRefused() public {
        poolKey = _key(hook, 0); // no fee, so the whole wei moves the price
        int24 dust = -199_990;
        _deposit(hook, poolKey, alice, dust, 0, true, 2); // 2 wei of token0
        (uint160 lower, uint160 upper) = OrderMath.bounds(dust);
        uint128 liquidity = hook.getLevel(poolKey.toId(), dust).askLiquidity;
        assertGt(liquidity, 0);
        assertEq(OrderMath.amount1ForLiquidity(lower, upper, liquidity, true), 1, "1 wei crosses the dust");

        // A bid at the same level needs the price at the dust's upper edge.
        vm.expectRevert(TickTockState.OrdersInTheWay.selector);
        _deposit(hook, poolKey, bob, dust + 10, 0, false, 1e18);
    }

    function test_movePriceThroughEmptySpace() public {
        _deposit(hook, poolKey, alice, 100, 0, true, 1e18);
        hook.movePrice(poolKey, _sqrt(-500));
        assertEq(_price(poolKey), _sqrt(-500));
        assertEq(hook.getPool(poolId).askCursor, -500);

        vm.expectRevert(TickTockState.OrdersInTheWay.selector);
        hook.movePrice(poolKey, _sqrt(200));

        // Moving to the current price does nothing.
        hook.movePrice(poolKey, _sqrt(-500));
    }

    function test_movePriceUnknownPool() public {
        vm.expectRevert(TickTockState.PoolNotFound.selector);
        hook.movePrice(poolKey, _sqrt(0));
    }

    /// A price pushed far into empty space can be walked back in chunks, and the pool works again.
    function test_farPriceIsWalkedBackInChunks() public {
        _deposit(hook, poolKey, alice, 100, 0, true, 1e18);
        // Anyone can push the price through empty space with a regular swap.
        swapRouter.swap(poolKey, IPoolManager.SwapParams(true, -1, _sqrt(-800_000)), _settings(), "");
        assertEq(_price(poolKey), _sqrt(-800_000));

        for (int24 target = -600_000; target <= 0; target += 200_000) {
            hook.movePrice(poolKey, _sqrt(target));
        }
        assertEq(_price(poolKey), _sqrt(0));
        _deposit(hook, poolKey, bob, 80, 0, false, 1e18); // bid at 70, nudged from 0
        assertEq(_price(poolKey), _sqrt(71));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Native ETH
    // ---------------------------------------------------------------------------------------------------------------

    function test_nativeEthAskRefundsTheExcess() public {
        PoolKey memory ethKey = PoolKey(CurrencyLibrary.ADDRESS_ZERO, currency1, 3000, 1, IHooks(address(hook)));
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        hook.deposit{value: 2e18}(ethKey, 100, 0, true, 1e18, 0, alice, block.timestamp);

        assertApproxEqAbs(balanceBefore - alice.balance, 1e18, 1, "pays the order, refunds the rest");
        assertEq(address(hook).balance, 0);
        assertEq(hook.getLevel(ethKey.toId(), 100).askLiquidity, _askLiquidity(100, 1e18));
    }

    function test_nativeEthInsufficientValue() public {
        PoolKey memory ethKey = PoolKey(CurrencyLibrary.ADDRESS_ZERO, currency1, 3000, 1, IHooks(address(hook)));
        vm.prank(alice);
        vm.expectRevert(TickTockState.InsufficientValue.selector);
        hook.deposit{value: 1e17}(ethKey, 100, 0, true, 1e18, 0, alice, block.timestamp);
    }

    function test_ethSentForAnErc20IsRefused() public {
        vm.prank(alice);
        vm.expectRevert(TickTockState.UnexpectedValue.selector);
        hook.deposit{value: 1}(poolKey, 100, 0, true, 1e18, 0, alice, block.timestamp);

        PoolKey memory ethKey = PoolKey(CurrencyLibrary.ADDRESS_ZERO, currency1, 3000, 1, IHooks(address(hook)));
        vm.prank(alice);
        vm.expectRevert(TickTockState.UnexpectedValue.selector);
        hook.deposit{value: 1}(ethKey, 100, 0, false, 1e18, 0, alice, block.timestamp); // a bid pays token1
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Refusals
    // ---------------------------------------------------------------------------------------------------------------

    function test_minShares() public {
        uint256 liquidity = _askLiquidity(100, 1e18);
        vm.prank(alice);
        vm.expectRevert(TickTockState.InsufficientShares.selector);
        hook.deposit(poolKey, 100, 0, true, 1e18, liquidity + 1, alice, block.timestamp);

        vm.prank(alice);
        hook.deposit(poolKey, 100, 0, true, 1e18, liquidity, alice, block.timestamp);
    }

    function test_deadline() public {
        vm.warp(1000);
        vm.prank(alice);
        vm.expectRevert(TickTockState.DeadlinePassed.selector);
        hook.deposit(poolKey, 100, 0, true, 1e18, 0, alice, 999);
    }

    function test_invalidPoolKeys() public {
        TickTockHook other = _createHook(10, _spreads(20));
        _expectDepositRevert(_key(other, 3000), 100, 0, 1e18, TickTockState.InvalidPoolKey.selector);

        PoolKey memory wideSpacing = poolKey;
        wideSpacing.tickSpacing = 2;
        _expectDepositRevert(wideSpacing, 100, 0, 1e18, TickTockState.InvalidPoolKey.selector);

        PoolKey memory dynamicFee = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        _expectDepositRevert(dynamicFee, 100, 0, 1e18, TickTockState.DynamicFeeNotSupported.selector);
    }

    function test_invalidStrategies() public {
        _expectDepositRevert(poolKey, 100, 3, 1e18, TickTockState.InvalidSpreadIndex.selector);
        _expectDepositRevert(poolKey, 105, 0, 1e18, TickTockState.LevelNotOnGrid.selector);
        // The bid level would be below MIN_TICK.
        _expectDepositRevert(poolKey, -887_270, 0, 1e18, TickTockState.StrategyOutOfBounds.selector);
        // The ask level's range would end above MAX_TICK.
        _expectDepositRevert(poolKey, 887_280, 0, 1e18, TickTockState.StrategyOutOfBounds.selector);
    }

    function test_invalidAmountsAndRecipient() public {
        _expectDepositRevert(poolKey, 100, 0, 0, TickTockState.ZeroAmount.selector);
        // At a very low price, 1 wei of token0 buys no liquidity.
        _expectDepositRevert(poolKey, -880_000, 0, 1, TickTockState.ZeroLiquidity.selector);

        vm.prank(alice);
        vm.expectRevert(TickTockState.InvalidRecipient.selector);
        hook.deposit(poolKey, 100, 0, true, 1e18, 0, address(0), block.timestamp);
    }

    function _expectDepositRevert(PoolKey memory k, int24 sellLevel, uint8 spreadIndex, uint128 amount, bytes4 err)
        internal
    {
        vm.prank(alice);
        vm.expectRevert(err);
        hook.deposit(k, sellLevel, spreadIndex, true, amount, 0, alice, block.timestamp);
    }

    function _settings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }
}
