#!/usr/bin/env bash
# Run ON the client server (staging/production app VM with PM2).
# Ships PM2 logs to Loki on the central monitoring server.
set -euo pipefail

MONITORING_IP="${MONITORING_IP:-10.0.3.146}"
ENVIRONMENT="${ENVIRONMENT:-Staging}"
SERVICE_JOB="${SERVICE_JOB:-}"
INSTANCE_ID="${INSTANCE_ID:-}"
PM2_USER="${PM2_USER:-ubuntu}"
SKIP_PM2="${SKIP_PM2:-0}"
PROMTAIL_VERSION="${PROMTAIL_VERSION:-2.9.8}"
ARCH="linux-amd64"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/promtail"

if [[ $(uname -m) != "x86_64" ]]; then
  echo "This script targets linux-amd64. Download the matching Promtail binary for your architecture."
  exit 1
fi

PM2_LOG_DIR="$(eval echo "~${PM2_USER}")/.pm2/logs"
HAS_PM2=0
if [[ -d "$PM2_LOG_DIR" ]]; then
  HAS_PM2=1
elif [[ "$SKIP_PM2" == "1" ]]; then
  :
else
  echo "PM2 log directory not found: $PM2_LOG_DIR"
  echo "Set PM2_USER if PM2 runs under a different user, or SKIP_PM2=1 if this host has no PM2."
  exit 1
fi

HAS_DOCKER=0
if [[ -S /var/run/docker.sock ]] && command -v docker &>/dev/null; then
  HAS_DOCKER=1
fi

if [[ "$HAS_PM2" -eq 0 && "$HAS_DOCKER" -eq 0 ]]; then
  echo "Nothing to ship: no PM2 logs and no Docker. Install PM2 or Docker first."
  exit 1
fi

if [[ -z "$INSTANCE_ID" ]]; then
  INSTANCE_ID="$(curl -sf --connect-timeout 1 http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || true)"
fi
HOSTNAME="$(hostname -s 2>/dev/null || hostname)"

id -u promtail &>/dev/null || useradd --no-create-home --shell /usr/sbin/nologin promtail

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
curl -fL --retry 3 -o promtail.zip \
  "https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-${ARCH}.zip"
unzip -q promtail.zip
install -m 0755 "promtail-${ARCH}" "$INSTALL_DIR/promtail"

mkdir -p "$CONFIG_DIR"

cat >"$CONFIG_DIR/config.yml" <<EOF
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
  cat >>"$CONFIG_DIR/config.yml" <<EOF
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
      - regex:
          expression: '(?i)"level"\\s*:\\s*"(?P<level>error|warn|info|debug|trace|fatal)"'
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
  cat >>"$CONFIG_DIR/config.yml" <<EOF

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
      - source_labels: [__meta_docker_container_label_com_docker_compose_project]
        target_label: compose_project
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
  echo "Docker detected — Promtail will ship container logs (job=docker)."
fi

mkdir -p /var/lib/promtail
chown -R promtail:promtail /var/lib/promtail

usermod -aG "$(id -gn "$PM2_USER")" promtail 2>/dev/null || true
chmod -R g+rX "$PM2_LOG_DIR" 2>/dev/null || true

cat <<UNIT >/etc/systemd/system/promtail.service
[Unit]
Description=Promtail log shipper (PM2 → Loki)
Wants=network-online.target
After=network-online.target

[Service]
User=promtail
Group=promtail
Type=simple
Restart=on-failure
RestartSec=5
ExecStart=${INSTALL_DIR}/promtail -config.file=${CONFIG_DIR}/config.yml

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now promtail
systemctl status promtail --no-pager

echo ""
if [[ "$HAS_PM2" -eq 1 ]]; then
  echo "Promtail is shipping PM2 logs from ${PM2_LOG_DIR} to http://${MONITORING_IP}:3100"
fi
if [[ "$HAS_DOCKER" -eq 1 ]]; then
  echo "Docker container logs are also shipped (job=docker)."
fi
echo "Grafana dashboards (filters match Dogpackapp Resources):"
echo "  Environment=${ENVIRONMENT}, Service=${SERVICE_JOB}, VM=${INSTANCE_ID}"
