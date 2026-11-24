// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deploy} from "../script/Deploy.s.sol";
import {UniswapAddresses} from "../script/UniswapAddresses.sol";
import {TickTockFactory} from "../src/TickTockFactory.sol";
import {TickTockHook} from "../src/TickTockHook.sol";
import {TickTockTestBase} from "./utils/TickTockTestBase.sol";

contract DeployTest is TickTockTestBase {
    function test_deploysFactoryAndHook() public {
        vm.setEnv("POOL_MANAGER", vm.toString(address(manager)));
        vm.setEnv("MAX_OPS_PER_SWAP", "24");
        vm.setEnv("LEVEL_SPACING", "10");
        vm.setEnv("SPREADS", "10,50,100");

        (TickTockFactory deployed, address hook) = new Deploy().run();

        assertEq(address(deployed.poolManager()), address(manager));
        assertEq(deployed.maxOpsPerSwap(), 24);
        assertEq(deployed.hookOf(deployed.configHash(10, _spreads(10, 50, 100))), hook);
        (uint24 levelSpacing, int24[] memory spreads) = TickTockHook(hook).config();
        assertEq(levelSpacing, 10);
        assertEq(spreads.length, 3);

        // The hook works: a deposit creates its pool.
        _fund(alice, TickTockHook(hook));
        _deposit(TickTockHook(hook), _key(TickTockHook(hook), 3000), alice, 100, 0, true, 1e18);
    }

    function test_poolManagerFromChain() public {
        vm.setEnv("POOL_MANAGER", vm.toString(address(0)));
        Deploy script = new Deploy();

        vm.chainId(UniswapAddresses.UNICHAIN);
        assertEq(script.poolManager(), 0x1F98400000000000000000000000000000000004);
        vm.chainId(UniswapAddresses.UNICHAIN_SEPOLIA);
        assertEq(script.poolManager(), 0x00B036B58a818B1BC34d502D3fE730Db729e62AC);

        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(UniswapAddresses.UnsupportedChain.selector, 1));
        script.poolManager();

        vm.setEnv("POOL_MANAGER", vm.toString(address(manager)));
        assertEq(script.poolManager(), address(manager), "the environment wins");
    }
}
