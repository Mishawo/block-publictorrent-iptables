#!/bin/bash
#
# 2025 Updated !!
# GitHub:   https://github.com/MasterHide/block-publictorrent-iptables
# Author:   MasterHide
#
# Installer / setup script for project structure (keeps same file layout).

set -euo pipefail

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo -e "\033[31mThis script must be run as root. Exiting.\033[0m"
  exit 1
fi

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'  # No Color

# Functions for output
print_success() { echo -e "${GREEN}$1${NC}"; }
print_error()   { echo -e "${RED}$1${NC}"; }
print_warning() { echo -e "${YELLOW}$1${NC}"; }

die() { print_error "$1"; exit 1; }

# Common locations this project might be placed (kept from original)
INSTALL_PATHS=(
  "/root/block-publictorrent-iptables"
  "/opt/block-publictorrent-iptables"
  "/usr/local/src/block-publictorrent-iptables"
  "/home/$SUDO_USER/block-publictorrent-iptables"
)

ESSENTIAL_FILES=("trackers" "hostsTrackers" "bmenu.sh" "cleanup_hosts.sh" "ctp.sh" "rmfew.sh" "uninstall_all.sh" "README.md" "LICENSE")

# Where to keep persistent lists
TRACKERS_DST="/etc/trackers"
HOSTS_TRACKERS_DST="/etc/hostsTrackers"
HOSTS_FILE="/etc/hosts"

