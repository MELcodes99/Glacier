#!/usr/bin/env bash
# Read-only: find Chainlink feeds + USDC pools for INTCc, CRCLc, ANTc.
set -u
USDC=0x833589fcd6edb6e08f4c7c32d4f71b54bda02913

echo "== Chainlink feeds on Base (Coinbase tokenized equities)"
curl -s "https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-base-1.json" -o /tmp/base-feeds.json
python3 - <<'PY'
import json
feeds = json.load(open('/tmp/base-feeds.json'))
keys = ('INTC', 'INTEL', 'CRCL', 'CIRCLE', 'ANT', 'ANTHROPIC')
for f in feeds:
    name = (f.get('name') or '') + ' ' + (f.get('assetName') or '')
    up = name.upper()
    if 'COINBASE' in up or any(k in up.split() or (k + ' ') in up or ('/' + k) in up or (k + '/') in up for k in keys):
        print(f"{f.get('name'):<28} proxy={f.get('proxyAddress')}  dec={f.get('decimals')}  heartbeat={f.get('heartbeat')}")
PY

echo ""
echo "== API nav_price (from stocks.json)"
python3 -c "
import json
for t in json.load(open('stocks.json'))['tokens']:
    if t['symbol'] in ('INTCc','CRCLc','ANTc'):
        print(t['symbol'], t['contract_address'], 'nav_price=', t.get('nav_price'), 'multiplier=', t.get('multiplier'))
"

echo ""
echo "== Deepest USDC pools (DexScreener)"
for T in 0xB2000000000000000000004AFF16039bA04bdFBc 0xB20000000000000000000019f6E7C675b73C2e4D 0xb20000000000000000000016e38FD364d271Ba28; do
  curl -s "https://api.dexscreener.com/latest/dex/tokens/$T" | python3 -c "
import sys, json
d = json.load(sys.stdin); usdc = '$USDC'
ps = [p for p in (d.get('pairs') or []) if p.get('chainId') == 'base']
ps = [p for p in ps if usdc in (p['baseToken']['address'].lower(), p['quoteToken']['address'].lower())]
ps.sort(key=lambda p: -(p.get('liquidity') or {}).get('usd', 0))
sym = next((p['baseToken']['symbol'] if p['baseToken']['address'].lower()=='$T'.lower() else p['quoteToken']['symbol'] for p in ps), '$T')
print(sym)
for p in ps[:3]:
    print(f\"   {p.get('dexId'):<10} {','.join(p.get('labels') or []):<4} liq=\${(p.get('liquidity') or {}).get('usd',0):>10,.0f}  id={p['pairAddress']}\")
if not ps: print('   no USDC pools found')
"
done
