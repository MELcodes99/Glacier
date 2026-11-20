#!/usr/bin/env bash
set -u
RPC="${BASE_RPC_URL:-https://mainnet.base.org}"
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
AERO=0x9CB220581b91b0C83223012FE69688b92aD07a76
# symbol token feed pool nav
ROWS=(
  "INTCc 0xB2000000000000000000004AFF16039bA04bdFBc 0xAB657C39bac0D5886250D70849e2E3E008F2EECB 0x3D384288fA79B51De882B06B617aB7989CcAd4f3 53.39"
  "CRCLc 0xB20000000000000000000019f6E7C675b73C2e4D 0x0231cF2635D1E17bB5c2462cc7504Ba1fBd61f33 0x294666AD6a415E8C33Af801225c04079BB4f1133 50.795"
  "ANTc 0xb20000000000000000000016e38FD364d271Ba28 0xeEDc7412E991a3F2BD693eb2aC7fB0F27d4660dA 0x599C4225FE90214795a0be228D20d7680f8CED15 85.21"
)
c() { cast call "$@" --rpc-url "$RPC" 2>&1 | head -1 | awk '{print $1}'; }
for row in "${ROWS[@]}"; do
  set -- $row
  SYM=$1; TOKEN=$2; FEED=$3; POOL=$4; NAV=$5
  ANSWER=$(cast call "$FEED" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url "$RPC" | sed -n 2p | awk '{print $1}')
  UPDATED=$(cast call "$FEED" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url "$RPC" | sed -n 4p | awk '{print $1}')
  echo "== $SYM"
  echo "  feed price      : $(python3 -c "print($ANSWER/1e8)")  (API nav $NAV)  age: $(( $(date +%s) - UPDATED ))s"
  echo "  token decimals  : $(c $TOKEN 'decimals()(uint8)')"
  echo "  pool factory    : $(c $POOL 'factory()(address)')  (want $AERO)"
  echo "  pool tokens     : $(c $POOL 'token0()(address)') / $(c $POOL 'token1()(address)')"
  TS=$(c $POOL 'tickSpacing()(int24)')
  echo "  getPool matches : $( [ "$(c $AERO 'getPool(address,address,int24)(address)' $USDC $TOKEN $TS | tr A-F a-f)" = "$(echo $POOL | tr A-F a-f)" ] && echo yes || echo NO )"
  echo "  USDC in pool    : $(python3 -c "print(f'\${$(c $USDC 'balanceOf(address)(uint256)' $POOL)/1e6:,.0f}')")"
  SQRT=$(c $POOL 'slot0()(uint160,int24,uint16,uint16,uint16,bool)')
  echo "  pool price      : $(python3 -c "s=$SQRT/2**96; print(round(100/(s*s),2))")"
done
