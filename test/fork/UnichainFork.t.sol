// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookSaltMiner} from "../../script/HookSaltMiner.sol";
import {UniswapAddresses} from "../../script/UniswapAddresses.sol";
import {IPermit2, IUniversalRouter, IV4Quoter, UniversalRouterSwap} from "../../script/UniversalRouterSwap.sol";
import {HookConfig} from "../../src/libraries/HookConfig.sol";
import {TickTockFactory} from "../../src/TickTockFactory.sol";
import {TickTockHook} from "../../src/TickTockHook.sol";

/// @notice TickTock against Uniswap's real deployments, on a fork of Unichain mainnet: the deployed PoolManager, and
/// swaps through the Universal Router and the V4Quoter the way wallets and aggregators send them.
/// @dev Opt-in: runs when UNICHAIN_RPC_URL is set, skips otherwise. The fork is pinned to FORK_BLOCK so Foundry caches
/// its state; override with UNICHAIN_FORK_BLOCK. Gas goes to `snapshots/TickTockUnichain.json`.
///   UNICHAIN_RPC_URL=https://mainnet.unichain.org forge test --mp "test/fork/*"
contract UnichainForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant FORK_BLOCK = 64_790_000;
    uint16 internal constant MAX_OPS = 24;
    /// Ethereum's per-transaction gas cap since Fusaka (EIP-7825).
    uint256 internal constant TX_GAS_CAP = 1 << 24;
    string internal constant GROUP = "TickTockUnichain";

    /// A large ask far above the orders. Swaps buy through the orders and stop inside it, so they never push the
    /// price into empty space at the end of the tick range.
    int24 internal constant WALL = 2000;

    UniswapAddresses.Deployment internal uni;
    IPoolManager internal manager;
    IUniversalRouter internal router;
    IV4Quoter internal quoter;

    TickTockFactory internal factory;
    uint256 internal factoryDeployGas;
    TickTockHook internal hook;
    PoolKey internal key;
    PoolId internal poolId;
    MockERC20 internal token0;
    MockERC20 internal token1;

    address internal alice = makeAddr("alice");

    function setUp() public {
        string memory rpc = vm.envOr("UNICHAIN_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envOr("UNICHAIN_FORK_BLOCK", FORK_BLOCK));
        assertEq(block.chainid, UniswapAddresses.UNICHAIN, "a Unichain mainnet RPC");
        uni = UniswapAddresses.forChain(block.chainid);
        manager = IPoolManager(uni.poolManager);
        router = IUniversalRouter(uni.universalRouter);
        quoter = IV4Quoter(uni.quoter);

        uint256 gasBefore = gasleft();
        factory = new TickTockFactory(manager, MAX_OPS);
        factoryDeployGas = gasBefore - gasleft();

        int24[] memory spreads = new int24[](8);
        for (uint256 i = 0; i < 8; ++i) {
            spreads[i] = int24(int256(10 * (i + 1)));
        }
        (bytes32 salt,) = HookSaltMiner.find(
            address(factory), factory.hookInitCodeHash(10, spreads), HookConfig.HOOK_FLAGS, 0, 1_000_000
        );
        hook = TickTockHook(factory.createHook(10, spreads, salt));

        MockERC20 a = new MockERC20("Token A", "A", 18);
        MockERC20 b = new MockERC20("Token B", "B", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 1, IHooks(address(hook)));
        poolId = key.toId();

        // Alice deposits; this contract trades through the router, paying with Permit2.
        for (uint256 i = 0; i < 2; ++i) {
            MockERC20 token = i == 0 ? token0 : token1;
            token.mint(alice, 1e30);
            vm.prank(alice);
            token.approve(address(hook), type(uint256).max);
            token.mint(address(this), 1e30);
            token.approve(uni.permit2, type(uint256).max);
            IPermit2(uni.permit2).approve(address(token), address(router), type(uint160).max, type(uint48).max);
        }

        // The first deposit creates the pool at its price, then the price moves down to 0 through empty space.
        _depositAsk(5000, 0, 1e18);
        hook.movePrice(key, TickMath.getSqrtPriceAtTick(0));
        _depositAsk(WALL, 0, 1e24);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Deployment
    // ---------------------------------------------------------------------------------------------------------------

    /// Deploying the factory (which deploys the implementation and the engine) is the largest transaction.
    function test_deploymentFitsUnderTheTxGasCap() public view {
        bytes memory initCode = abi.encodePacked(type(TickTockFactory).creationCode, abi.encode(manager, MAX_OPS));
        uint256 txGas = factoryDeployGas + _creationIntrinsicGas(initCode);
        console.log("factory deployment gas:", txGas);
        assertLt(txGas, TX_GAS_CAP);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Swaps through the Universal Router
    // ---------------------------------------------------------------------------------------------------------------

    function test_quoterMatchesTheRouterOnAFlip() public {
        _depositAsk(100, 0, 1e18);
        uint128 amountIn = 2e18;

        (uint256 quoted, uint256 quoterGas) =
            quoter.quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams(key, false, amountIn, ""));
        uint256 received = _buy0(amountIn, "router swap: flips 1 level, 1 spread (2 ops)");

        assertEq(received, quoted, "the quote includes afterSwap");
        assertEq(hook.getLevel(poolId, 100).askLiquidity, 0, "the ask flipped");
        assertGt(hook.getLevel(poolId, 90).bidLiquidity, 0, "into the bid");
        console.log("quoter gas estimate:", quoterGas);
    }

    function test_routerSwapCrossingNoLevel() public {
        _buy0(1e15, "router swap: crosses no level");
        (, int24 tick,,) = manager.getSlot0(poolId);
        assertEq(tick, WALL, "stopped inside the wall");
    }

    /// The worst case per swap with 24 operations: two 8-spread levels, each flipping into 8 fresh destinations.
    function test_routerSwapWorstCase() public {
        _eightAsksAt(200);
        _eightAsksAt(300);
        _buy0(30e18, "router swap: budget spent on 8-spread levels (2 levels, 18 ops)");
        assertEq(hook.getLevel(poolId, 200).askLiquidity, 0);
        assertEq(hook.getLevel(poolId, 300).askLiquidity, 0);
    }

    /// Three 8-spread levels need 27 operations, more than the budget: the swap flips two, a keeper the third.
    function test_routerSwapOverBudgetThenFlipCrossed() public {
        _eightAsksAt(200);
        _eightAsksAt(300);
        _eightAsksAt(400);
        _buy0(40e18, "");

        uint256 unflipped;
        for (int24 level = 200; level <= 400; level += 100) {
            if (hook.getLevel(poolId, level).askLiquidity != 0) ++unflipped;
        }
        assertEq(unflipped, 1, "the budget ran out after two levels");

        uint256 ops = hook.flipCrossed(key, 100);
        vm.snapshotGasLastCall(GROUP, "flipCrossed: 1 leftover 8-spread level");
        assertEq(ops, 9);
        for (int24 level = 200; level <= 400; level += 100) {
            assertEq(hook.getLevel(poolId, level).askLiquidity, 0);
        }
    }

    function test_depositNewGroup() public {
        vm.prank(alice);
        hook.deposit(key, 100, 0, true, 1e18, 0, alice, block.timestamp);
        vm.snapshotGasLastCall(GROUP, "deposit: new group");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _depositAsk(int24 sellLevel, uint8 spreadIndex, uint128 amount0) internal {
        vm.prank(alice);
        hook.deposit(key, sellLevel, spreadIndex, true, amount0, 0, alice, block.timestamp);
    }

    function _eightAsksAt(int24 level) internal {
        for (uint8 k = 0; k < 8; ++k) {
            _depositAsk(level, k, 1e18);
        }
    }

    /// Buys token0 with exactly `amountIn` token1 through the Universal Router, and records the gas under `gasName`
    /// unless it's empty.
    function _buy0(uint128 amountIn, string memory gasName) internal returns (uint256 received) {
        (bytes memory commands, bytes[] memory inputs) = UniversalRouterSwap.exactInputSingle(key, false, amountIn, 0);
        uint256 before = token0.balanceOf(address(this));
        router.execute(commands, inputs, block.timestamp);
        if (bytes(gasName).length != 0) vm.snapshotGasLastCall(GROUP, gasName);
        return token0.balanceOf(address(this)) - before;
    }

    /// A contract creation's intrinsic gas: the base cost, the creation cost, calldata, and initcode words
    /// (EIP-3860).
    function _creationIntrinsicGas(bytes memory initCode) internal pure returns (uint256 gas) {
        gas = 21_000 + 32_000 + 2 * ((initCode.length + 31) / 32);
        for (uint256 i = 0; i < initCode.length; ++i) {
            gas += initCode[i] == 0 ? 4 : 16;
        }
    }
}
