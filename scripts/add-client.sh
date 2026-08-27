#!/usr/bin/env bash
# Run ON the monitoring server — register a client VM for metrics + print/run agent install.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NODES_JSON="${NODES_JSON:-$REPO_ROOT/file_sd/nodes.json}"
MONITORING_IP="${MONITORING_IP:-10.0.3.146}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://127.0.0.1:9090}"

IP=""
ENVIRONMENT="Staging"
SERVICE_JOB=""
INSTANCE_ID=""
ROLE="app"
PM2_USER="ubuntu"
INSTALL_SSH=""
SKIP_INSTALL=0

usage() {
  cat <<EOF
Usage: $0 --ip IP --service-job NAME --instance-id i-xxx [options]

Register a client VM in file_sd/nodes.json (Prometheus metrics) and optionally
install Node Exporter + Promtail on the client (PM2 + Docker logs → Loki).

Required:
  --ip IP                 Client private IP (Node Exporter target)
  --service-job NAME      Service name (maps to Grafana "Service" / Prometheus job)
  --instance-id ID        EC2 instance id (maps to Grafana "VM")

Options:
  --environment ENV       Staging | Production | Release | Development  (default: Staging)
  --role ROLE             app | client | db  (default: app)
  --pm2-user USER         Linux user running PM2 (default: ubuntu)
  --install-ssh USER@HOST SSH to client and run install-client-monitoring.sh
  --skip-install          Only update nodes.json, do not install agents
  --monitoring-ip IP      Monitoring server IP for client agents (default: $MONITORING_IP)

After registration Prometheus reloads in ~30s. Grafana dropdowns update automatically.

Example:
  $0 --ip 10.0.3.173 \\
     --service-job stg-dogpack-job-service-01 \\
     --instance-id i-0c79fe4d36153a983 \\
     --install-ssh ubuntu@10.0.3.173
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip) IP="$2"; shift 2 ;;
    --environment) ENVIRONMENT="$2"; shift 2 ;;
    --service-job) SERVICE_JOB="$2"; shift 2 ;;
    --instance-id) INSTANCE_ID="$2"; shift 2 ;;
    --role) ROLE="$2"; shift 2 ;;
    --pm2-user) PM2_USER="$2"; shift 2 ;;
    --install-ssh) INSTALL_SSH="$2"; shift 2 ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    --monitoring-ip) MONITORING_IP="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "$IP" || -z "$SERVICE_JOB" || -z "$INSTANCE_ID" ]]; then
  echo "Error: --ip, --service-job, and --instance-id are required."
  echo ""
  usage
  exit 1
fi

if [[ ! -f "$NODES_JSON" ]]; then
  echo "Error: $NODES_JSON not found."
  exit 1
fi

TARGET="${IP}:9100"
echo "== Updating $NODES_JSON =="
python3 - "$NODES_JSON" "$TARGET" "$ENVIRONMENT" "$SERVICE_JOB" "$INSTANCE_ID" "$ROLE" <<'PY'
import json
import sys

path, target, environment, service_job, instance_id, role = sys.argv[1:7]
with open(path) as f:
    nodes = json.load(f)

entry = {
    "targets": [target],
    "labels": {
        "environment": environment,
        "service_job": service_job,
        "instance_id": instance_id,
        "role": role,
    },
}

for i, node in enumerate(nodes):
    labels = node.get("labels", {})
    if labels.get("instance_id") == instance_id or target in node.get("targets", []):
        nodes[i] = entry
        break
else:
    nodes.append(entry)

with open(path, "w") as f:
    json.dump(nodes, f, indent=2)
    f.write("\n")

print(f"Registered {target} → job={service_job}, instance={instance_id}, env={environment}")
PY

if curl -sf -X POST "$PROMETHEUS_URL/-/reload" >/dev/null 2>&1; then
  echo "Prometheus config reloaded."
else
  echo "Prometheus reload skipped (will pick up nodes.json within 30s)."
fi

if [[ "$SKIP_INSTALL" -eq 0 && -n "$INSTALL_SSH" ]]; then
  echo ""
  echo "== Installing agents on $INSTALL_SSH =="
  scp -q "$SCRIPT_DIR/install-client-monitoring.sh" "${INSTALL_SSH}:/tmp/"
  ssh "$INSTALL_SSH" "sudo MONITORING_IP='${MONITORING_IP}' \
    ENVIRONMENT='${ENVIRONMENT}' \
    SERVICE_JOB='${SERVICE_JOB}' \
    INSTANCE_ID='${INSTANCE_ID}' \
    PM2_USER='${PM2_USER}' \
    bash /tmp/install-client-monitoring.sh"
elif [[ "$SKIP_INSTALL" -eq 0 ]]; then
  echo ""
  echo "== Run on the client VM (copy scripts first, or use --install-ssh) =="
  cat <<EOF
sudo MONITORING_IP=${MONITORING_IP} \\
     ENVIRONMENT=${ENVIRONMENT} \\
     SERVICE_JOB=${SERVICE_JOB} \\
     INSTANCE_ID=${INSTANCE_ID} \\
     PM2_USER=${PM2_USER} \\
     bash scripts/install-client-monitoring.sh
EOF
  echo ""
  echo "Security groups:"
  echo "  Client SG: allow TCP 9100 from ${MONITORING_IP} (metrics)"
  echo "  Monitoring SG: allow TCP 3100 from ${IP} (logs → Loki)"
fi

echo ""
echo "== Verify (after ~1 min) =="
echo "  curl -sG '${PROMETHEUS_URL}/api/v1/query' --data-urlencode 'query=up{instance=\"${INSTANCE_ID}\",job=\"${SERVICE_JOB}\"}'"
echo "  bash scripts/verify-loki-pm2.sh ${ENVIRONMENT} ${INSTANCE_ID}"
echo ""
echo "Grafana dashboards update automatically:"
echo "  Dogpackapp Resources → Environment=${ENVIRONMENT}, Service=${SERVICE_JOB}, VM=${INSTANCE_ID}"
echo "  PM2 Application Logs → same filters"
