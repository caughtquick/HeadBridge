#!/bin/bash
set -euo pipefail

PREFIX="${HOME}/.local"
BIN_DIR="${PREFIX}/bin"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
SERVICE_FILE="${SYSTEMD_USER_DIR}/headbridge.service"

echo "==> Building HeadBridge release binary..."
swift build -c release

echo "==> Installing binary to ${BIN_DIR}/headbridge..."
mkdir -p "${BIN_DIR}"
install -m 755 .build/release/headbridge "${BIN_DIR}/headbridge"

echo "==> Setting up systemd user service..."
mkdir -p "${SYSTEMD_USER_DIR}"
cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=HeadBridge Bluetooth Headphone Daemon
After=bluetooth.target pipewire.service wireplumber.service

[Service]
ExecStart=%h/.local/bin/headbridge daemon
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF

echo "==> Reloading and enabling systemd user service..."
systemctl --user daemon-reload
systemctl --user enable --now headbridge.service

echo ""
echo "HeadBridge installed and service started successfully!"
echo "Binary:  ${BIN_DIR}/headbridge"
echo "Service: headbridge.service"
echo ""
echo "Try running:"
echo "  headbridge status"
echo "  headbridge anc"
echo "  headbridge eq"
