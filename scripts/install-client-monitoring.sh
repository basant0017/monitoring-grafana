#!/usr/bin/env bash
#
# ══════════════════════════════════════════════════════════════════
#  STEP 1 — Run this script ONLY on the CLIENT server (sudo).
#  Installs: Node Exporter (:9100) + Promtail (PM2/Docker → Loki)
#
#  STEP 2 — YOU manually add nodes-entry.json to MONITORING server:
#           /opt/monitoring-grafana/monitoring/file_sd/nodes.json
#           Then open Grafana — dashboards update automatically.
# ══════════════════════════════════════════════════════════════════
#
set -euo pipefail

MONITORING_IP="${MONITORING_IP:-10.0.3.146}"
ENVIRONMENT="${ENVIRONMENT:-Staging}"
SERVICE_JOB="${SERVICE_JOB:-}"
INSTANCE_ID="${INSTANCE_ID:-}"
PM2_USER="${PM2_USER:-ubuntu}"
ROLE="${ROLE:-app}"
SKIP_PM2="${SKIP_PM2:-0}"
SKIP_LOGS="${SKIP_LOGS:-0}"
SKIP_METRICS="${SKIP_METRICS:-0}"
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-v1.11.1}"
PROMTAIL_VERSION="${PROMTAIL_VERSION:-2.9.8}"
INSTALL_DIR="/usr/local/bin"
PROMTAIL_CONFIG_DIR="/etc/promtail"
REG_DIR="/etc/dogpack-monitoring"

usage() {
  cat <<'EOF'
Usage: sudo bash install-client-monitoring.sh

  STEP 1  Run on CLIENT server (this script)
  STEP 2  Manually add printed JSON to monitoring server file_sd/nodes.json

Quick start (EC2):
  sudo MONITORING_IP=10.0.3.146 \
       SERVICE_JOB=my-app-service \
       bash install-client-monitoring.sh

Recommended (same labels in nodes.json on monitoring server):
  sudo MONITORING_IP=10.0.3.146 \
       ENVIRONMENT=Staging \
       SERVICE_JOB=stg-dogpack-job-service-01 \
       INSTANCE_ID=i-0c79fe4d36153a983 \
       PM2_USER=ubuntu \
       bash install-client-monitoring.sh

Docker-only (no PM2):
  sudo SKIP_PM2=1 MONITORING_IP=10.0.3.146 SERVICE_JOB=my-docker-app bash install-client-monitoring.sh

Metrics only (no logs):
  sudo SKIP_LOGS=1 MONITORING_IP=10.0.3.146 SERVICE_JOB=my-app bash install-client-monitoring.sh

Environment variables:
  MONITORING_IP   Monitoring server IP          (default: 10.0.3.146)
  ENVIRONMENT     Staging | Production          (default: Staging)
  SERVICE_JOB     Grafana "Service" name        (default: hostname)
  INSTANCE_ID     Grafana "VM" id               (default: EC2 id or hostname)
  PM2_USER        Linux user for PM2            (default: ubuntu)
  ROLE            app | client | db             (default: app)
  SKIP_PM2=1      Skip PM2 logs
  SKIP_LOGS=1     Skip Promtail (metrics only)
  SKIP_METRICS=1  Skip Node Exporter (logs only)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Error: run as root →  sudo bash install-client-monitoring.sh"
  exit 1
fi

echo ""
echo "=========================================="
echo " Dogpackapp — Client Monitoring Install"
echo " STEP 1 of 2  (client server only)"
echo "=========================================="
echo ""

# ── Packages ──────────────────────────────────────────────────────
echo "[1/6] Installing packages (curl, unzip, tar)..."
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y curl unzip tar
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y curl unzip tar
elif command -v yum >/dev/null 2>&1; then
  yum install -y curl unzip tar
else
  echo "Error: unsupported OS. Install curl, unzip, tar manually."
  exit 1
fi

# ── Architecture ──────────────────────────────────────────────────
MACHINE="$(uname -m)"
case "$MACHINE" in
  x86_64)        ARCH="linux-amd64" ;;
  aarch64|arm64) ARCH="linux-arm64" ;;
  *)
    echo "Error: unsupported architecture: $MACHINE"
    exit 1
    ;;
