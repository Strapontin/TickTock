// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {DeployTestnet} from "../../script/testnet/DeployTestnet.s.sol";
import {Seed} from "../../script/testnet/Seed.s.sol";
import {Trade} from "../../script/testnet/Trade.s.sol";
import {TickTockHook} from "../../src/TickTockHook.sol";

/// @notice The testnet scripts, run in order on a fork of Unichain Sepolia: deploy, seed, trade. They write their
/// deployment file to a scratch path, removed at the end.
/// @dev Opt-in: runs when UNICHAIN_SEPOLIA_RPC_URL is set, skips otherwise.
contract TestnetScriptsTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant FORK_BLOCK = 68_690_000;
    string internal constant DEPLOYMENT = "deployments/test-run.json";

    function setUp() public {
        string memory rpc = vm.envOr("UNICHAIN_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envOr("UNICHAIN_SEPOLIA_FORK_BLOCK", FORK_BLOCK));
        (address deployer, uint256 privateKey) = makeAddrAndKey("testnet deployer");
        vm.deal(deployer, 1 ether);
        vm.setEnv("PRIVATE_KEY", vm.toString(privateKey));
        vm.setEnv("DEPLOYMENT", DEPLOYMENT);
    }

    function test_deploySeedAndTrade() public {
        DeployTestnet.Deployed memory d = new DeployTestnet().run();
        TickTockHook hook = TickTockHook(d.hook);
        PoolId poolId = d.key.toId();
        assertEq(vm.parseJsonAddress(vm.readFile(DEPLOYMENT), ".hook"), d.hook, "the file has the hook");

        int24 mid = new Seed().run();
        assertGt(hook.getLevel(poolId, mid + 10).askLiquidity, 0, "the best ask");
        assertGt(hook.getLevel(poolId, mid).bidLiquidity, 0, "the best bid");

        // Buy token0 worth 2.5 orders: through the two best asks, into the third.
        bool baseIs0 = Currency.unwrap(d.key.currency0) == address(d.base);
        uint256 orderValue1 = baseIs0 ? 3000 * 10 ** d.quote.decimals() : 10 ** d.base.decimals();
        vm.setEnv("ZERO_FOR_ONE", "false");
        vm.setEnv("AMOUNT_IN", vm.toString(orderValue1 * 5 / 2));
        (int24 tickBefore, int24 tickAfter) = new Trade().run();

        assertEq(tickBefore, mid + 10);
        assertEq(tickAfter, mid + 30, "stopped inside the third ask");
        assertEq(hook.getLevel(poolId, mid + 10).askLiquidity, 0, "the first ask flipped");
        assertEq(hook.getLevel(poolId, mid + 20).askLiquidity, 0, "the second ask flipped");

        vm.removeFile(DEPLOYMENT);
    }
}
