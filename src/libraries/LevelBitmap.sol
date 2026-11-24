// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";

/// @title LevelBitmap
/// @notice A bitmap of order levels, compressed by the config's level spacing, with a bounded search for the next
/// set level in either direction.
/// @dev A level is a tick that is a multiple of `spacing`. Its bit sits at `level / spacing`, split into a word
/// (the upper bits) and a bit inside that word (the lower 8 bits), as in v4's TickBitmap. Search bounds can be any
/// tick: they are rounded inward to the level grid.
library LevelBitmap {
    /// @notice Thrown when a level is not a multiple of the spacing.
    error LevelNotOnGrid(int24 level, int24 spacing);

    /// @notice Sets the bit of `level`.
    function set(mapping(int16 => uint256) storage self, int24 level, int24 spacing) internal {
        (int16 wordPos, uint8 bitPos) = _position(_compress(level, spacing));
        self[wordPos] |= uint256(1) << bitPos;
    }

    /// @notice Clears the bit of `level`.
    function clear(mapping(int16 => uint256) storage self, int24 level, int24 spacing) internal {
        (int16 wordPos, uint8 bitPos) = _position(_compress(level, spacing));
        self[wordPos] &= ~(uint256(1) << bitPos);
    }

    /// @notice Whether the bit of `level` is set.
    function isSet(mapping(int16 => uint256) storage self, int24 level, int24 spacing) internal view returns (bool) {
        (int16 wordPos, uint8 bitPos) = _position(_compress(level, spacing));
        return self[wordPos] & (uint256(1) << bitPos) != 0;
    }

    /// @notice Finds the lowest set level in the tick range `[from, to]`.
    /// @dev Reads one storage word per 256 levels in the range.
    function nextUp(mapping(int16 => uint256) storage self, int24 from, int24 to, int24 spacing)
        internal
        view
        returns (int24 level, bool found)
    {
        int24 lo = _ceilDiv(from, spacing);
        int24 hi = _floorDiv(to, spacing);
        if (lo > hi) return (0, false);

        (int16 wordPos, uint8 bitPos) = _position(lo);
        (int16 endWordPos, uint8 endBitPos) = _position(hi);

        uint256 word = self[wordPos] & (type(uint256).max << bitPos);
        while (true) {
            if (wordPos == endWordPos) word &= type(uint256).max >> (255 - endBitPos);
            if (word != 0) {
                return (_decompress(wordPos, BitMath.leastSignificantBit(word), spacing), true);
            }
            if (wordPos == endWordPos) return (0, false);
            unchecked {
                ++wordPos;
            }
            word = self[wordPos];
        }
    }

    /// @notice Finds the highest set level in the tick range `[to, from]`.
    /// @dev Reads one storage word per 256 levels in the range.
    function nextDown(mapping(int16 => uint256) storage self, int24 from, int24 to, int24 spacing)
        internal
        view
        returns (int24 level, bool found)
    {
        int24 hi = _floorDiv(from, spacing);
        int24 lo = _ceilDiv(to, spacing);
        if (lo > hi) return (0, false);

        (int16 wordPos, uint8 bitPos) = _position(hi);
        (int16 endWordPos, uint8 endBitPos) = _position(lo);

        uint256 word = self[wordPos] & (type(uint256).max >> (255 - bitPos));
        while (true) {
            if (wordPos == endWordPos) word &= type(uint256).max << endBitPos;
            if (word != 0) {
                return (_decompress(wordPos, BitMath.mostSignificantBit(word), spacing), true);
            }
            if (wordPos == endWordPos) return (0, false);
            unchecked {
                --wordPos;
            }
            word = self[wordPos];
        }
    }

    function _compress(int24 level, int24 spacing) private pure returns (int24) {
        if (level % spacing != 0) revert LevelNotOnGrid(level, spacing);
        return level / spacing;
    }

    function _decompress(int16 wordPos, uint8 bitPos, int24 spacing) private pure returns (int24) {
        // Cannot overflow: the compressed index of a valid tick fits in 21 bits, and the result is a valid tick.
        unchecked {
            return ((int24(wordPos) << 8) + int24(uint24(bitPos))) * spacing;
        }
    }

    function _position(int24 compressed) private pure returns (int16 wordPos, uint8 bitPos) {
        assembly ("memory-safe") {
            wordPos := sar(8, compressed)
            bitPos := and(compressed, 0xff)
        }
    }

    function _floorDiv(int24 a, int24 b) private pure returns (int24 q) {
        q = a / b;
        if (a % b != 0 && a < 0) --q;
    }

    function _ceilDiv(int24 a, int24 b) private pure returns (int24 q) {
        q = a / b;
        if (a % b != 0 && a > 0) ++q;
    }
}