esac
echo "[2/6] Architecture: $MACHINE ($ARCH)"

# ── Identity (must match nodes.json on monitoring server) ───────
HOSTNAME="$(hostname -s 2>/dev/null || hostname)"

CLIENT_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
if [[ -z "$CLIENT_IP" ]]; then
  CLIENT_IP="$(curl -sf --connect-timeout 2 \
    http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null || true)"
fi

[[ -z "$SERVICE_JOB" ]] && SERVICE_JOB="$HOSTNAME"

if [[ -z "$INSTANCE_ID" ]]; then
  INSTANCE_ID="$(curl -sf --connect-timeout 2 \
    http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || true)"
  [[ -z "$INSTANCE_ID" ]] && INSTANCE_ID="$HOSTNAME"
fi

echo "[3/6] Client identity:"
echo "        Private IP   : ${CLIENT_IP:-unknown}"
echo "        Hostname     : $HOSTNAME"
echo "        Environment  : $ENVIRONMENT"
echo "        Service job  : $SERVICE_JOB"
echo "        Instance id  : $INSTANCE_ID"
echo "        Monitoring   : $MONITORING_IP"
echo ""

# ── Detect PM2 / Docker ───────────────────────────────────────────
HAS_PM2=0
PM2_LOG_DIR=""
HAS_DOCKER=0

if [[ "$SKIP_LOGS" == "1" ]]; then
  echo "        Logs         : skipped (SKIP_LOGS=1)"
else
  if [[ "$SKIP_PM2" != "1" ]]; then
    if id "$PM2_USER" >/dev/null 2>&1; then
      PM2_LOG_DIR="$(eval echo "~${PM2_USER}")/.pm2/logs"
      if [[ -d "$PM2_LOG_DIR" ]]; then
        HAS_PM2=1
        echo "        PM2 logs     : $PM2_LOG_DIR"
      else
        echo "        PM2 logs     : not found ($PM2_LOG_DIR)"
        echo "                  → sudo -u $PM2_USER pm2 status"
        echo "                  → or use SKIP_PM2=1 for Docker-only"
        exit 1
      fi
    else
      echo "Error: PM2 user '$PM2_USER' not found. Set PM2_USER or SKIP_PM2=1"
      exit 1
    fi
  else
    echo "        PM2 logs     : skipped (SKIP_PM2=1)"
  fi

  if [[ -S /var/run/docker.sock ]] && command -v docker >/dev/null 2>&1; then
    HAS_DOCKER=1
    echo "        Docker logs  : enabled"
  else
    echo "        Docker logs  : not detected"
  fi

  if [[ "$HAS_PM2" -eq 0 && "$HAS_DOCKER" -eq 0 ]]; then
    echo "Error: no log source. Install PM2/Docker or set SKIP_LOGS=1."
    exit 1
  fi
fi

if [[ "$SKIP_METRICS" == "1" && "$SKIP_LOGS" == "1" ]]; then
  echo "Error: both SKIP_METRICS and SKIP_LOGS are set — nothing to install."
  exit 1
fi

# ── Node Exporter ─────────────────────────────────────────────────
if [[ "$SKIP_METRICS" != "1" ]]; then
  echo ""
  echo "[4/6] Node Exporter (metrics → Prometheus :9100)"
  echo "------------------------------------------"

  id -u node_exporter &>/dev/null || \
    useradd --no-create-home --shell /usr/sbin/nologin node_exporter

  tmp_ne="$(mktemp -d)"
  NE_URL="https://github.com/prometheus/node_exporter/releases/download/${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION#v}.${ARCH}.tar.gz"
  echo "  Download: $NE_URL"
  curl -fL --retry 3 -o "$tmp_ne/node_exporter.tgz" "$NE_URL"
  tar xzf "$tmp_ne/node_exporter.tgz" -C "$tmp_ne"
  install -m 0755 "$tmp_ne/node_exporter-${NODE_EXPORTER_VERSION#v}.${ARCH}/node_exporter" \
    "$INSTALL_DIR/node_exporter"
  rm -rf "$tmp_ne"

  cat >/etc/systemd/system/node_exporter.service <<'UNIT'
