#!/usr/bin/env bash
set -eu
RPC="${BASE_RPC_URL:-https://mainnet.base.org}"
REGISTRY=0x4A68A731741C9253CA6293Dbe1b28078Ac58998b
ROUTER=0x4F854230f990615f91b0Fe73625BDb02299cB3cD
ACCT="--account glacier-deployer --rpc-url $RPC"
# symbol token feed pool
ROWS=(
  "INTCc 0xB2000000000000000000004AFF16039bA04bdFBc 0xAB657C39bac0D5886250D70849e2E3E008F2EECB 0x3D384288fA79B51De882B06B617aB7989CcAd4f3"
  "CRCLc 0xB20000000000000000000019f6E7C675b73C2e4D 0x0231cF2635D1E17bB5c2462cc7504Ba1fBd61f33 0x294666AD6a415E8C33Af801225c04079BB4f1133"
  "ANTc 0xb20000000000000000000016e38FD364d271Ba28 0xeEDc7412E991a3F2BD693eb2aC7fB0F27d4660dA 0x599C4225FE90214795a0be228D20d7680f8CED15"
)
for row in "${ROWS[@]}"; do
  set -- $row
  SYM=$1; TOKEN=$2; FEED=$3; POOL=$4
  echo "== $SYM"
  cast send $ROUTER "setPool(address,address)" $TOKEN $POOL $ACCT | grep -E "^status"
  cast send $REGISTRY "setStock(address,address)" $TOKEN $FEED $ACCT | grep -E "^status"
  echo "  router pool : $(cast call $ROUTER 'poolOf(address)(address)' $TOKEN --rpc-url $RPC)"
  echo "  listed      : $(cast call $REGISTRY 'isListed(address)(bool)' $TOKEN --rpc-url $RPC)"
done
echo ""
echo "listed stocks: $(cast call $REGISTRY 'listedTokens()(address[])' --rpc-url $RPC)"
