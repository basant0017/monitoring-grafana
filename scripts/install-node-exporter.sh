#!/usr/bin/env bash
# Run ON the client server (SSH in as root or use sudo). Tested on Ubuntu/Debian/RHEL-like x86_64.
set -euo pipefail

VERSION="${NODE_EXPORTER_VERSION:-v1.11.1}"
ARCH="linux-amd64"
URL="https://github.com/prometheus/node_exporter/releases/download/${VERSION}/node_exporter-${VERSION#v}.${ARCH}.tar.gz"
INSTALL_DIR="/usr/local/bin"
USER_NAME="node_exporter"

if [[ $(uname -m) != "x86_64" ]]; then
  echo "This script targets linux-amd64. For ARM, set ARCH and download the matching release asset from GitHub."
  exit 1
fi

id -u "$USER_NAME" &>/dev/null || useradd --no-create-home --shell /usr/sbin/nologin "$USER_NAME"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
curl -fL --retry 3 -o node_exporter.tgz "$URL"
tar xzf node_exporter.tgz
install -m 0755 "node_exporter-${VERSION#v}.${ARCH}/node_exporter" "$INSTALL_DIR/node_exporter"

cat <<'UNIT' >/etc/systemd/system/node_exporter.service
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
systemctl status node_exporter --no-pager

echo ""
echo "Node Exporter is listening on :9100. From your monitoring host, test:"
echo "  curl -sS http://$(hostname -I | awk '{print $1}'):9100/metrics | head"
