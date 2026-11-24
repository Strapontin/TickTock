// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The Uniswap v4 deployments TickTock uses, per chain. Source: the v4 deployments page of the Uniswap docs,
/// checked on-chain on 2026-11-24 (code present, and each Quoter points at the listed PoolManager).
library UniswapAddresses {
    struct Deployment {
        address poolManager;
        address universalRouter;
        address quoter;
        address stateView;
        address permit2;
    }

    uint256 internal constant UNICHAIN = 130;
    uint256 internal constant UNICHAIN_SEPOLIA = 1301;

    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    error UnsupportedChain(uint256 chainId);

    function forChain(uint256 chainId) internal pure returns (Deployment memory) {
        if (chainId == UNICHAIN) {
            return Deployment({
                poolManager: 0x1F98400000000000000000000000000000000004,
                universalRouter: 0xEf740bf23aCaE26f6492B10de645D6B98dC8Eaf3,
                quoter: 0xF885781cB68A0BE66AA2AC7eDa5Fe72Bde7dA907,
                stateView: 0x86e8631A016F9068C3f085fAF484Ee3F5fDee8f2,
                permit2: PERMIT2
            });
        }
        if (chainId == UNICHAIN_SEPOLIA) {
            return Deployment({
                poolManager: 0x00B036B58a818B1BC34d502D3fE730Db729e62AC,
                universalRouter: 0xf70536B3bcC1bD1a972dc186A2cf84cC6da6Be5D,
                quoter: 0x572B9cDBcd8c2b8F3Fe849B9d250F35284455d7f,
                stateView: 0xc199F1072a74D4e905ABa1A84d9a45E2546B6222,
                permit2: PERMIT2
            });
        }
        revert UnsupportedChain(chainId);
    }

    function isSupported(uint256 chainId) internal pure returns (bool) {
        return chainId == UNICHAIN || chainId == UNICHAIN_SEPOLIA;
    }
}