[Unit]
Description=Prometheus Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
Restart=on-failure
RestartSec=5
ExecStart=/usr/local/bin/node_exporter --web.listen-address=0.0.0.0:9100

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now node_exporter
  echo "  Status  : $(systemctl is-active node_exporter)"
  "$INSTALL_DIR/node_exporter" --version 2>/dev/null | head -1 || true
else
  echo ""
  echo "[4/6] Node Exporter — skipped (SKIP_METRICS=1)"
fi

# ── Promtail ──────────────────────────────────────────────────────
if [[ "$SKIP_LOGS" != "1" ]]; then
  echo ""
  echo "[5/6] Promtail (logs → Loki at ${MONITORING_IP}:3100)"
  echo "------------------------------------------"

  id -u promtail &>/dev/null || \
    useradd --no-create-home --shell /usr/sbin/nologin promtail

  tmp_pt="$(mktemp -d)"
  cd "$tmp_pt"
  PT_URL="https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-${ARCH}.zip"
  echo "  Download: $PT_URL"
  curl -fL --retry 3 -o promtail.zip "$PT_URL"
  unzip -q promtail.zip
  install -m 0755 "promtail-${ARCH}" "$INSTALL_DIR/promtail"
  cd /
  rm -rf "$tmp_pt"

  mkdir -p "$PROMTAIL_CONFIG_DIR"
  cat >"$PROMTAIL_CONFIG_DIR/config.yml" <<EOF
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /var/lib/promtail/positions.yaml

clients:
  - url: http://${MONITORING_IP}:3100/loki/api/v1/push

scrape_configs:
EOF

  if [[ "$HAS_PM2" -eq 1 ]]; then
    cat >>"$PROMTAIL_CONFIG_DIR/config.yml" <<EOF
  - job_name: pm2-stdout
    static_configs:
      - targets: [localhost]
        labels:
          job: pm2
          environment: ${ENVIRONMENT}
          host: ${HOSTNAME}
          instance_id: ${INSTANCE_ID}
          service_job: ${SERVICE_JOB}
          stream: stdout
          __path__: ${PM2_LOG_DIR}/*-out*.log
    pipeline_stages:
      - regex:
          source: filename
          expression: '.*/(?P<app>[^/]+?)-out(?:-\\d+)?\\.log'
      - labels:
          app:
      - regex:
          expression: '(?i)\\[(?P<level>ERROR|WARN|INFO|DEBUG|TRACE|FATAL)\\]'
      - labels:
          level:

  - job_name: pm2-stderr
    static_configs:
      - targets: [localhost]
        labels:
          job: pm2
          environment: ${ENVIRONMENT}
          host: ${HOSTNAME}
          instance_id: ${INSTANCE_ID}
          service_job: ${SERVICE_JOB}
          stream: stderr
          __path__: ${PM2_LOG_DIR}/*-error*.log
    pipeline_stages:
      - regex:
          source: filename
          expression: '.*/(?P<app>[^/]+?)-error(?:-\\d+)?\\.log'
      - labels:
          app:
      - static_labels:
          level: error
EOF
  fi

  if [[ "$HAS_DOCKER" -eq 1 ]]; then
    cat >>"$PROMTAIL_CONFIG_DIR/config.yml" <<EOF

  - job_name: docker
    docker_sd_configs:
      - host: unix:///var/run/docker.sock
        refresh_interval: 5s
    relabel_configs:
      - source_labels: [__meta_docker_container_name]
        regex: /(.*)
        target_label: container
      - source_labels: [__meta_docker_container_log_stream]
        target_label: stream
      - source_labels: [__meta_docker_container_label_com_docker_compose_service]
        target_label: compose_service
      - target_label: job
        replacement: docker
      - target_label: environment
        replacement: ${ENVIRONMENT}
      - target_label: host
        replacement: ${HOSTNAME}
      - target_label: instance_id
        replacement: ${INSTANCE_ID}
      - target_label: service_job
        replacement: ${SERVICE_JOB}
    pipeline_stages:
      - docker: {}
EOF
    usermod -aG docker promtail 2>/dev/null || true
  fi

  mkdir -p /var/lib/promtail
  chown -R promtail:promtail /var/lib/promtail

  if [[ "$HAS_PM2" -eq 1 ]]; then
    usermod -aG "$(id -gn "$PM2_USER")" promtail 2>/dev/null || true
    chmod -R g+rX "$PM2_LOG_DIR" 2>/dev/null || true
  fi

  cat >/etc/systemd/system/promtail.service <<UNIT
