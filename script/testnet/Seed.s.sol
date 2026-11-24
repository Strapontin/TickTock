// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Script.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {TickTockHook} from "../../src/TickTockHook.sol";
import {TestnetBase} from "./TestnetBase.sol";
import {TestToken} from "./TestToken.sol";

/// @notice Seeds the testnet pool with a ladder of orders around the deployment's price: LEVELS asks above it and
/// LEVELS bids below, one level apart, cycling through the spreads. Each order is worth one base token. The first
/// deposit creates the pool.
/// @dev forge script script/testnet/Seed.s.sol --rpc-url unichain_sepolia --broadcast
contract Seed is TestnetBase {
    function run() external returns (int24 midLevel) {
        Testnet memory t = _load();
        TickTockHook hook = TickTockHook(t.hook);
        (uint24 spacing, int24[] memory spreads) = hook.config();
        int24 step = int24(spacing);
        uint256 levels = vm.envOr("LEVELS", uint256(8));
        (uint256 privateKey, address account) = _signer();

        midLevel = _floorToSpacing(_priceTick(t), step);
        (uint256 askAmount0, uint256 bidAmount1) = _orderAmounts(t);
        TestToken token0 = TestToken(Currency.unwrap(t.key.currency0));
        TestToken token1 = TestToken(Currency.unwrap(t.key.currency1));

        vm.startBroadcast(privateKey);
        token0.mint(account, askAmount0 * levels);
        token1.mint(account, bidAmount1 * levels);
        token0.approve(t.hook, type(uint256).max);
        token1.approve(t.hook, type(uint256).max);
        // Asks at mid + 1, mid + 2, ... levels. The first creates the pool at its price.
        for (uint256 j = 1; j <= levels; ++j) {
            uint8 k = uint8((j - 1) % spreads.length);
            int24 level = midLevel + int24(int256(j)) * step;
            hook.deposit(t.key, level, k, true, uint128(askAmount0), 0, account, block.timestamp + 600);
        }
        // Bids at mid, mid - 1, ... levels. A bid at B belongs to the strategy selling at B + spread.
        for (uint256 j = 0; j < levels; ++j) {
            uint8 k = uint8(j % spreads.length);
            int24 level = midLevel - int24(int256(j)) * step;
            hook.deposit(t.key, level + spreads[k], k, false, uint128(bidAmount1), 0, account, block.timestamp + 600);
        }
        vm.stopBroadcast();

        console.log("mid level:", vm.toString(midLevel));
        console.log("pool tick:", vm.toString(_tick(t.key)));
    }

    /// The tick of the deployment's price, in raw token1 per raw token0.
    function _priceTick(Testnet memory t) internal view returns (int24) {
        uint256 baseUnit = 10 ** TestToken(t.base).decimals();
        uint256 quoteUnits = t.price * 10 ** TestToken(t.quote).decimals();
        bool baseIs0 = Currency.unwrap(t.key.currency0) == t.base;
        (uint256 raw1, uint256 raw0) = baseIs0 ? (quoteUnits, baseUnit) : (baseUnit, quoteUnits);
        uint256 sqrtPriceX96 = FixedPointMathLib.sqrt(FullMath.mulDiv(raw1, 1 << 192, raw0));
        return TickMath.getTickAtSqrtPrice(uint160(sqrtPriceX96));
    }

    /// One base token per order: an ask's token0 amount and a bid's token1 amount.
    function _orderAmounts(Testnet memory t) internal view returns (uint256 askAmount0, uint256 bidAmount1) {
        uint256 baseAmount = 10 ** TestToken(t.base).decimals();
        uint256 quoteAmount = t.price * 10 ** TestToken(t.quote).decimals();
        bool baseIs0 = Currency.unwrap(t.key.currency0) == t.base;
        return baseIs0 ? (baseAmount, quoteAmount) : (quoteAmount, baseAmount);
    }

    function _floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 r = tick % spacing;
        return r < 0 ? tick - r - spacing : tick - r;
    }
}
