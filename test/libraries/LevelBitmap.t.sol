// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LevelBitmap} from "../../src/libraries/LevelBitmap.sol";

contract BitmapHarness {
    using LevelBitmap for mapping(int16 => uint256);

    mapping(int16 => uint256) internal bitmap;

    function set(int24 level, int24 spacing) external {
        bitmap.set(level, spacing);
    }

    function clear(int24 level, int24 spacing) external {
        bitmap.clear(level, spacing);
    }

    function isSet(int24 level, int24 spacing) external view returns (bool) {
        return bitmap.isSet(level, spacing);
    }

    function nextUp(int24 from, int24 to, int24 spacing) external view returns (int24, bool) {
        return bitmap.nextUp(from, to, spacing);
    }

    function nextDown(int24 from, int24 to, int24 spacing) external view returns (int24, bool) {
        return bitmap.nextDown(from, to, spacing);
    }
}

contract LevelBitmapTest is Test {
    BitmapHarness internal harness;

    /// Reference set for the brute-force comparison, keyed by compressed level.
    mapping(int24 => bool) internal expectedSet;

    function setUp() public {
        harness = new BitmapHarness();
    }

    function test_setClearIsSet() public {
        assertFalse(harness.isSet(-120, 60));
        harness.set(-120, 60);
        assertTrue(harness.isSet(-120, 60));
        harness.set(-120, 60);
        assertTrue(harness.isSet(-120, 60));
        harness.clear(-120, 60);
        assertFalse(harness.isSet(-120, 60));
    }

    function test_offGridReverts() public {
        vm.expectRevert(abi.encodeWithSelector(LevelBitmap.LevelNotOnGrid.selector, int24(61), int24(60)));
        harness.set(61, 60);
    }

    function test_neighborsAreIndependent() public {
        harness.set(-1, 1);
        assertFalse(harness.isSet(0, 1));
        assertFalse(harness.isSet(-2, 1));
        assertFalse(harness.isSet(255, 1));
        assertFalse(harness.isSet(-257, 1));
    }

    function test_nextUp_acrossWords() public {
        harness.set(-257, 1);
        harness.set(300, 1);
        _assertFound(harness.nextUp, -1000, 1000, 1, -257);
        _assertFound(harness.nextUp, -256, 1000, 1, 300);
        _assertNotFound(harness.nextUp, -256, 299, 1);
    }

    function test_nextDown_acrossWords() public {
        harness.set(-257, 1);
        harness.set(300, 1);
        _assertFound(harness.nextDown, 1000, -1000, 1, 300);
        _assertFound(harness.nextDown, 299, -1000, 1, -257);
        _assertNotFound(harness.nextDown, 299, -256, 1);
    }

    function test_boundsRoundInwardToGrid() public {
        harness.set(120, 60);
        harness.set(-120, 60);
        _assertFound(harness.nextUp, 61, 1000, 60, 120);
        _assertNotFound(harness.nextUp, 121, 179, 60);
        _assertFound(harness.nextDown, -61, -1000, 60, -120);
        _assertNotFound(harness.nextDown, -121, -179, 60);
        // A range holding no grid point at all.
        _assertNotFound(harness.nextUp, 1, 59, 60);
        _assertNotFound(harness.nextDown, 59, 1, 60);
    }

    function test_emptyRange() public {
        harness.set(0, 1);
        _assertNotFound(harness.nextUp, 1, 0, 1);
        _assertNotFound(harness.nextDown, 0, 1, 1);
    }

    function test_extremeTicks() public {
        int24 lowest = TickMath.MIN_TICK;
        int24 highest = TickMath.MAX_TICK - 1;
        harness.set(lowest, 1);
        harness.set(highest, 1);
        _assertFound(harness.nextUp, TickMath.MIN_TICK, TickMath.MAX_TICK, 1, lowest);
        _assertFound(harness.nextDown, TickMath.MAX_TICK, TickMath.MIN_TICK, 1, highest);

        // With a wide spacing, the extreme grid points are inside the tick bounds.
        int24 spacing = 600;
        int24 lowestOnGrid = (TickMath.MIN_TICK / spacing) * spacing;
        int24 highestOnGrid = (TickMath.MAX_TICK / spacing) * spacing;
        harness.set(lowestOnGrid, spacing);
        harness.set(highestOnGrid, spacing);
        _assertFound(harness.nextUp, TickMath.MIN_TICK, TickMath.MAX_TICK, spacing, lowestOnGrid);
        _assertFound(harness.nextDown, TickMath.MAX_TICK, TickMath.MIN_TICK, spacing, highestOnGrid);
    }

    /// Sets random levels near a random point and checks every search against a brute-force scan.
    function testFuzz_searchMatchesBruteForce(uint256 seed, uint16 spacingSeed, int24 centerSeed) public {
        int24 spacing = int24(uint24(bound(spacingSeed, 1, 200)));
        int24 minCompressed = TickMath.MIN_TICK / spacing;
        int24 maxCompressed = (TickMath.MAX_TICK - 1) / spacing;
        int24 window = 700; // spans several bitmap words
        int24 center = int24(bound(centerSeed, minCompressed + window, maxCompressed - window));

        for (uint256 i = 0; i < 24; ++i) {
            int24 compressed = center + int24(int256(_random(seed, i) % uint256(uint24(2 * window)))) - window;
            harness.set(compressed * spacing, spacing);
            expectedSet[compressed] = true;
        }

        for (uint256 q = 0; q < 8; ++q) {
            int24 a = (center - window) * spacing
                + int24(int256(_random(seed, 100 + q) % uint256(uint24(2 * window * spacing))));
            int24 b = (center - window) * spacing
                + int24(int256(_random(seed, 200 + q) % uint256(uint24(2 * window * spacing))));
            (int24 lo, int24 hi) = a <= b ? (a, b) : (b, a);

            (int24 upLevel, bool upFound) = harness.nextUp(lo, hi, spacing);
            (int24 expectedUp, bool expectedUpFound) = _bruteUp(lo, hi, spacing);
            assertEq(upFound, expectedUpFound, "nextUp found");
            if (upFound) assertEq(upLevel, expectedUp, "nextUp level");

            (int24 downLevel, bool downFound) = harness.nextDown(hi, lo, spacing);
            (int24 expectedDown, bool expectedDownFound) = _bruteDown(hi, lo, spacing);
            assertEq(downFound, expectedDownFound, "nextDown found");
            if (downFound) assertEq(downLevel, expectedDown, "nextDown level");
        }
    }

    function _bruteUp(int24 from, int24 to, int24 spacing) internal view returns (int24, bool) {
        int24 tick = from;
        while (tick <= to && tick % spacing != 0) ++tick;
        for (; tick <= to; tick += spacing) {
            if (expectedSet[tick / spacing]) return (tick, true);
        }
        return (0, false);
    }

    function _bruteDown(int24 from, int24 to, int24 spacing) internal view returns (int24, bool) {
        int24 tick = from;
        while (tick >= to && tick % spacing != 0) --tick;
        for (; tick >= to; tick -= spacing) {
            if (expectedSet[tick / spacing]) return (tick, true);
        }
        return (0, false);
    }

    function _random(uint256 seed, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i)));
    }

    function _assertFound(
        function(int24, int24, int24) external view returns (int24, bool) search,
        int24 from,
        int24 to,
        int24 spacing,
        int24 expected
    ) internal view {
        (int24 level, bool found) = search(from, to, spacing);
        assertTrue(found, "expected a level");
        assertEq(level, expected);
    }

    function _assertNotFound(
        function(int24, int24, int24) external view returns (int24, bool) search,
        int24 from,
        int24 to,
        int24 spacing
    ) internal view {
        (, bool found) = search(from, to, spacing);
        assertFalse(found, "expected no level");
    }
}
