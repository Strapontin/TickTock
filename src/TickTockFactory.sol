// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {HookConfig} from "./libraries/HookConfig.sol";
import {TickTockHook} from "./TickTockHook.sol";

/// @title TickTockFactory
/// @notice Deploys one TickTock hook per config, as a minimal clone of a single implementation. Anyone can deploy a
/// config; duplicates are refused. One factory per chain.
contract TickTockFactory {
    /// @notice The smallest allowed swap budget: 1 removal plus 8 additions, the busiest possible level.
    uint16 public constant MIN_OPS_PER_SWAP = 9;

    /// @notice The hook permissions every hook address must match exactly.
    uint160 public constant HOOK_FLAGS = HookConfig.HOOK_FLAGS;

    /// @notice The v4 pool manager.
    IPoolManager public immutable poolManager;

    /// @notice The most liquidity operations one swap's `afterSwap` may spend, for every hook of this factory.
    uint16 public immutable maxOpsPerSwap;

    /// @notice The hook implementation every clone delegates to.
    address public immutable implementation;

    /// @notice The hook deployed for a config, by config hash.
    mapping(bytes32 configHash => address hook) public hookOf;

    event HookCreated(bytes32 indexed configHash, address indexed hook, uint24 levelSpacing, int24[] spreads);

    error MaxOpsPerSwapTooLow(uint16 maxOpsPerSwap);
    error ConfigExists(address hook);
    error InvalidHookAddress(address hook);

    constructor(IPoolManager poolManager_, uint16 maxOpsPerSwap_) {
        if (maxOpsPerSwap_ < MIN_OPS_PER_SWAP) revert MaxOpsPerSwapTooLow(maxOpsPerSwap_);
        poolManager = poolManager_;
        maxOpsPerSwap = maxOpsPerSwap_;
        implementation = address(new TickTockHook(poolManager_, maxOpsPerSwap_));
    }

    /// @notice Deploys the hook for a config.
    /// @param salt A salt that gives the clone an address with exactly the hook's permission bits. Find one with
    /// `script/MineSalt.s.sol`.
    function createHook(uint24 levelSpacing, int24[] calldata spreads, bytes32 salt) external returns (address hook) {
        HookConfig.validate(levelSpacing, spreads);
        bytes32 configHash_ = HookConfig.hash(levelSpacing, spreads);
        address existing = hookOf[configHash_];
        if (existing != address(0)) revert ConfigExists(existing);

        bytes memory args = HookConfig.encode(levelSpacing, spreads);
        address predicted = LibClone.predictDeterministicAddress(implementation, args, salt, address(this));
        if (uint160(predicted) & Hooks.ALL_HOOK_MASK != HOOK_FLAGS) revert InvalidHookAddress(predicted);

        hook = LibClone.cloneDeterministic(implementation, args, salt);
        hookOf[configHash_] = hook;
        emit HookCreated(configHash_, hook, levelSpacing, spreads);
    }

    /// @notice The address `createHook` would deploy to.
    function predictHookAddress(uint24 levelSpacing, int24[] calldata spreads, bytes32 salt)
        external
        view
        returns (address)
    {
        HookConfig.validate(levelSpacing, spreads);
        return LibClone.predictDeterministicAddress(
            implementation, HookConfig.encode(levelSpacing, spreads), salt, address(this)
        );
    }

    /// @notice The init code hash of a config's clone, for mining salts off-chain.
    function hookInitCodeHash(uint24 levelSpacing, int24[] calldata spreads) external view returns (bytes32) {
        HookConfig.validate(levelSpacing, spreads);
        return LibClone.initCodeHash(implementation, HookConfig.encode(levelSpacing, spreads));
    }

    /// @notice The key a config is registered under in `hookOf`.
    function configHash(uint24 levelSpacing, int24[] calldata spreads) external pure returns (bytes32) {
        return HookConfig.hash(levelSpacing, spreads);
    }
}
