// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Script.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPermit2, IUniversalRouter, UniversalRouterSwap} from "../UniversalRouterSwap.sol";
import {TestnetBase} from "./TestnetBase.sol";
import {TestToken} from "./TestToken.sol";

/// @notice One swap on the testnet pool through the Universal Router, paid with Permit2, as a wallet would send it.
/// It mints the input first: the test tokens are their own faucet.
/// @dev ZERO_FOR_ONE=true sells token0 for token1. AMOUNT_IN is in the input token's raw units.
///   ZERO_FOR_ONE=false AMOUNT_IN=5000000000 forge script script/testnet/Trade.s.sol --rpc-url unichain_sepolia \
///   --broadcast
contract Trade is TestnetBase {
    function run() external returns (int24 tickBefore, int24 tickAfter) {
        Testnet memory t = _load();
        bool zeroForOne = vm.envBool("ZERO_FOR_ONE");
        uint128 amountIn = uint128(vm.envUint("AMOUNT_IN"));
        (uint256 privateKey, address account) = _signer();
        address input = Currency.unwrap(zeroForOne ? t.key.currency0 : t.key.currency1);

        tickBefore = _tick(t.key);
        vm.startBroadcast(privateKey);
        TestToken(input).mint(account, amountIn);
        TestToken(input).approve(t.permit2, type(uint256).max);
        IPermit2(t.permit2).approve(input, t.universalRouter, type(uint160).max, type(uint48).max);
        (bytes memory commands, bytes[] memory inputs) =
            UniversalRouterSwap.exactInputSingle(t.key, zeroForOne, amountIn, 0);
        IUniversalRouter(t.universalRouter).execute(commands, inputs, block.timestamp + 600);
        vm.stopBroadcast();
        tickAfter = _tick(t.key);

        console.log("tick before:", vm.toString(tickBefore));
        console.log("tick after: ", vm.toString(tickAfter));
    }
}
