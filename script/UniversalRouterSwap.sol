// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

// The parts of Uniswap's periphery TickTock's scripts and fork tests call, as deployed on Unichain.

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IV4Quoter {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

/// @notice Builds Universal Router calls for one exact-input swap on one v4 pool, the way wallets send them: the router
/// pulls the input with Permit2 and sends the output to the caller.
library UniversalRouterSwap {
    /// @dev `IV4Router.ExactInputSingleParams`.
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    // The Universal Router command and v4 router actions used.
    uint8 internal constant V4_SWAP = 0x10;
    uint8 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant SETTLE_ALL = 0x0c;
    uint8 internal constant TAKE_ALL = 0x0f;

    /// Arguments for `IUniversalRouter.execute`, without the deadline.
    function exactInputSingle(PoolKey memory key, bool zeroForOne, uint128 amountIn, uint128 minAmountOut)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        (Currency input, Currency output) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingleParams(key, zeroForOne, amountIn, minAmountOut, ""));
        params[1] = abi.encode(input, uint256(amountIn));
        params[2] = abi.encode(output, uint256(minAmountOut));

        commands = abi.encodePacked(V4_SWAP);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL), params);
    }
}
