// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LibClone} from "solady/utils/LibClone.sol";

/// @title HookSaltMiner
/// @notice Off-chain search for a salt that gives a hook clone an address with exactly the required permission bits.
/// @dev 14 bits must match, so a salt takes 16,384 tries on average.
library HookSaltMiner {
    error SaltNotFound(uint256 start, uint256 tries);

    /// @notice Finds the first salt from `start` whose clone address has exactly `flags` as its low 14 bits.
    /// @param deployer The factory.
    /// @param initCodeHash The clone's init code hash, from `TickTockFactory.hookInitCodeHash`.
    function find(address deployer, bytes32 initCodeHash, uint160 flags, uint256 start, uint256 tries)
        internal
        pure
        returns (bytes32 salt, address hook)
    {
        for (uint256 i = start; i < start + tries; ++i) {
            hook = LibClone.predictDeterministicAddress(initCodeHash, bytes32(i), deployer);
            if (uint160(hook) & Hooks.ALL_HOOK_MASK == flags) return (bytes32(i), hook);
        }
        revert SaltNotFound(start, tries);
    }
}
