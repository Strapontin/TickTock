// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookSaltMiner} from "../../script/HookSaltMiner.sol";
import {HookConfig} from "../../src/libraries/HookConfig.sol";
import {OrderMath} from "../../src/libraries/OrderMath.sol";
import {TickTockFactory} from "../../src/TickTockFactory.sol";
import {TickTockHook} from "../../src/TickTockHook.sol";

/// @notice A local v4 deployment, two test tokens and a TickTock factory, plus helpers.
abstract contract TickTockTestBase is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint16 internal constant MAX_OPS = 24;
    uint128 internal constant USER_FUNDS = 1e30;

    TickTockFactory internal factory;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        factory = new TickTockFactory(manager, MAX_OPS);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Hooks and pools
    // ---------------------------------------------------------------------------------------------------------------

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

    function _key(TickTockHook hook, uint24 fee) internal view returns (PoolKey memory) {
        return PoolKey(currency0, currency1, fee, 1, IHooks(address(hook)));
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

    // ---------------------------------------------------------------------------------------------------------------
    // Users
    // ---------------------------------------------------------------------------------------------------------------

    /// Gives `user` both test tokens and approves `hook` to spend them.
    function _fund(address user, TickTockHook hook) internal {
        _fundCurrency(user, hook, currency0);
        _fundCurrency(user, hook, currency1);
        vm.deal(user, USER_FUNDS);
    }

    function _fundCurrency(address user, TickTockHook hook, Currency currency) internal {
        if (currency.isAddressZero()) return;
        MockERC20(Currency.unwrap(currency)).mint(user, USER_FUNDS);
        vm.prank(user);
        MockERC20(Currency.unwrap(currency)).approve(address(hook), type(uint256).max);
    }

    function _deposit(
        TickTockHook hook,
        PoolKey memory key,
        address user,
        int24 sellLevel,
        uint8 spreadIndex,
        bool startWithToken0,
        uint128 amount
    ) internal returns (uint64 groupId, uint256 shares) {
        vm.prank(user);
        return hook.deposit(key, sellLevel, spreadIndex, startWithToken0, amount, 0, user, block.timestamp);
    }

    function _withdrawAll(TickTockHook hook, address user, uint64 groupId)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 shares = hook.sharesOf(user, groupId);
        vm.prank(user);
        return hook.withdraw(groupId, shares, user, block.timestamp);
    }

    function _balance(Currency currency, address user) internal view returns (uint256) {
        return currency.balanceOf(user);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Swaps and pool state
    // ---------------------------------------------------------------------------------------------------------------

    /// Swaps from this contract until the price reaches `target`, with no limit on the amount.
    function _swapTo(PoolKey memory key, uint160 target) internal returns (BalanceDelta) {
        bool zeroForOne = target < _price(key);
        return swapRouter.swap(
            key,
            IPoolManager.SwapParams(zeroForOne, -int256(uint256(type(uint120).max)), target),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _swapToTick(PoolKey memory key, int24 tick) internal returns (BalanceDelta) {
        return _swapTo(key, TickMath.getSqrtPriceAtTick(tick));
    }

    function _price(PoolKey memory key) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = manager.getSlot0(key.toId());
    }

    function _positionLiquidity(TickTockHook hook, PoolKey memory key, int24 level) internal view returns (uint128) {
        (uint128 liquidity,,) = manager.getPositionInfo(key.toId(), address(hook), level, level + 1, bytes32(0));
        return liquidity;
    }

    function _sqrt(int24 tick) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }

    function _askLiquidity(int24 level, uint256 amount0) internal pure returns (uint256) {
        (uint160 lower, uint160 upper) = OrderMath.bounds(level);
        return OrderMath.liquidityForAmount0(lower, upper, amount0, false);
    }

    function _bidLiquidity(int24 level, uint256 amount1) internal pure returns (uint256) {
        (uint160 lower, uint160 upper) = OrderMath.bounds(level);
        return OrderMath.liquidityForAmount1(lower, upper, amount1, false);
    }
}
