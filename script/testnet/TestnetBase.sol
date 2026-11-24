// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {DeployBase} from "../DeployBase.sol";

/// @notice What the testnet scripts share: the deployment file `DeployTestnet` writes, and the signer.
/// @dev The signer is PRIVATE_KEY, the testnet-only key in `.env`. DEPLOYMENT overrides the file's path.
abstract contract TestnetBase is DeployBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct Testnet {
        address hook;
        address universalRouter;
        address permit2;
        /// The pair's base token (tWETH) and quote token (tUSDC), and the starting price in whole quote per base.
        address base;
        address quote;
        uint256 price;
        PoolKey key;
    }

    function deploymentPath() public view returns (string memory) {
        return vm.envOr("DEPLOYMENT", string("deployments/unichain-sepolia.json"));
    }

    function _load() internal view returns (Testnet memory t) {
        string memory json = vm.readFile(deploymentPath());
        t.hook = vm.parseJsonAddress(json, ".hook");
        t.universalRouter = vm.parseJsonAddress(json, ".universalRouter");
        t.permit2 = vm.parseJsonAddress(json, ".permit2");
        t.base = vm.parseJsonAddress(json, ".tokens.base");
        t.quote = vm.parseJsonAddress(json, ".tokens.quote");
        t.price = vm.parseJsonUint(json, ".price");
        t.key = PoolKey({
            currency0: Currency.wrap(vm.parseJsonAddress(json, ".pool.currency0")),
            currency1: Currency.wrap(vm.parseJsonAddress(json, ".pool.currency1")),
            fee: uint24(vm.parseJsonUint(json, ".pool.fee")),
            tickSpacing: int24(vm.parseJsonInt(json, ".pool.tickSpacing")),
            hooks: IHooks(t.hook)
        });
    }

    function _signer() internal view returns (uint256 privateKey, address account) {
        privateKey = vm.envUint("PRIVATE_KEY");
        account = vm.addr(privateKey);
    }

    function _tick(PoolKey memory key) internal view returns (int24 tick) {
        (, tick,,) = IPoolManager(poolManager()).getSlot0(key.toId());
    }
}
