#!/bin/bash
# ctp - common torrent port/domain blocking helper
set -euo pipefail

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo -e "\033[31mThis script must be run as root. Exiting.\033[0m"
  exit 1
fi

# Define common torrent ports (TCP/UDP)
TORRENT_PORTS=()
for port in {6881..6999}; do TORRENT_PORTS+=("$port"); done
TORRENT_PORTS+=(51413 12345 30000 40000 45000)

# Define known torrent tracker ports (DHT, PEX)
DHT_PORTS=(6881 8999 27000)
PEER_EXCHANGE_PORTS=(2710 2711)
TORRENT_DOMAINS=("thepiratebay.org" "1337x.to" "rarbg.to" "yts.mx" "torlock.com")

HOSTS_FILE="/etc/hosts"
IPTABLES_RULES_V4="/etc/iptables/rules.v4"
IPTABLES_RULES_V6="/etc/iptables/rules.v6"

ensure_dirs() { [ -d /etc/iptables ] || mkdir -p /etc/iptables 2>/dev/null || true; }

save_iptables_rules() {
  ensure_dirs
  if command -v iptables-save >/dev/null 2>&1 && [ -d /etc/iptables ]; then
    iptables-save > "$IPTABLES_RULES_V4" || true
  fi
  if command -v ip6tables-save >/dev/null 2>&1 && [ -d /etc/iptables ] && command -v ip6tables-save >/dev/null 2>&1; then
    ip6tables-save > "$IPTABLES_RULES_V6" || true
  fi
  if systemctl list-unit-files 2>/dev/null | grep -q '^netfilter-persistent\.service'; then
    systemctl restart netfilter-persistent || true
  fi
}

hosts_add_domain() {
  local domain="$1"
  grep -Eq "^[[:space:]]*(0\.0\.0\.0|127\.0\.0\.1|::1)[[:space:]]+${domain//\./\\.}([[:space:]]|$)" "$HOSTS_FILE" && return 0
  echo "0.0.0.0 $domain" >> "$HOSTS_FILE"
}

# Function to block torrent traffic
block_torrent() {
  echo "Blocking common torrent ports, DHT, and PEX traffic..."

  for port in "${TORRENT_PORTS[@]}"; do
    iptables -w 2 -A OUTPUT -p tcp --dport "$port" -j DROP
    iptables -w 2 -A OUTPUT -p udp --dport "$port" -j DROP
    iptables -w 2 -A INPUT  -p tcp --sport "$port" -j DROP
    iptables -w 2 -A INPUT  -p udp --sport "$port" -j DROP
  done

  for port in "${DHT_PORTS[@]}"; do
    iptables -w 2 -A OUTPUT -p udp --dport "$port" -j DROP
    iptables -w 2 -A INPUT  -p udp --sport "$port" -j DROP
  done

  for port in "${PEER_EXCHANGE_PORTS[@]}"; do
    iptables -w 2 -A OUTPUT -p udp --dport "$port" -j DROP
    iptables -w 2 -A INPUT  -p udp --sport "$port" -j DROP
  done

  echo "Blocking common torrent domains via /etc/hosts (DNS sinkhole)..."
  for domain in "${TORRENT_DOMAINS[@]}"; do
    hosts_add_domain "$domain"
  done

  save_iptables_rules
  echo "Torrent blocking rules applied."
}

# Function to unblock torrent traffic (best-effort)
unblock_torrent() {
  echo "Removing torrent blocking rules (best-effort)..."

  for port in "${TORRENT_PORTS[@]}"; do
    iptables -w 2 -D OUTPUT -p tcp --dport "$port" -j DROP 2>/dev/null || true
    iptables -w 2 -D OUTPUT -p udp --dport "$port" -j DROP 2>/dev/null || true
    iptables -w 2 -D INPUT  -p tcp --sport "$port" -j DROP 2>/dev/null || true
    iptables -w 2 -D INPUT  -p udp --sport "$port" -j DROP 2>/dev/null || true
  done

  for port in "${DHT_PORTS[@]}"; do
    iptables -w 2 -D OUTPUT -p udp --dport "$port" -j DROP 2>/dev/null || true
    iptables -w 2 -D INPUT  -p udp --sport "$port" -j DROP 2>/dev/null || true
  done

  for port in "${PEER_EXCHANGE_PORTS[@]}"; do
    iptables -w 2 -D OUTPUT -p udp --dport "$port" -j DROP 2>/dev/null || true
    iptables -w 2 -D INPUT  -p udp --sport "$port" -j DROP 2>/dev/null || true
  done

  # Remove only our simple mappings
  for domain in "${TORRENT_DOMAINS[@]}"; do
    sed -i.bak -E "/^[[:space:]]*(0\.0\.0\.0|127\.0\.0\.1|::1)[[:space:]]+${domain//\./\\.}([[:space:]]|$)/d" "$HOSTS_FILE"
  done

  save_iptables_rules
  echo "Torrent blocking rules removed."
}

echo "1) Block torrent traffic"
echo "2) Unblock torrent traffic"
read -r -p "Choose an option [1-2]: " choice

case "${choice:-}" in
  1) block_torrent ;;
  2) unblock_torrent ;;
  *) echo "Invalid option."; exit 1 ;;
esac
