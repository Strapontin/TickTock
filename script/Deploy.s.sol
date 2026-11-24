// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickTockFactory} from "../src/TickTockFactory.sol";
import {HookSaltMiner} from "./HookSaltMiner.sol";
import {UniswapAddresses} from "./UniswapAddresses.sol";

/// @notice Deploys a TickTock factory (with its hook implementation and engine), then optionally a first config's
/// hook.
/// @dev Usage:
///   MAX_OPS_PER_SWAP=24 forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --account <keystore>
/// The PoolManager comes from `UniswapAddresses` on the chains it lists; set POOL_MANAGER=0x... on any other. To also
/// create a config's hook, add LEVEL_SPACING=10 SPREADS=10,50,100. To use an existing factory instead of deploying
/// one, set FACTORY=0x.... See README.md for the per-chain MAX_OPS_PER_SWAP.
contract Deploy is Script {
    function run() external returns (TickTockFactory factory, address hook) {
        address existing = vm.envOr("FACTORY", address(0));

        vm.startBroadcast();
        if (existing == address(0)) {
            factory = new TickTockFactory(IPoolManager(poolManager()), uint16(vm.envUint("MAX_OPS_PER_SWAP")));
            console.log("factory:", address(factory));
            console.log("implementation:", factory.implementation());
        } else {
            factory = TickTockFactory(existing);
        }

        uint24 levelSpacing = uint24(vm.envOr("LEVEL_SPACING", uint256(0)));
        if (levelSpacing != 0) {
            int256[] memory raw = vm.envInt("SPREADS", ",");
            int24[] memory spreads = new int24[](raw.length);
            for (uint256 i = 0; i < raw.length; ++i) {
                spreads[i] = int24(raw[i]);
            }
            (bytes32 salt,) = HookSaltMiner.find(
                address(factory),
                factory.hookInitCodeHash(levelSpacing, spreads),
                factory.HOOK_FLAGS(),
                vm.envOr("SALT_START", uint256(0)),
                vm.envOr("SALT_TRIES", uint256(1_000_000))
            );
            hook = factory.createHook(levelSpacing, spreads, salt);
            console.log("hook:", hook);
        }
        vm.stopBroadcast();
    }

    /// POOL_MANAGER if set, else Uniswap's deployment on this chain.
    function poolManager() public view returns (address) {
        address fromEnv = vm.envOr("POOL_MANAGER", address(0));
        if (fromEnv != address(0)) return fromEnv;
        return UniswapAddresses.forChain(block.chainid).poolManager;
    }
}
