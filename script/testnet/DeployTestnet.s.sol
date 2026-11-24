// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickTockFactory} from "../../src/TickTockFactory.sol";
import {TickTockHook} from "../../src/TickTockHook.sol";
import {UniswapAddresses} from "../UniswapAddresses.sol";
import {TestnetBase} from "./TestnetBase.sol";
import {TestToken} from "./TestToken.sol";

/// @notice Deploys TickTock on Unichain Sepolia with two test tokens, and writes every address to the deployment
/// file. The pool itself is created by the first deposit (`Seed`).
/// @dev forge script script/testnet/DeployTestnet.s.sol --rpc-url unichain_sepolia --broadcast
contract DeployTestnet is TestnetBase {
    using PoolIdLibrary for PoolKey;

    uint16 internal constant MAX_OPS_PER_SWAP = 24;
    uint24 internal constant LEVEL_SPACING = 10;
    uint24 internal constant FEE = 500; // 0.05%
    uint256 internal constant PRICE = 3000; // tUSDC per tWETH

    struct Deployed {
        TestToken base;
        TestToken quote;
        TickTockFactory factory;
        address hook;
        PoolKey key;
    }

    function run() external returns (Deployed memory d) {
        require(block.chainid == UniswapAddresses.UNICHAIN_SEPOLIA, "DeployTestnet: Unichain Sepolia only");
        (uint256 privateKey,) = _signer();
        uint256 startBlock = block.number;

        vm.startBroadcast(privateKey);
        d.base = new TestToken("TickTock Test WETH", "tWETH", 18);
        d.quote = new TestToken("TickTock Test USDC", "tUSDC", 6);
        d.factory = _deployFactory(MAX_OPS_PER_SWAP);
        d.hook = _createHook(d.factory, LEVEL_SPACING, spreads());
        vm.stopBroadcast();

        (address token0, address token1) = address(d.base) < address(d.quote)
            ? (address(d.base), address(d.quote))
            : (address(d.quote), address(d.base));
        d.key = PoolKey(Currency.wrap(token0), Currency.wrap(token1), FEE, 1, IHooks(d.hook));

        _write(d, startBlock);
        console.log("hook:", d.hook);
        console.log("written to", deploymentPath());
    }

    /// 0.1% to 2%.
    function spreads() public pure returns (int24[] memory s) {
        s = new int24[](5);
        (s[0], s[1], s[2], s[3], s[4]) = (10, 20, 50, 100, 200);
    }

    function _write(Deployed memory d, uint256 startBlock) internal {
        UniswapAddresses.Deployment memory uni = UniswapAddresses.forChain(block.chainid);
        address implementation = d.factory.implementation();

        string memory pool = "pool";
        vm.serializeBytes32(pool, "id", PoolId.unwrap(d.key.toId()));
        vm.serializeAddress(pool, "currency0", Currency.unwrap(d.key.currency0));
        vm.serializeAddress(pool, "currency1", Currency.unwrap(d.key.currency1));
        vm.serializeUint(pool, "fee", d.key.fee);
        vm.serializeInt(pool, "tickSpacing", d.key.tickSpacing);
        pool = vm.serializeAddress(pool, "hooks", d.hook);

        string memory tokens = "tokens";
        vm.serializeAddress(tokens, "base", address(d.base));
        tokens = vm.serializeAddress(tokens, "quote", address(d.quote));

        int24[] memory s = spreads();
        int256[] memory spreads256 = new int256[](s.length);
        for (uint256 i = 0; i < s.length; ++i) {
            spreads256[i] = s[i];
        }

        string memory root = "deployment";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "startBlock", startBlock);
        vm.serializeAddress(root, "poolManager", uni.poolManager);
        vm.serializeAddress(root, "universalRouter", uni.universalRouter);
        vm.serializeAddress(root, "quoter", uni.quoter);
        vm.serializeAddress(root, "stateView", uni.stateView);
        vm.serializeAddress(root, "permit2", uni.permit2);
        vm.serializeAddress(root, "factory", address(d.factory));
        vm.serializeAddress(root, "implementation", implementation);
        vm.serializeAddress(root, "engine", TickTockHook(implementation).engine());
        vm.serializeAddress(root, "hook", d.hook);
        vm.serializeUint(root, "maxOpsPerSwap", MAX_OPS_PER_SWAP);
        vm.serializeUint(root, "levelSpacing", LEVEL_SPACING);
        vm.serializeInt(root, "spreads", spreads256);
        vm.serializeUint(root, "price", PRICE);
        vm.serializeString(root, "tokens", tokens);
        root = vm.serializeString(root, "pool", pool);
        vm.writeJson(root, deploymentPath());
    }
}
