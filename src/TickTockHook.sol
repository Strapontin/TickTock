// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {HookConfig} from "./libraries/HookConfig.sol";

/// @title TickTockHook
/// @notice A Uniswap v4 hook for double-sided limit orders that repeat forever. See docs/DESIGN.md.
/// @dev The factory deploys this contract once as an implementation, then one minimal clone per config. The pool
/// manager and the swap budget are immutables of the implementation, shared by every clone of one factory. The
/// config (level spacing and spreads) is each clone's immutable args. The implementation refuses every call that
/// doesn't come through a clone.
contract TickTockHook is IHooks, ReentrancyGuardTransient {
    /// @notice The v4 pool manager.
    IPoolManager public immutable poolManager;

    /// @notice The most liquidity operations one swap's `afterSwap` may spend.
    uint16 public immutable maxOpsPerSwap;

    /// @dev This contract's own address, to tell the implementation apart from its clones.
    address private immutable _implementation;

    /// @notice The implementation was called directly instead of through a clone.
    error NotAClone();
    /// @notice A pool callback came from someone other than the pool manager.
    error NotPoolManager();
    /// @notice Pools are only created by the hook, on the first deposit.
    error PoolCreationRestricted();
    /// @notice Only the hook provides liquidity in its pools.
    error LiquidityRestricted();
    /// @notice Donations are blocked.
    error DonationsBlocked();
    /// @notice A callback whose permission flag is off was called.
    error HookNotImplemented();

    constructor(IPoolManager poolManager_, uint16 maxOpsPerSwap_) {
        poolManager = poolManager_;
        maxOpsPerSwap = maxOpsPerSwap_;
        _implementation = address(this);
    }

    modifier onlyClone() {
        _checkClone();
        _;
    }

    modifier onlyPoolManager() {
        _checkPoolManager();
        _;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Config
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice This hook's config.
    function config() external view onlyClone returns (uint24 levelSpacing, int24[] memory spreads) {
        HookConfig.Config memory c = _config();
        levelSpacing = uint24(c.levelSpacing);
        spreads = new int24[](c.spreadCount);
        for (uint256 i = 0; i < c.spreadCount; ++i) {
            spreads[i] = c.spreads[i];
        }
    }

    function _config() internal view returns (HookConfig.Config memory) {
        return HookConfig.decode(LibClone.argsOnClone(address(this)));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // v4 hook callbacks
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    /// @dev The hook's own `initialize` calls skip this callback (v4 `noSelfCall`), so only the hook creates pools.
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert PoolCreationRestricted();
    }

    /// @inheritdoc IHooks
    /// @dev The hook's own liquidity calls skip this callback, so only outside LPs are refused.
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert LiquidityRestricted();
    }

    /// @inheritdoc IHooks
    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        onlyClone
        onlyPoolManager
        nonReentrant
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, 0);
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert DonationsBlocked();
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------------------------

    function _checkClone() internal view {
        if (address(this) == _implementation) revert NotAClone();
    }

    function _checkPoolManager() internal view {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    /// @dev v4 needs transient storage on every chain it runs on, so the lock always uses it. Solady's default
    /// falls back to regular storage outside Ethereum mainnet.
    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }
}
