// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {HookSaltMiner} from "../../script/HookSaltMiner.sol";
import {HookConfig} from "../../src/libraries/HookConfig.sol";
import {TickTockFactory} from "../../src/TickTockFactory.sol";
import {TickTockHook} from "../../src/TickTockHook.sol";

/// @notice A local v4 deployment, two test tokens and a TickTock factory.
abstract contract TickTockTestBase is Test, Deployers {
    uint16 internal constant MAX_OPS = 24;

    TickTockFactory internal factory;

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        factory = new TickTockFactory(manager, MAX_OPS);
    }

    function _createHook(uint24 levelSpacing, int24[] memory spreads) internal returns (TickTockHook) {
        (bytes32 salt,) = _mineSalt(levelSpacing, spreads, 0);
        return TickTockHook(factory.createHook(levelSpacing, spreads, salt));
    }

    function _mineSalt(uint24 levelSpacing, int24[] memory spreads, uint256 start)
        internal
        view
        returns (bytes32 salt, address hook)
    {
        bytes32 initCodeHash = factory.hookInitCodeHash(levelSpacing, spreads);
        return HookSaltMiner.find(address(factory), initCodeHash, HookConfig.HOOK_FLAGS, start, 1_000_000);
    }

    function _spreads(int24 a) internal pure returns (int24[] memory s) {
        s = new int24[](1);
        s[0] = a;
    }

    function _spreads(int24 a, int24 b) internal pure returns (int24[] memory s) {
        s = new int24[](2);
        (s[0], s[1]) = (a, b);
    }

    function _spreads(int24 a, int24 b, int24 c) internal pure returns (int24[] memory s) {
        s = new int24[](3);
        (s[0], s[1], s[2]) = (a, b, c);
    }
}
