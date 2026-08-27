#!/usr/bin/env bash
# Run on the monitoring server to verify Docker logs reach Loki.
set -euo pipefail

LOKI="${LOKI_URL:-http://127.0.0.1:3100}"
ENV="${1:-Staging}"
HOST="${2:-}"

echo "== Loki ready =="
curl -sf "$LOKI/ready" && echo " OK"

echo ""
echo "== Labels =="
curl -s "$LOKI/loki/api/v1/labels" | python3 -m json.tool 2>/dev/null || curl -s "$LOKI/loki/api/v1/labels"

for label in environment host container compose_service stream; do
  echo ""
  echo "== label/$label values =="
  curl -sG "$LOKI/loki/api/v1/label/$label/values" \
    --data-urlencode 'query={job="docker"}' | python3 -m json.tool 2>/dev/null || true
done

QUERY="{job=\"docker\", environment=\"$ENV\"}"
if [[ -n "$HOST" ]]; then
  QUERY="{job=\"docker\", environment=\"$ENV\", host=\"$HOST\"}"
fi

echo ""
echo "== Sample log lines (query: $QUERY) =="
END=$(python3 -c 'import time; print(int(time.time()*1e9))')
START=$(python3 -c 'import time; print(int((time.time()-3600)*1e9))')
curl -sG "$LOKI/loki/api/v1/query_range" \
  --data-urlencode "query=$QUERY" \
  --data-urlencode "limit=5" \
  --data-urlencode "start=$START" \
  --data-urlencode "end=$END" | python3 -c "
import sys, json
d = json.load(sys.stdin)
results = d.get('data', {}).get('result', [])
print(f'streams: {len(results)}')
for s in results[:3]:
    labels = s.get('stream', {})
    print('labels:', labels)
    for line in s.get('values', [])[:2]:
        print(' ', line[1][:120])
" 2>/dev/null || echo "No log lines in last 1h — start Promtail on monitoring server or client VM"