[Unit]
Description=Promtail log shipper (PM2/Docker → Loki)
Wants=network-online.target
After=network-online.target

[Service]
User=promtail
Group=promtail
Type=simple
Restart=on-failure
RestartSec=5
ExecStart=${INSTALL_DIR}/promtail -config.file=${PROMTAIL_CONFIG_DIR}/config.yml

[Install]
WantedBy=multi-user.target
UNIT

  echo "  Validating config..."
  "$INSTALL_DIR/promtail" -config.file="$PROMTAIL_CONFIG_DIR/config.yml" -check-syntax

  systemctl daemon-reload
  systemctl enable --now promtail
  echo "  Status  : $(systemctl is-active promtail)"
  "$INSTALL_DIR/promtail" --version 2>/dev/null | head -1 || true
  sleep 2
  curl -sf http://127.0.0.1:9080/ready >/dev/null && \
    echo "  Ready   : http://127.0.0.1:9080/ready OK" || \
    echo "  Ready   : starting..."
else
  echo ""
  echo "[5/6] Promtail — skipped (SKIP_LOGS=1)"
fi

# ── Save registration file for STEP 2 ─────────────────────────────
echo ""
echo "[6/6] Saving registration info for STEP 2..."
mkdir -p "$REG_DIR"

TARGET_IP="${CLIENT_IP:-YOUR_PRIVATE_IP}"
REG_FILE="$REG_DIR/nodes-entry.json"

cat >"$REG_FILE" <<JSON
{
  "targets": ["${TARGET_IP}:9100"],
  "labels": {
    "environment": "${ENVIRONMENT}",
    "service_job": "${SERVICE_JOB}",
    "instance_id": "${INSTANCE_ID}",
    "role": "${ROLE}"
  }
}
JSON
chmod 644 "$REG_FILE"

cat >"$REG_DIR/STEP2-instructions.txt" <<TXT
STEP 2 — Add this client to monitoring server (manual)

1. SSH to monitoring server: ${MONITORING_IP}
2. Edit file:
     /opt/monitoring-grafana/monitoring/file_sd/nodes.json
3. Paste the JSON from: ${REG_FILE}
   (add comma after previous entry if needed)
4. Wait ~30 seconds — Prometheus reloads automatically
5. Open Grafana: https://grafana-stg.dogpackapp.com
   Filters:
     Environment = ${ENVIRONMENT}
     Service     = ${SERVICE_JOB}
     VM          = ${INSTANCE_ID}

Security groups:
  Client SG       → allow TCP 9100 from ${MONITORING_IP}
  Monitoring SG   → allow TCP 3100 from ${TARGET_IP}

Test from monitoring server:
  curl -s http://${TARGET_IP}:9100/metrics | head
  bash scripts/verify-loki-pm2.sh ${ENVIRONMENT} ${INSTANCE_ID} ${SERVICE_JOB}
TXT
chmod 644 "$REG_DIR/STEP2-instructions.txt"

# ── Final summary ─────────────────────────────────────────────────
echo ""
echo "=========================================="
echo " STEP 1 DONE — Client agents installed"
echo "=========================================="
echo ""
[[ "$SKIP_METRICS" != "1" ]] && \
  echo "  ✓ Node Exporter   :9100  (metrics)" || true
[[ "$SKIP_LOGS" != "1" ]] && \
  echo "  ✓ Promtail        → ${MONITORING_IP}:3100  (logs)" || true
echo ""
echo "  Saved files:"
echo "    $REG_FILE"
echo "    $REG_DIR/STEP2-instructions.txt"
echo ""
echo "=========================================="
echo " STEP 2 — YOU do this on monitoring server"
echo "=========================================="
echo ""
echo "  File : /opt/monitoring-grafana/monitoring/file_sd/nodes.json"
echo ""
echo "  Add this JSON block:"
echo ""
cat "$REG_FILE"
echo ""
echo "  Then Grafana → Environment=${ENVIRONMENT} | Service=${SERVICE_JOB} | VM=${INSTANCE_ID}"
echo ""
echo "=========================================="
echo " Done"
echo "=========================================="
echo ""
