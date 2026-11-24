// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {TickTockFactory} from "../src/TickTockFactory.sol";
import {HookSaltMiner} from "./HookSaltMiner.sol";

/// @notice Finds a salt for `TickTockFactory.createHook`.
/// @dev Usage:
///   FACTORY=0x... LEVEL_SPACING=10 SPREADS=10,50,100 forge script script/MineSalt.s.sol --rpc-url $RPC_URL
/// Optional: SALT_START (default 0) and SALT_TRIES (default 1,000,000).
contract MineSalt is Script {
    function run() external view returns (bytes32 salt, address hook) {
        TickTockFactory factory = TickTockFactory(vm.envAddress("FACTORY"));
        uint24 levelSpacing = uint24(vm.envUint("LEVEL_SPACING"));
        int256[] memory raw = vm.envInt("SPREADS", ",");
        int24[] memory spreads = new int24[](raw.length);
        for (uint256 i = 0; i < raw.length; ++i) {
            spreads[i] = int24(raw[i]);
        }

        bytes32 initCodeHash = factory.hookInitCodeHash(levelSpacing, spreads);
        (salt, hook) = HookSaltMiner.find(
            address(factory),
            initCodeHash,
            factory.HOOK_FLAGS(),
            vm.envOr("SALT_START", uint256(0)),
            vm.envOr("SALT_TRIES", uint256(1_000_000))
        );
        console.log("hook address:", hook);
        console.log("salt:");
        console.logBytes32(salt);
    }
}
