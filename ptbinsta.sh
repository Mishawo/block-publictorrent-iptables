#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/Mishawo/block-publictorrent-iptables.git"
INSTALL_DIR="/opt/block-publictorrent-iptables"

log() { echo "[+] $*"; }
err() { echo "[!] $*" >&2; }

# Must run as root
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  err "Please run as root. Example: sudo bash install.sh"
  exit 1
fi

log "Updating apt cache..."
apt update -y

log "Installing dependencies (git)..."
apt install -y git

# Optional: you can add these if you want, but keeping minimal to match your proven steps:
# apt install -y curl wget dnsutils iptables || true

log "Preparing install directory: $INSTALL_DIR"
rm -rf "$INSTALL_DIR"

log "Cloning repo..."
git clone "$REPO_URL" "$INSTALL_DIR"

log "Setting executable permissions..."
cd "$INSTALL_DIR"
chmod +x ./*.sh

# Ensure required scripts exist
if [[ ! -f "./bt.sh" ]]; then
  err "bt.sh not found after clone. Repo content is unexpected."
  exit 1
fi

log "Running bt.sh..."
./bt.sh

# OPTIONAL: auto-open menu after install
# If you want install to end without opening menu, comment this out.
if [[ -f "./bmenu.sh" ]]; then
  log "Launching bmenu.sh..."
  ./bmenu.sh
else
  err "bmenu.sh not found. Install finished, but menu script is missing."
fi

log "Done."
