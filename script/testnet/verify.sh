#!/usr/bin/env bash
# Verifies a testnet deployment's contracts on Sourcify and Blockscout, which need no API key.
# The factory deploys the implementation and the engine from its constructor, so each is verified on its own.
# The hook is a clone of the implementation: explorers show it as a proxy.
#
# Usage: script/testnet/verify.sh [deployments/unichain-sepolia.json]
set -euo pipefail

file=${1:-deployments/unichain-sepolia.json}
chain=$(jq -r .chainId "$file")
pool_manager=$(jq -r .poolManager "$file")
max_ops=$(jq -r .maxOpsPerSwap "$file")
blockscout=https://unichain-sepolia.blockscout.com/api/

verify() { # address, contract, constructor args
  forge verify-contract --chain "$chain" --verifier sourcify --watch "$1" "$2" --constructor-args "$3" ||
    echo "warning: Sourcify failed for $2"
  forge verify-contract --chain "$chain" --verifier blockscout --verifier-url "$blockscout" --watch "$1" "$2" \
    --constructor-args "$3" || echo "warning: Blockscout failed for $2"
}

verify "$(jq -r .tokens.base "$file")" script/testnet/TestToken.sol:TestToken \
  "$(cast abi-encode 'c(string,string,uint8)' 'TickTock Test WETH' tWETH 18)"
verify "$(jq -r .tokens.quote "$file")" script/testnet/TestToken.sol:TestToken \
  "$(cast abi-encode 'c(string,string,uint8)' 'TickTock Test USDC' tUSDC 6)"
verify "$(jq -r .factory "$file")" src/TickTockFactory.sol:TickTockFactory \
  "$(cast abi-encode 'c(address,uint16)' "$pool_manager" "$max_ops")"
verify "$(jq -r .implementation "$file")" src/TickTockHook.sol:TickTockHook \
  "$(cast abi-encode 'c(address,uint16)' "$pool_manager" "$max_ops")"
verify "$(jq -r .engine "$file")" src/TickTockEngine.sol:TickTockEngine \
  "$(cast abi-encode 'c(address)' "$pool_manager")"
