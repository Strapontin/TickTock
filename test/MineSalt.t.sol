// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MineSalt} from "../script/MineSalt.s.sol";
import {TickTockTestBase} from "./utils/TickTockTestBase.sol";

contract MineSaltTest is TickTockTestBase {
    function test_minedSaltIsAccepted() public {
        vm.setEnv("FACTORY", vm.toString(address(factory)));
        vm.setEnv("LEVEL_SPACING", "10");
        vm.setEnv("SPREADS", "10,50,100");

        (bytes32 salt, address predicted) = new MineSalt().run();

        assertEq(factory.createHook(10, _spreads(10, 50, 100), salt), predicted);
    }
}
