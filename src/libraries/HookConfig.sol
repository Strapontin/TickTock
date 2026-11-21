// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title HookConfig
/// @notice A TickTock config (level spacing plus spread menu): validation, and its encoding as a clone's immutable
/// args. Shared by the factory, which writes the args, and the hook, which reads them.
/// @dev The args are 28 bytes: `levelSpacing` (3 bytes), the number of spreads (1 byte), then 8 spreads of 3 bytes
/// each, unused ones zero.
library HookConfig {
    /// @notice The hook permissions. A hook's address must have exactly these low bits.
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG;

    /// @notice The most spreads a menu can hold.
    uint256 internal constant MAX_SPREADS = 8;

    /// @notice The widest level spacing: wider would leave at most one level.
    uint24 internal constant MAX_LEVEL_SPACING = uint24(TickMath.MAX_TICK);

    /// @notice The widest spread that still fits a strategy inside the tick bounds: `S - spread >= MIN_TICK` and
    /// `S + 1 <= MAX_TICK`.
    int24 internal constant MAX_SPREAD = TickMath.MAX_TICK - 1 - TickMath.MIN_TICK;

    /// @notice Length of the encoded args.
    uint256 internal constant ARGS_LENGTH = 28;

    struct Config {
        int24 levelSpacing;
        uint8 spreadCount;
        int24[8] spreads;
    }

    error InvalidLevelSpacing(uint24 levelSpacing);
    error InvalidSpreadCount(uint256 count);
    error InvalidSpread(uint256 index, int24 spread);

    /// @notice Reverts unless the config is valid (DESIGN.md section 2).
    /// @dev Spreads must be strictly increasing, positive multiples of the level spacing, at most `MAX_SPREAD`.
    function validate(uint24 levelSpacing, int24[] memory spreads) internal pure {
        if (levelSpacing == 0 || levelSpacing > MAX_LEVEL_SPACING) revert InvalidLevelSpacing(levelSpacing);
        uint256 count = spreads.length;
        if (count == 0 || count > MAX_SPREADS) revert InvalidSpreadCount(count);
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 spacing = int24(levelSpacing); // at most MAX_LEVEL_SPACING, checked above
        int24 previous = 0;
        for (uint256 i = 0; i < count; ++i) {
            int24 spread = spreads[i];
            if (spread <= previous || spread > MAX_SPREAD || spread % spacing != 0) revert InvalidSpread(i, spread);
            previous = spread;
        }
    }

    /// @notice The key a config is registered under in the factory.
    function hash(uint24 levelSpacing, int24[] memory spreads) internal pure returns (bytes32) {
        return keccak256(abi.encode(levelSpacing, spreads));
    }

    /// @notice Encodes a validated config as clone args.
    function encode(uint24 levelSpacing, int24[] memory spreads) internal pure returns (bytes memory args) {
        args = abi.encodePacked(levelSpacing, uint8(spreads.length));
        for (uint256 i = 0; i < MAX_SPREADS; ++i) {
            args = abi.encodePacked(args, i < spreads.length ? spreads[i] : int24(0));
        }
    }

    /// @notice Decodes clone args written by `encode`.
    function decode(bytes memory args) internal pure returns (Config memory config) {
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(args, 0x20))
        }
        // The casts keep exactly the bits each field was written with.
        // forge-lint: disable-next-line(unsafe-typecast)
        config.levelSpacing = int24(uint24(word >> 232));
        // forge-lint: disable-next-line(unsafe-typecast)
        config.spreadCount = uint8(word >> 224);
        for (uint256 i = 0; i < MAX_SPREADS; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            config.spreads[i] = int24(uint24(word >> (200 - 24 * i)));
        }
    }
}
