#!/bin/bash
set -euo pipefail

PREFIX="${HOME}/.local"
BIN_DIR="${PREFIX}/bin"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
SERVICE_LINK="${SYSTEMD_USER_DIR}/headbridge.service"
BIN_LINK="${BIN_DIR}/headbridge"

echo "==> Stopping and disabling HeadBridge systemd user service..."
systemctl --user stop headbridge.service 2>/dev/null || true
systemctl --user disable headbridge.service 2>/dev/null || true

echo "==> Removing symlinks..."
if [ -L "${BIN_LINK}" ] || [ -f "${BIN_LINK}" ]; then
    rm -f "${BIN_LINK}"
    echo "Removed: ${BIN_LINK}"
fi

if [ -L "${SERVICE_LINK}" ] || [ -f "${SERVICE_LINK}" ]; then
    rm -f "${SERVICE_LINK}"
    echo "Removed: ${SERVICE_LINK}"
fi

echo "==> Reloading systemd user daemon..."
systemctl --user daemon-reload
systemctl --user reset-failed 2>/dev/null || true

echo ""
echo "HeadBridge has been successfully uninstalled."
