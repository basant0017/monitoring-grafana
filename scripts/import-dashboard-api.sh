#!/usr/bin/env bash
# Import dogpackapp-resources.json via Grafana HTTP API (when file provisioning is not used).
# Usage:
#   export GRAFANA_URL=http://127.0.0.1:3000
#   export GRAFANA_USER=admin
#   export GRAFANA_PASSWORD='yourpassword'
#   ./scripts/import-dashboard-api.sh
set -euo pipefail
BASE="$(cd "$(dirname "$0")/.." && pwd)"
URL="${GRAFANA_URL:-http://127.0.0.1:3000}"
USER="${GRAFANA_USER:-admin}"
PASS="${GRAFANA_PASSWORD:?set GRAFANA_PASSWORD}"
JSON="${BASE}/grafana/provisioning/dashboards/json/dogpackapp-resources.json"

# Grafana expects { dashboard, overwrite }; strip read-only export fields if needed
BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT
jq '{dashboard: (. | del(.id) | del(.version)), overwrite: true}' "${JSON}" >"$BODY"

curl -fsS -u "${USER}:${PASS}" \
  -H "Content-Type: application/json" \
  -X POST \
  --data @"${BODY}" \
  "${URL}/api/dashboards/db"

echo ""
echo "OK — open ${URL}/d/rYdddlPWj (or search: Dogpackapp Resources)"
