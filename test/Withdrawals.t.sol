// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {OrderMath} from "../src/libraries/OrderMath.sol";
import {TickTockHook} from "../src/TickTockHook.sol";
import {TickTockState} from "../src/base/TickTockState.sol";
import {TickTockTestBase} from "./utils/TickTockTestBase.sol";

contract WithdrawalsTest is TickTockTestBase {
    using PoolIdLibrary for PoolKey;

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

    function test_withdrawAllOutOfRange() public {
        (uint64 groupId,) = _deposit(hook, poolKey, alice, 100, 0, true, 1e18);
        uint256 balanceBefore = _balance(currency0, alice);
        (uint256 amount0, uint256 amount1) = _withdrawAll(hook, alice, groupId);

        assertApproxEqAbs(amount0, 1e18, 2, "the order comes back, minus rounding");
        assertLe(amount0, 1e18);
        assertEq(amount1, 0);
        assertEq(_balance(currency0, alice) - balanceBefore, amount0);

        // The slot is empty again, and nothing is left in the pool.
        assertEq(hook.sharesOf(alice, groupId), 0);
        assertEq(hook.getGroup(groupId).totalShares, 0);
        assertEq(hook.getGroup(groupId).liquidity, 0);
        assertEq(hook.slotGroup(poolId, 100, false, 0), 0);
        assertEq(hook.getLevel(poolId, 100).askMask, 0);
        assertEq(hook.getLevel(poolId, 100).askLiquidity, 0);
        assertEq(_positionLiquidity(hook, poolKey, 100), 0);
    }

    function test_partialWithdrawalIsProportional() public {
        (uint64 groupId, uint256 shares) = _deposit(hook, poolKey, alice, 100, 0, true, 1e18);
        vm.prank(alice);
        (uint256 amount0,) = hook.withdraw(groupId, shares / 4, alice, block.timestamp);

        assertApproxEqAbs(amount0, 0.25e18, 2);
        assertEq(hook.sharesOf(alice, groupId), shares - shares / 4);
        assertEq(hook.getGroup(groupId).liquidity, shares - shares / 4);
        assertEq(hook.slotGroup(poolId, 100, false, 0), groupId, "the slot keeps its group");
    }

    function test_twoUsersGetTheirShares() public {
        (uint64 groupId,) = _deposit(hook, poolKey, alice, 100, 0, true, 1e18);
        _deposit(hook, poolKey, bob, 100, 0, true, 3e18);

        (uint256 bobAmount,) = _withdrawAll(hook, bob, groupId);
        (uint256 aliceAmount,) = _withdrawAll(hook, alice, groupId);
        assertApproxEqAbs(bobAmount, 3e18, 3);
        assertApproxEqAbs(aliceAmount, 1e18, 3);
        assertEq(_positionLiquidity(hook, poolKey, 100), 0);
    }

    /// With the price inside the level, the user gets both tokens, exactly as `positionOf` said.
    function test_withdrawInRange() public {
        (uint64 groupId,) = _deposit(hook, poolKey, alice, 100, 0, true, 1e18);
        (uint160 lower, uint160 upper) = OrderMath.bounds(100);
        _swapTo(poolKey, lower + (upper - lower) / 3);

        (uint256 expected0, uint256 expected1) = hook.positionOf(alice, groupId);
        (uint256 amount0, uint256 amount1) = _withdrawAll(hook, alice, groupId);
        assertGt(amount0, 0);
        assertGt(amount1, 0);
        assertEq(amount0, expected0);
        assertEq(amount1, expected1);
    }

    /// After a swap crosses the ask and flips it into a bid, the user gets the token it converted into.
    function test_withdrawAfterAFlip() public {
        (uint64 groupId,) = _deposit(hook, poolKey, alice, 100, 0, true, 1e18);
        _swapToTick(poolKey, 101);

        (uint256 amount0, uint256 amount1) = _withdrawAll(hook, alice, groupId);
        // Sold at the level's fill price, about 1.0001^100.5, plus the fee the swap paid.
        assertLe(amount0, 1);
        uint256 atFillPrice = 1e18 * 10_101 / 10_000; // 1.0001^100.5 ≈ 1.01010
        assertApproxEqRel(amount1, atFillPrice * 1_003 / 1_000, 1e15);
    }

    function test_freedSlotGetsANewGroup() public {
        (uint64 first,) = _deposit(hook, poolKey, alice, 100, 0, true, 1e18);
        _withdrawAll(hook, alice, first);
        (uint64 second,) = _deposit(hook, poolKey, bob, 100, 0, true, 1e18);
        assertEq(second, first + 1);
        assertEq(hook.getGroup(second).totalShares, _askLiquidity(100, 1e18));
    }

    function test_withdrawToAnotherRecipient() public {
        (uint64 groupId, uint256 shares) = _deposit(hook, poolKey, alice, 100, 0, true, 1e18);
        vm.prank(alice);
        (uint256 amount0,) = hook.withdraw(groupId, shares, carol, block.timestamp);
        assertEq(_balance(currency0, carol), amount0);
    }

    function test_nativeEthWithdrawal() public {
        PoolKey memory ethKey = PoolKey(CurrencyLibrary.ADDRESS_ZERO, currency1, 3000, 1, IHooks(address(hook)));
        vm.prank(alice);
        (uint64 groupId,) = hook.deposit{value: 1e18}(ethKey, 100, 0, true, 1e18, 0, alice, block.timestamp);

        uint256 balanceBefore = alice.balance;
        (uint256 amount0,) = _withdrawAll(hook, alice, groupId);
        assertApproxEqAbs(amount0, 1e18, 2);
        assertEq(alice.balance - balanceBefore, amount0);
    }

    /// At any price, a deposit and a withdrawal lose at most one wei to rounding, and never gain.
    function testFuzz_depositWithdrawRoundTrip(int24 sellSeed, uint8 spreadIndex, bool startWithToken0, uint128 amount)
        public
    {
        spreadIndex = uint8(bound(spreadIndex, 0, 2));
        int24 sellLevel = int24(bound(sellSeed, -887_000, 887_000)) / 10 * 10;
        amount = uint128(bound(amount, 1, 1e27));
        Currency payCurrency = startWithToken0 ? currency0 : currency1;
        uint256 balanceBefore = _balance(payCurrency, alice);

        vm.prank(alice);
        try hook.deposit(poolKey, sellLevel, spreadIndex, startWithToken0, amount, 0, alice, block.timestamp) returns (
            uint64 groupId, uint256
        ) {
            uint256 paid = balanceBefore - _balance(payCurrency, alice);
            assertLe(paid, amount);
            (uint256 amount0, uint256 amount1) = _withdrawAll(hook, alice, groupId);
            uint256 back = startWithToken0 ? amount0 : amount1;
            assertEq(startWithToken0 ? amount1 : amount0, 0);
            assertLe(back, paid);
            assertGe(back + 1, paid);
        } catch (bytes memory reason) {
            // Too small to buy liquidity at that price, or too much for one tick.
            bytes4 selector = bytes4(reason);
            assertTrue(
                selector == TickTockState.ZeroLiquidity.selector || selector == TickTockState.TooMuchLiquidity.selector
                    || selector == Pool.TickLiquidityOverflow.selector,
                "unexpected revert"
            );
        }
    }

    function test_refusals() public {
        (uint64 groupId, uint256 shares) = _deposit(hook, poolKey, alice, 100, 0, true, 1e18);

        vm.startPrank(alice);
        vm.expectRevert(TickTockState.InsufficientShares.selector);
        hook.withdraw(groupId, shares + 1, alice, block.timestamp);
        vm.expectRevert(TickTockState.ZeroShares.selector);
        hook.withdraw(groupId, 0, alice, block.timestamp);
        vm.expectRevert(TickTockState.InvalidRecipient.selector);
        hook.withdraw(groupId, shares, address(0), block.timestamp);
        vm.expectRevert(TickTockState.DeadlinePassed.selector);
        hook.withdraw(groupId, shares, alice, block.timestamp - 1);
        vm.stopPrank();

        // Someone else's shares.
        vm.prank(bob);
        vm.expectRevert(TickTockState.InsufficientShares.selector);
        hook.withdraw(groupId, 1, bob, block.timestamp);
    }
}