is_ipv4() { [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_ipv6() { [[ "${1:-}" =~ : ]]; }
is_ip()   { is_ipv4 "$1" || is_ipv6 "$1"; }

ensure_file() {
  local f="$1"
  if [ ! -e "$f" ]; then
    touch "$f" || die "Failed to create $f"
    chmod 0644 "$f" || true
  fi
}

hosts_add_domain_line() {
  local domain="$1"
  grep -Eq "^[[:space:]]*(0\.0\.0\.0|127\.0\.0\.1|::1)[[:space:]]+${domain//\./\\.}([[:space:]]|$)" "$HOSTS_FILE" && return 0
  echo "0.0.0.0 $domain" >> "$HOSTS_FILE"
}

sync_trackers_to_hosts() {
  # Only add valid domain mappings to /etc/hosts (never append raw domains)
  [ -f "$TRACKERS_DST" ] || return 0
  local tmp
  tmp="$(mktemp)"
  while IFS= read -r entry; do
    entry="${entry%%#*}"
    entry="$(echo "$entry" | xargs || true)"
    [ -n "$entry" ] || continue
    if is_ip "$entry"; then
      continue
    fi
    echo "0.0.0.0 $entry" >> "$tmp"
  done < "$TRACKERS_DST"

  if [ -s "$tmp" ]; then
    while IFS= read -r line; do
      # line format: 0.0.0.0 domain
      hosts_add_domain_line "$(echo "$line" | awk '{print $2}')"
    done < "$tmp"
  fi
  rm -f "$tmp"
}

download_file_to_all_paths() {
  local file="$1"
  local downloaded=0
  for path in "${INSTALL_PATHS[@]}"; do
    if [ -d "$path" ]; then
      if [ -f "$path/$file" ]; then
        downloaded=1
      fi
    fi
  done

  # If the file is already present in one of the install paths, do nothing
  if [ "$downloaded" -eq 1 ]; then
    return 0
  fi

  # Otherwise try to download from the official repo (best-effort)
  if command -v wget >/dev/null 2>&1; then
    for path in "${INSTALL_PATHS[@]}"; do
      if [ -d "$path" ]; then
        wget -q -O "$path/$file" "https://raw.githubusercontent.com/MasterHide/block-publictorrent-iptables/main/$file" \
          && print_success "Downloaded $file to $path" \
          && chmod +x "$path/$file" 2>/dev/null || true
      fi
    done
  elif command -v curl >/dev/null 2>&1; then
    for path in "${INSTALL_PATHS[@]}"; do
      if [ -d "$path" ]; then
        curl -fsSL "https://raw.githubusercontent.com/MasterHide/block-publictorrent-iptables/main/$file" -o "$path/$file" \
          && print_success "Downloaded $file to $path" \
          && chmod +x "$path/$file" 2>/dev/null || true
      fi
    done
  else
    print_warning "Neither wget nor curl found. Skipping download step."
  fi
}

# Download essential files to all known paths (best-effort, keeps structure)
for file in "${ESSENTIAL_FILES[@]}"; do
  download_file_to_all_paths "$file"
done

# Ensure persistent files exist
ensure_file "$HOSTS_TRACKERS_DST"
ensure_file "$TRACKERS_DST"

# If local project has trackers/hostsTrackers, move them to /etc/ for persistence
for path in "${INSTALL_PATHS[@]}"; do
  if [ -f "$path/trackers" ]; then
    cp "$path/trackers" "$TRACKERS_DST" || true
  fi
  if [ -f "$path/hostsTrackers" ]; then
    cp "$path/hostsTrackers" "$HOSTS_TRACKERS_DST" || true
  fi
done

print_success "Ensured persistent lists: $TRACKERS_DST and $HOSTS_TRACKERS_DST"

# Update /etc/hosts safely from tracker domains
sync_trackers_to_hosts
print_success "Synced tracker domains into $HOSTS_FILE (0.0.0.0 mappings)."

# Create cron job for blocking public trackers (idempotent and correct direction rules)
CRON_FILE="/etc/cron.daily/denypublic"
cat >"$CRON_FILE"<<'EOF'
#!/bin/bash
set -euo pipefail
IFS=$'\n'

TRACKERS_FILE="/etc/trackers"
DNSMASQ_CONF="/etc/dnsmasq.d/blocked_domains.conf"

command -v iptables >/dev/null 2>&1 || exit 0

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

ensure_rule() {
  local cmd="$1"; shift
  local rule=("$@")
  if "$cmd" -w 2 -C "${rule[@]}" >/dev/null 2>&1; then
    return 0
  fi
  "$cmd" -w 2 -A "${rule[@]}"
}

resolve_to_ips() {
  local host="$1"
  if is_ip "$host"; then
    echo "$host"
    return 0
  fi
  getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u
}

[ -f "$TRACKERS_FILE" ] || exit 0

# Prepare dnsmasq conf if dnsmasq exists
if command -v dnsmasq >/dev/null 2>&1; then
  mkdir -p /etc/dnsmasq.d || true
  touch "$DNSMASQ_CONF" || true
fi

# Process each tracker entry
while IFS= read -r entry; do
  entry="${entry%%#*}"
  entry="$(echo "$entry" | xargs || true)"
  [ -n "$entry" ] || continue

  # If entry isn't IP, add dnsmasq mapping (idempotent) when available
  if ! is_ip "$entry" && command -v dnsmasq >/dev/null 2>&1; then
    if ! grep -qF "address=/$entry/0.0.0.0" "$DNSMASQ_CONF" 2>/dev/null; then
      echo "address=/$entry/0.0.0.0" >> "$DNSMASQ_CONF"
    fi
  fi

  ips="$(resolve_to_ips "$entry" || true)"
  [ -n "${ips:-}" ] || continue

  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    cmd="$(iptables_cmd_for_ip "$ip")"

    # Inbound from that IP
    ensure_rule "$cmd" INPUT  -s "$ip" -j DROP
    # Outbound to that IP
    ensure_rule "$cmd" OUTPUT -d "$ip" -j DROP
    # Forwarded traffic both directions
    ensure_rule "$cmd" FORWARD -s "$ip" -j DROP
    ensure_rule "$cmd" FORWARD -d "$ip" -j DROP

    if have_chain "$cmd" DOCKER-USER; then
      ensure_rule "$cmd" DOCKER-USER -d "$ip" -j DROP
    fi
  done <<< "$ips"

done < "$TRACKERS_FILE"

# Restart dnsmasq if updated
if command -v dnsmasq >/dev/null 2>&1 && [ -f "$DNSMASQ_CONF" ]; then
  systemctl restart dnsmasq 2>/dev/null || true
fi
EOF

chmod +x "$CRON_FILE" || die "Failed to make $CRON_FILE executable."
print_success "Cron job installed at $CRON_FILE."

# Install bmenu globally
for path in "${INSTALL_PATHS[@]}"; do
  if [ -f "$path/bmenu.sh" ]; then
    cp "$path/bmenu.sh" /usr/local/bin/bmenu || die "Failed to install bmenu globally."
    chmod +x /usr/local/bin/bmenu || die "Failed to set executable permission for bmenu."
    chown root:root /usr/local/bin/bmenu || true
    print_success "bmenu command is now available globally to all users."
    exit 0
  fi
done

print_error "bmenu.sh not found in any of the defined installation paths."
exit 1
