// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickTockHook} from "../src/TickTockHook.sol";
import {TickTockTestBase} from "./utils/TickTockTestBase.sol";

/// @notice The hook skeleton: permissions, refused callbacks and access control.
contract TickTockHookSkeletonTest is TickTockTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    TickTockHook internal hook;
    PoolKey internal poolKey;

    function setUp() public override {
        super.setUp();
        hook = _createHook(10, _spreads(10, 50));
        poolKey = PoolKey(currency0, currency1, 3000, 1, IHooks(address(hook)));
    }

    function test_externalInitializeRefused() public {
        vm.expectRevert(
            _wrapped(
                IHooks.beforeInitialize.selector, abi.encodeWithSelector(TickTockHook.PoolCreationRestricted.selector)
            )
        );
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));
    }

    function test_outsideLiquidityRefused() public {
        _initializeAsHook();
        vm.expectRevert(
            _wrapped(
                IHooks.beforeAddLiquidity.selector, abi.encodeWithSelector(TickTockHook.LiquidityRestricted.selector)
            )
        );
        modifyLiquidityRouter.modifyLiquidity(poolKey, IPoolManager.ModifyLiquidityParams(0, 1, 1e18, 0), "");
    }

    function test_donationsRefused() public {
        _initializeAsHook();
        vm.expectRevert(
            _wrapped(IHooks.beforeDonate.selector, abi.encodeWithSelector(TickTockHook.DonationsBlocked.selector))
        );
        donateRouter.donate(poolKey, 1, 1, "");
    }

    /// A swap through an empty pool runs `afterSwap`, which accepts it.
    function test_swapReachesAfterSwap() public {
        _initializeAsHook();
        uint160 limit = TickMath.getSqrtPriceAtTick(-100);
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams(true, -1, limit),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolKey.toId());
        assertEq(sqrtPriceX96, limit);
    }

    function test_afterSwapOnlyFromPoolManager() public {
        vm.expectRevert(TickTockHook.NotPoolManager.selector);
        hook.afterSwap(address(this), poolKey, IPoolManager.SwapParams(true, -1, 0), BalanceDelta.wrap(0), "");
    }

    function test_implementationRefusesDirectCalls() public {
        TickTockHook implementation = TickTockHook(factory.implementation());
        vm.expectRevert(TickTockHook.NotAClone.selector);
        implementation.config();

        vm.prank(address(manager));
        vm.expectRevert(TickTockHook.NotAClone.selector);
        implementation.afterSwap(address(this), poolKey, IPoolManager.SwapParams(true, -1, 0), BalanceDelta.wrap(0), "");
    }

    function test_unusedCallbacksRevert() public {
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams(0, 1, 1, 0);
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams(true, -1, 0);
        BalanceDelta zero = BalanceDelta.wrap(0);

        vm.expectRevert(TickTockHook.HookNotImplemented.selector);
        hook.afterInitialize(address(this), poolKey, 0, 0);
        vm.expectRevert(TickTockHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(address(this), poolKey, params, zero, zero, "");
        vm.expectRevert(TickTockHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(this), poolKey, params, "");
        vm.expectRevert(TickTockHook.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(address(this), poolKey, params, zero, zero, "");
        vm.expectRevert(TickTockHook.HookNotImplemented.selector);
        hook.beforeSwap(address(this), poolKey, swapParams, "");
        vm.expectRevert(TickTockHook.HookNotImplemented.selector);
        hook.afterDonate(address(this), poolKey, 0, 0, "");
    }

    /// Stands in for the hook creating its pool on a first deposit (step 3): the hook's own call skips
    /// `beforeInitialize`.
    function _initializeAsHook() internal {
        vm.prank(address(hook));
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));
    }

    function _wrapped(bytes4 callback, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }
}
