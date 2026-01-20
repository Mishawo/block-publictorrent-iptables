#!/bin/bash
# uninstall_all - remove files and rules created by this project (without flushing unrelated firewall rules)
set -euo pipefail

log_message() { echo -e "[INFO] $1"; }
log_warn()    { echo -e "[WARN] $1"; }
log_error()   { echo -e "[ERROR] $1"; }

# Check if script is being run as root
if [ "$(id -u)" -ne 0 ]; then
  log_error "This script must be run as root or with sudo."
  exit 1
fi

TRACKERS_FILE="/etc/trackers"
HOSTS_TRACKERS_FILE="/etc/hostsTrackers"
CRON_FILE="/etc/cron.daily/denypublic"
HOSTS_FILE="/etc/hosts"

is_ipv4() { [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_ipv6() { [[ "${1:-}" =~ : ]]; }
is_ip()   { is_ipv4 "$1" || is_ipv6 "$1"; }

iptables_cmd_for_ip() {
  local ip="$1"
  if is_ipv6 "$ip" && command -v ip6tables >/dev/null 2>&1; then
    echo "ip6tables"
  else
    echo "iptables"
  fi
}

have_chain() {
  local cmd="$1" chain="$2"
  "$cmd" -S "$chain" >/dev/null 2>&1
}

delete_rule_if_exists() {
  local cmd="$1"; shift
  local rule=("$@")
  while "$cmd" -w 2 -C "${rule[@]}" >/dev/null 2>&1; do
    "$cmd" -w 2 -D "${rule[@]}" || break
  done
}

resolve_to_ips() {
  local host="$1"
  if is_ip "$host"; then
    echo "$host"
    return 0
  fi
  getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u
}

remove_hosts_mapping() {
  local domain="$1"
  sed -i.bak -E "/^[[:space:]]*(0\.0\.0\.0|127\.0\.0\.1|::1)[[:space:]]+${domain//\./\\.}([[:space:]]|$)/d" "$HOSTS_FILE"
}

log_message "Starting uninstall..."

# Step 1: Remove globally installed command(s)
if [ -f "/usr/local/bin/bmenu" ]; then
  rm -f /usr/local/bin/bmenu
  log_message "Removed /usr/local/bin/bmenu"
fi

# Step 2: Remove cron job
if [ -f "$CRON_FILE" ]; then
  rm -f "$CRON_FILE"
  log_message "Removed cron job $CRON_FILE"
fi

# Step 3: Remove firewall rules added for entries in /etc/trackers (best-effort, no flush)
if command -v iptables >/dev/null 2>&1; then
  if [ -f "$TRACKERS_FILE" ] && [ -s "$TRACKERS_FILE" ]; then
    log_message "Removing iptables/ip6tables rules for entries in $TRACKERS_FILE..."
    while IFS= read -r entry; do
      entry="${entry%%#*}"
      entry="$(echo "$entry" | xargs || true)"
      [ -n "$entry" ] || continue

      # Remove hosts sinkhole line if it's a domain
      if ! is_ip "$entry"; then
        remove_hosts_mapping "$entry" || true
      fi

      ips="$(resolve_to_ips "$entry" || true)"
      [ -n "${ips:-}" ] || continue

      while IFS= read -r ip; do
        [ -n "$ip" ] || continue
        cmd="$(iptables_cmd_for_ip "$ip")"

        delete_rule_if_exists "$cmd" INPUT  -s "$ip" -j DROP
        delete_rule_if_exists "$cmd" OUTPUT -d "$ip" -j DROP
        delete_rule_if_exists "$cmd" FORWARD -s "$ip" -j DROP
        delete_rule_if_exists "$cmd" FORWARD -d "$ip" -j DROP
        if have_chain "$cmd" DOCKER-USER; then
          delete_rule_if_exists "$cmd" DOCKER-USER -d "$ip" -j DROP
        fi
      done <<< "$ips"
    done < "$TRACKERS_FILE"
  else
    log_warn "$TRACKERS_FILE not found or empty; skipping IP-based rule cleanup."
  fi
else
  log_warn "iptables not found; skipping firewall cleanup."
fi

# Step 4: Remove known torrent-port rules used by ctp.sh (best-effort)
TORRENT_PORTS=()
for port in {6881..6999}; do TORRENT_PORTS+=("$port"); done
TORRENT_PORTS+=(51413 12345 30000 40000 45000)
DHT_PORTS=(6881 8999 27000)
PEER_EXCHANGE_PORTS=(2710 2711)

if command -v iptables >/dev/null 2>&1; then
  for port in "${TORRENT_PORTS[@]}"; do
    delete_rule_if_exists iptables OUTPUT -p tcp --dport "$port" -j DROP
    delete_rule_if_exists iptables OUTPUT -p udp --dport "$port" -j DROP
    delete_rule_if_exists iptables INPUT  -p tcp --sport "$port" -j DROP
    delete_rule_if_exists iptables INPUT  -p udp --sport "$port" -j DROP
  done
  for port in "${DHT_PORTS[@]}"; do
    delete_rule_if_exists iptables OUTPUT -p udp --dport "$port" -j DROP
    delete_rule_if_exists iptables INPUT  -p udp --sport "$port" -j DROP
  done
  for port in "${PEER_EXCHANGE_PORTS[@]}"; do
    delete_rule_if_exists iptables OUTPUT -p udp --dport "$port" -j DROP
    delete_rule_if_exists iptables INPUT  -p udp --sport "$port" -j DROP
  done
fi

# Step 5: Remove project data files
for f in "$TRACKERS_FILE" "$HOSTS_TRACKERS_FILE"; do
  if [ -f "$f" ]; then
    rm -f "$f"
    log_message "Removed $f"
  fi
done

# Step 6: Optional: clean dnsmasq config used by denypublic cron (leave file if user has own entries)
DNSMASQ_CONF="/etc/dnsmasq.d/blocked_domains.conf"
if [ -f "$DNSMASQ_CONF" ]; then
  log_warn "dnsmasq config exists at $DNSMASQ_CONF. Not deleting automatically."
fi

# Step 7: Save rules (if persistence is available)
if systemctl list-unit-files 2>/dev/null | grep -q '^netfilter-persistent\.service'; then
  systemctl restart netfilter-persistent || true
fi

log_message "Uninstallation complete."
