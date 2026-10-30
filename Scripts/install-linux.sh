#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${HOME}/.local"
BIN_DIR="${PREFIX}/bin"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
RELEASE_BIN="${REPO_DIR}/.build/release/headbridge"
REPO_SERVICE="${REPO_DIR}/systemd/headbridge.service"

echo "==> Building HeadBridge release binary in ${REPO_DIR}..."
(cd "${REPO_DIR}" && swift build -c release)

echo "==> Creating directories..."
mkdir -p "${BIN_DIR}"
mkdir -p "${SYSTEMD_USER_DIR}"

echo "==> Symlinking binary to ${BIN_DIR}/headbridge..."
ln -sf "${RELEASE_BIN}" "${BIN_DIR}/headbridge"

echo "==> Symlinking systemd user service to ${SYSTEMD_USER_DIR}/headbridge.service..."
ln -sf "${REPO_SERVICE}" "${SYSTEMD_USER_DIR}/headbridge.service"

echo "==> Reloading and enabling systemd user service..."
systemctl --user daemon-reload
systemctl --user enable --now headbridge.service

echo ""
echo "HeadBridge installed via symlinks and service started successfully!"
echo "Binary symlink:  ${BIN_DIR}/headbridge -> ${RELEASE_BIN}"
echo "Service symlink: ${SYSTEMD_USER_DIR}/headbridge.service -> ${REPO_SERVICE}"
echo ""
echo "Try running:"
echo "  headbridge status"
echo "  headbridge anc"
echo "  headbridge devices"
