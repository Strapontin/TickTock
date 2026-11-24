// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickTockFactory} from "../src/TickTockFactory.sol";
import {HookSaltMiner} from "./HookSaltMiner.sol";
import {UniswapAddresses} from "./UniswapAddresses.sol";

/// @notice What the deploy scripts share: finding the PoolManager, deploying a factory, and creating a config's hook
/// with a mined salt.
abstract contract DeployBase is Script {
    /// POOL_MANAGER if set, else Uniswap's deployment on this chain.
    function poolManager() public view returns (address) {
        address fromEnv = vm.envOr("POOL_MANAGER", address(0));
        if (fromEnv != address(0)) return fromEnv;
        return UniswapAddresses.forChain(block.chainid).poolManager;
    }

    /// Deploys a factory, which deploys the hook implementation and the engine. Call while broadcasting.
    function _deployFactory(uint16 maxOpsPerSwap) internal returns (TickTockFactory) {
        return new TickTockFactory(IPoolManager(poolManager()), maxOpsPerSwap);
    }

    /// Mines a salt for the config's hook address, then creates the hook. Call while broadcasting. SALT_START and
    /// SALT_TRIES bound the search.
    function _createHook(TickTockFactory factory, uint24 levelSpacing, int24[] memory spreads)
        internal
        returns (address)
    {
        (bytes32 salt,) = HookSaltMiner.find(
            address(factory),
            factory.hookInitCodeHash(levelSpacing, spreads),
            factory.HOOK_FLAGS(),
            vm.envOr("SALT_START", uint256(0)),
            vm.envOr("SALT_TRIES", uint256(1_000_000))
        );
        return factory.createHook(levelSpacing, spreads, salt);
    }
}
