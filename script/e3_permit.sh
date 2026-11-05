#!/usr/bin/env bash
# Bonus E3: a permit signed OUTSIDE Solidity, with `cast wallet sign --data`,
# and submitted to a local anvil node with `cast send`.
#
#     bash script/e3_permit.sh | tee evidence/e3_permit.txt
#
# The keys are anvil's built-in development keys (public, for local use only).
set -euo pipefail
cd "$(dirname "$0")/.."

RPC=http://127.0.0.1:8545
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # anvil #0
OWNER_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d      # anvil #1
SPENDER_KEY=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a    # anvil #2
DEPLOYER=$(cast wallet address --private-key $DEPLOYER_KEY)
OWNER=$(cast wallet address --private-key $OWNER_KEY)
SPENDER=$(cast wallet address --private-key $SPENDER_KEY)
WORK=$(mktemp -d)

anvil --silent --port 8545 &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null; rm -rf "$WORK"' EXIT
until cast chain-id --rpc-url $RPC >/dev/null 2>&1; do sleep 0.2; done

step() { printf '\n== %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; }

step "accounts"
echo "deployer/admin : $DEPLOYER"
echo "owner          : $OWNER   (signs, never sends a transaction)"
echo "spender        : $SPENDER   (submits the permit and pays its gas)"
echo "chain id       : $(cast chain-id --rpc-url $RPC)"

step "1. deploy with forge script"
PRIVATE_KEY=$DEPLOYER_KEY TREASURY_ADDRESS=$DEPLOYER \
  forge script script/Deploy.s.sol --rpc-url $RPC --broadcast 2>&1 \
  | grep -E "CampusToken:|admin|treasury|cap|ONCHAIN EXECUTION COMPLETE"
TOKEN=$(jq -r '.transactions[0].contractAddress' broadcast/Deploy.s.sol/31337/run-latest.json)
TOKEN=$(cast to-check-sum-address "$TOKEN")
echo "token          : $TOKEN"

step "2. mint 1000 CMPS to the owner"
cast send --rpc-url $RPC --private-key $DEPLOYER_KEY $TOKEN "mint(address,uint256)" $OWNER 1000ether >/dev/null
run cast call --rpc-url $RPC $TOKEN "balanceOf(address)(uint256)" $OWNER
echo "owner's ETH spent so far: none -- nonce of the owner = $(cast nonce --rpc-url $RPC $OWNER)"

VALUE=250000000000000000000          # 250 CMPS, as a decimal string: too big for a JSON number
NONCE=$(cast call --rpc-url $RPC $TOKEN "nonces(address)(uint256)" $OWNER)
DEADLINE=$(( $(cast block latest --rpc-url $RPC --field timestamp) + 3600 ))

typed_data() { # $1 = version string written into the domain
cat <<JSON
{
  "types": {
    "EIP712Domain": [
      {"name": "name", "type": "string"},
      {"name": "version", "type": "string"},
      {"name": "chainId", "type": "uint256"},
      {"name": "verifyingContract", "type": "address"}
    ],
    "Permit": [
      {"name": "owner", "type": "address"},
      {"name": "spender", "type": "address"},
      {"name": "value", "type": "uint256"},
      {"name": "nonce", "type": "uint256"},
      {"name": "deadline", "type": "uint256"}
    ]
  },
  "primaryType": "Permit",
  "domain": {
    "name": "Campus Token",
    "version": "$1",
    "chainId": 31337,
    "verifyingContract": "$TOKEN"
  },
  "message": {
    "owner": "$OWNER",
    "spender": "$SPENDER",
    "value": "$VALUE",
    "nonce": $NONCE,
    "deadline": $DEADLINE
  }
}
JSON
}

decode() { # print the revert reason of a failed cast send
  local data
  data=$(grep -oE 'custom error 0x[0-9a-f]{8}: [0-9a-f]+' "$1" | head -1 | sed -E 's/custom error (0x[0-9a-f]{8}): /\1/')
  echo "reverted with selector ${data:0:10} = $(cast 4byte-decode "$data" 2>/dev/null | head -1 | sed "s/^1) //" || true)"
  echo "  InvalidPermitSigner(address,address) has selector $(cast sig 'InvalidPermitSigner(address,address)')"
  cast decode-error --sig 'InvalidPermitSigner(address,address)' "$data" | sed 's/^/  /'
}

split() { # 65-byte signature r || s || v  ->  "v r s"
  local sig=${1#0x}
  echo "$((16#${sig:128:2})) 0x${sig:0:64} 0x${sig:64:64}"
}

step "3. the typed data I sign (EIP-712)"
typed_data 1 | tee "$WORK/permit.json"

step "4. a deliberately wrong domain first: version \"1.0\" instead of \"1\""
typed_data 1.0 >"$WORK/wrong.json"
WRONG=$(cast wallet sign --data --from-file "$WORK/wrong.json" --private-key $OWNER_KEY)
read -r V R S <<<"$(split "$WRONG")"
echo "signature: $WRONG"
if cast send --rpc-url $RPC --private-key $SPENDER_KEY $TOKEN \
     "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)" \
     $OWNER $SPENDER $VALUE $DEADLINE $V $R $S >"$WORK/out" 2>&1; then
  echo "unexpected: accepted"; exit 1
else
  decode "$WORK/out"
  echo "  (recovered signer, claimed owner): the digest differs, so ecrecover gives an unrelated address"
fi

step "5. sign the correct typed data with cast"
SIG=$(cast wallet sign --data --from-file "$WORK/permit.json" --private-key $OWNER_KEY)
read -r V R S <<<"$(split "$SIG")"
echo "signature: $SIG"
echo "v = $V"; echo "r = $R"; echo "s = $S"
echo "DOMAIN_SEPARATOR() on chain: $(cast call --rpc-url $RPC $TOKEN 'DOMAIN_SEPARATOR()(bytes32)')"
echo "cast's own check           : $(cast wallet verify --data --from-file "$WORK/permit.json" --address $OWNER $SIG 2>&1 | head -1)"

step "6. the spender submits permit with cast send"
cast send --rpc-url $RPC --private-key $SPENDER_KEY $TOKEN \
  "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)" \
  $OWNER $SPENDER $VALUE $DEADLINE $V $R $S | grep -E "^status|^gasUsed|^transactionHash"

step "7. results"
run cast call --rpc-url $RPC $TOKEN "allowance(address,address)(uint256)" $OWNER $SPENDER
run cast call --rpc-url $RPC $TOKEN "nonces(address)(uint256)" $OWNER
echo "transactions sent by the owner: $(cast nonce --rpc-url $RPC $OWNER)"

step "8. resubmitting the same signature"
if cast send --rpc-url $RPC --private-key $SPENDER_KEY $TOKEN \
     "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)" \
     $OWNER $SPENDER $VALUE $DEADLINE $V $R $S >"$WORK/out" 2>&1; then
  echo "unexpected: accepted twice"; exit 1
else
  decode "$WORK/out"
  echo "  the nonce is now 1, so the digest is built with nonce 1 and the old signature no longer matches"
fi

step "9. the spender uses the allowance"
cast send --rpc-url $RPC --private-key $SPENDER_KEY $TOKEN \
  "transferFrom(address,address,uint256)" $OWNER $SPENDER 100ether | grep -E "^status"
run cast call --rpc-url $RPC $TOKEN "balanceOf(address)(uint256)" $SPENDER
run cast call --rpc-url $RPC $TOKEN "allowance(address,address)(uint256)" $OWNER $SPENDER
