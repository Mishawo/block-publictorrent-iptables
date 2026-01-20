#!/bin/bash
# rmfew - remove project files and unblock torrent/tracker rules (best-effort)
set -euo pipefail

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo -e "\033[31mThis script must be run as root. Exiting.\033[0m"
  exit 1
fi

# Confirmation before execution
read -r -p "Are you sure you want to remove project files and unblock traffic? (y/N): " confirm
if [[ "${confirm:-}" != "y" && "${confirm:-}" != "Y" ]]; then
  echo -e "\033[33mOperation canceled.\033[0m"
  exit 0
fi

TRACKERS_FILE="/etc/trackers"
HOSTS_TRACKERS_FILE="/etc/hostsTrackers"
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

# Define blocked torrent ports and domains (kept close to original intent)
TORRENT_PORTS=()
for port in {6881..6999}; do TORRENT_PORTS+=("$port"); done
TORRENT_PORTS+=(51413 12345 30000 40000 45000)
DHT_PORTS=(6881 8999 27000)
PEER_EXCHANGE_PORTS=(2710 2711)
TORRENT_DOMAINS=(
  "thepiratebay.org" "1337x.to" "rarbg.to" "yts.mx" "torlock.com"
  "tracker.openbittorrent.com" "tracker.opentrackr.org"
  "tracker.leechers-paradise.org" "tracker.publicbt.com" "tracker.coppersurfer.tk"
)

echo "Unblocking torrent/tracker traffic (best-effort)..."

# Remove port-based rules
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

# Remove domain mappings from hosts
for domain in "${TORRENT_DOMAINS[@]}"; do
  remove_hosts_mapping "$domain" || true
done

# Remove IP-based rules for entries in trackers file
if [ -f "$TRACKERS_FILE" ] && command -v iptables >/dev/null 2>&1; then
  while IFS= read -r entry; do
    entry="${entry%%#*}"
    entry="$(echo "$entry" | xargs || true)"
    [ -n "$entry" ] || continue

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
fi

# Remove project files
rm -f "$TRACKERS_FILE" "$HOSTS_TRACKERS_FILE" 2>/dev/null || true
rm -f /etc/cron.daily/denypublic 2>/dev/null || true
rm -f /usr/local/bin/bmenu 2>/dev/null || true

# Save rules if persistence exists
if systemctl list-unit-files 2>/dev/null | grep -q '^netfilter-persistent\.service'; then
  systemctl restart netfilter-persistent || true
fi

echo -e "\033[32mDone. Backups of /etc/hosts may have been created with .bak extension.\033[0m"
