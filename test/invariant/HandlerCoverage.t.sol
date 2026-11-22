// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {TickTockState} from "../../src/base/TickTockState.sol";
import {TickTockInvariantSetup} from "./TickTockInvariants.t.sol";

/// @notice Guards the invariant suite against going vacuous: a fixed sequence of handler actions must reach every
/// path the invariants are meant to cover (flips, partial flips, merges, skips, capped placements), then everyone
/// withdraws as at the end of each invariant run.
contract HandlerCoverageTest is TickTockInvariantSetup {
    struct Seen {
        uint256 flips;
        uint256 partialFlips;
        uint256 merges;
        uint256 skips;
        uint256 unplaced;
    }

    function test_handlerReachesEveryPath() public {
        Seen memory seen;
        vm.recordLogs();
        for (uint256 i = 0; i < 300; ++i) {
            _act(uint256(keccak256(abi.encode("coverage", i))));
            _countEvents(seen, vm.getRecordedLogs());
        }

        assertGt(handler.successes("deposit"), 0, "deposits");
        assertGt(handler.successes("withdraw"), 0, "withdrawals");
        assertGt(handler.successes("swap"), 0, "swaps");
        assertGt(handler.successes("flipCrossed"), 0, "flipCrossed");
        assertGt(handler.successes("movePrice"), 0, "movePrice");
        assertGt(handler.successes("fillTick"), 0, "fillTick");
        assertGt(seen.flips, 0, "flips");
        assertGt(seen.partialFlips, 0, "partial flips");
        assertGt(seen.merges, 0, "merges");
        assertGt(seen.skips, 0, "skips");
        assertGt(seen.unplaced, 0, "capped placements");
        assertEq(handler.unexpectedReverts(), 0, string(handler.lastUnexpected()));
        assertEq(handler.afterSwapReverts(), 0, "afterSwap reverts");

        _withdrawEveryoneAndCheck();
    }

    function _act(uint256 r) internal {
        uint256 s1 = r >> 8;
        uint256 s3 = r >> 128;
        int256 s2 = int256((r >> 64) % 2000) - 1000;
        uint256 action = r % 8;
        if (action == 0) handler.deposit(s1, s3, s2, s3 >> 3, (r >> 200) & 1 == 1, s3 >> 7);
        else if (action == 1) handler.withdraw(s1, s3, s3 >> 5, s1 >> 9);
        else if (action == 2) handler.swap(s1, s2);
        else if (action == 3) handler.flipLevel(s1, s3);
        else if (action == 4) handler.flipCrossed(s1, s3);
        else if (action == 5) handler.movePrice(s1, s2);
        else if (action == 6) handler.partialFill(s1, s3, s1 >> 11);
        else handler.fillTick(s1, s3, s1 >> 13, s3 >> 17);
    }

    function _countEvents(Seen memory seen, Vm.Log[] memory logs) internal pure {
        for (uint256 j = 0; j < logs.length; ++j) {
            bytes32 topic = logs[j].topics[0];
            if (topic == TickTockState.LevelFlipped.selector) {
                ++seen.flips;
                // The last data word is `partialFill`.
                (,, bool partialFill) = abi.decode(logs[j].data, (bool, uint256, bool));
                if (partialFill) ++seen.partialFlips;
            } else if (topic == TickTockState.GroupsMerged.selector) {
                ++seen.merges;
            } else if (topic == TickTockState.LevelSkipped.selector) {
                ++seen.skips;
            } else if (topic == TickTockState.AmountUnplaced.selector) {
                ++seen.unplaced;
            }
        }
    }
}
