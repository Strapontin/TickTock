// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookConfig} from "../src/libraries/HookConfig.sol";
import {TickTockFactory} from "../src/TickTockFactory.sol";
import {TickTockHook} from "../src/TickTockHook.sol";
import {TickTockTestBase} from "./utils/TickTockTestBase.sol";

contract TickTockFactoryTest is TickTockTestBase {
    function test_constructor_refusesLowBudget() public {
        vm.expectRevert(abi.encodeWithSelector(TickTockFactory.MaxOpsPerSwapTooLow.selector, uint16(8)));
        new TickTockFactory(manager, 8);
    }

    function test_constructor_deploysImplementation() public view {
        TickTockHook implementation = TickTockHook(factory.implementation());
        assertGt(address(implementation).code.length, 0);
        assertEq(address(implementation.poolManager()), address(manager));
        assertEq(implementation.maxOpsPerSwap(), MAX_OPS);
        assertEq(factory.maxOpsPerSwap(), MAX_OPS);
    }

    function test_createHook() public {
        int24[] memory spreads = _spreads(10, 50, 100);
        (bytes32 salt, address predicted) = _mineSalt(10, spreads, 0);
        assertEq(factory.predictHookAddress(10, spreads, salt), predicted);

        vm.expectEmit(address(factory));
        emit TickTockFactory.HookCreated(factory.configHash(10, spreads), predicted, 10, spreads);
        address hook = factory.createHook(10, spreads, salt);

        assertEq(hook, predicted);
        assertEq(uint160(hook) & Hooks.ALL_HOOK_MASK, HookConfig.HOOK_FLAGS);
        assertEq(factory.hookOf(factory.configHash(10, spreads)), hook);

        // The clone shares the implementation's immutables and reads its own config.
        assertEq(address(TickTockHook(hook).poolManager()), address(manager));
        assertEq(TickTockHook(hook).maxOpsPerSwap(), MAX_OPS);
        (uint24 levelSpacing, int24[] memory readSpreads) = TickTockHook(hook).config();
        assertEq(levelSpacing, 10);
        assertEq(readSpreads.length, 3);
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(readSpreads[i], spreads[i]);
        }
    }

    function test_createHook_fullMenuAndExtremes() public {
        int24[] memory spreads = new int24[](8);
        for (uint256 i = 0; i < 8; ++i) {
            spreads[i] = int24(int256(i + 1)) * 3;
        }
        // The widest spread on the grid of 3.
        spreads[7] = HookConfig.MAX_SPREAD - HookConfig.MAX_SPREAD % 3;
        TickTockHook hook = _createHook(3, spreads);

        (uint24 levelSpacing, int24[] memory readSpreads) = hook.config();
        assertEq(levelSpacing, 3);
        assertEq(readSpreads.length, 8);
        for (uint256 i = 0; i < 8; ++i) {
            assertEq(readSpreads[i], spreads[i]);
        }
    }

    function test_createHook_differentConfigsGetDifferentHooks() public {
        TickTockHook a = _createHook(10, _spreads(10));
        TickTockHook b = _createHook(10, _spreads(20));
        TickTockHook c = _createHook(5, _spreads(10));
        assertTrue(address(a) != address(b) && address(b) != address(c) && address(a) != address(c));
    }

    function test_createHook_refusesDuplicate() public {
        int24[] memory spreads = _spreads(10, 50);
        (bytes32 salt, address hook) = _mineSalt(10, spreads, 0);
        factory.createHook(10, spreads, salt);

        // The same config with another valid salt.
        (bytes32 otherSalt,) = _mineSalt(10, spreads, uint256(salt) + 1);
        vm.expectRevert(abi.encodeWithSelector(TickTockFactory.ConfigExists.selector, hook));
        factory.createHook(10, spreads, otherSalt);

        // The same salt again, as a front-runner would.
        vm.expectRevert(abi.encodeWithSelector(TickTockFactory.ConfigExists.selector, hook));
        factory.createHook(10, spreads, salt);
    }

    function test_createHook_refusesWrongSalt() public {
        int24[] memory spreads = _spreads(10);
        bytes32 salt;
        address predicted;
        for (uint256 i = 0;; ++i) {
            salt = bytes32(i);
            predicted = factory.predictHookAddress(10, spreads, salt);
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK != HookConfig.HOOK_FLAGS) break;
        }
        vm.expectRevert(abi.encodeWithSelector(TickTockFactory.InvalidHookAddress.selector, predicted));
        factory.createHook(10, spreads, salt);
    }

    function test_createHook_refusesInvalidLevelSpacing() public {
        vm.expectRevert(abi.encodeWithSelector(HookConfig.InvalidLevelSpacing.selector, uint24(0)));
        factory.createHook(0, _spreads(10), 0);

        uint24 tooWide = HookConfig.MAX_LEVEL_SPACING + 1;
        vm.expectRevert(abi.encodeWithSelector(HookConfig.InvalidLevelSpacing.selector, tooWide));
        factory.createHook(tooWide, _spreads(10), 0);
    }

    function test_createHook_refusesInvalidSpreadCount() public {
        vm.expectRevert(abi.encodeWithSelector(HookConfig.InvalidSpreadCount.selector, uint256(0)));
        factory.createHook(10, new int24[](0), 0);

        int24[] memory nine = new int24[](9);
        for (uint256 i = 0; i < 9; ++i) {
            nine[i] = int24(int256(i + 1)) * 10;
        }
        vm.expectRevert(abi.encodeWithSelector(HookConfig.InvalidSpreadCount.selector, uint256(9)));
        factory.createHook(10, nine, 0);
    }

    function test_createHook_refusesInvalidSpreads() public {
        _expectInvalidSpread(10, _spreads(0), 0, 0);
        _expectInvalidSpread(10, _spreads(-10), 0, -10);
        _expectInvalidSpread(10, _spreads(15), 0, 15);
        _expectInvalidSpread(10, _spreads(10, 10), 1, 10);
        _expectInvalidSpread(10, _spreads(20, 10), 1, 10);
        _expectInvalidSpread(1, _spreads(HookConfig.MAX_SPREAD + 1), 0, HookConfig.MAX_SPREAD + 1);
    }

    function test_views_validateTheConfig() public {
        vm.expectRevert(abi.encodeWithSelector(HookConfig.InvalidSpread.selector, uint256(0), int24(15)));
        factory.predictHookAddress(10, _spreads(15), 0);
        vm.expectRevert(abi.encodeWithSelector(HookConfig.InvalidSpread.selector, uint256(0), int24(15)));
        factory.hookInitCodeHash(10, _spreads(15));
    }

    function _expectInvalidSpread(uint24 levelSpacing, int24[] memory spreads, uint256 index, int24 spread) internal {
        vm.expectRevert(abi.encodeWithSelector(HookConfig.InvalidSpread.selector, index, spread));
        factory.createHook(levelSpacing, spreads, 0);
    }
}
