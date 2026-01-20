#!/bin/bash
# bmenu - interactive menu for managing tracker blocking (hosts + iptables)
set -euo pipefail

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "\033[31mThis script must be run as root. Exiting.\033[0m"
    exit 1
fi

# -----------------------------------------------------------------------------
# Locking (prevents concurrent runs)
# -----------------------------------------------------------------------------
LOCK_PATH="/tmp/hiddify_update_lock"
exec 9>"$LOCK_PATH"
if ! command -v flock >/dev/null 2>&1; then
    echo -e "\033[31mflock is required but not found. Install util-linux.\033[0m"
    exit 1
fi
if ! flock -n 9; then
    echo -e "\033[31mAnother instance of the script is already running. Exiting.\033[0m"
    exit 1
fi

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
TRACKERS_FILE="/etc/trackers"
HOSTS_TRACKERS_FILE="/etc/hostsTrackers"
HOSTS_FILE="/etc/hosts"
IPTABLES_RULES_V4="/etc/iptables/rules.v4"
IPTABLES_RULES_V6="/etc/iptables/rules.v6"

# -----------------------------------------------------------------------------
# Color definitions for better UI/UX
# -----------------------------------------------------------------------------
COLOR_HEADER="\033[1;34m"
COLOR_SUCCESS="\033[32m"
COLOR_WARNING="\033[33m"
COLOR_ERROR="\033[31m"
COLOR_RESET="\033[0m"

print_header()  { echo -e "${COLOR_HEADER}$1${COLOR_RESET}"; }
print_success() { echo -e "${COLOR_SUCCESS}$1${COLOR_RESET}"; }
print_warning() { echo -e "${COLOR_WARNING}$1${COLOR_RESET}"; }
print_error()   { echo -e "${COLOR_ERROR}$1${COLOR_RESET}"; }

die() { print_error "$1"; exit 1; }

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
is_ipv4() { [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_ipv6() { [[ "${1:-}" =~ : ]]; } # simple heuristic; good enough for our use
is_ip()   { is_ipv4 "$1" || is_ipv6 "$1"; }

ensure_file_exists() {
    local f="$1"
    if [ ! -e "$f" ]; then
        touch "$f" || die "Failed to create $f"
        chmod 0644 "$f" || true
    fi
    [ -w "$f" ] || die "No write permission for $f"
}

ensure_dirs() {
    if [ ! -d "/etc/iptables" ]; then
        mkdir -p /etc/iptables || true
    fi
}

have_chain() {
    local cmd="$1" chain="$2"
    "$cmd" -S "$chain" >/dev/null 2>&1
}

iptables_cmd_for_ip() {
    local ip="$1"
    if is_ipv6 "$ip" && command -v ip6tables >/dev/null 2>&1; then
        echo "ip6tables"
    else
        echo "iptables"
    fi
}

# Add rule if missing; remove duplicates safely
iptables_ensure_rule() {
    local cmd="$1"; shift
    local rule=("$@")
    # Use -w if supported (prevents xtables lock races)
    if "$cmd" -w 2 -C "${rule[@]}" >/dev/null 2>&1; then
        return 0
    fi
    "$cmd" -w 2 -A "${rule[@]}"
}

iptables_delete_rule_if_exists() {
    local cmd="$1"; shift
    local rule=("$@")
    while "$cmd" -w 2 -C "${rule[@]}" >/dev/null 2>&1; do
        "$cmd" -w 2 -D "${rule[@]}" || break
    done
}

save_iptables_rules() {
    ensure_dirs
    if command -v iptables-save >/dev/null 2>&1 && [ -d /etc/iptables ]; then
        iptables-save > "$IPTABLES_RULES_V4" || true
    fi
    if command -v ip6tables-save >/dev/null 2>&1 && [ -d /etc/iptables ]; then
        ip6tables-save > "$IPTABLES_RULES_V6" || true
    fi

    # Restart persistence service if available
    if systemctl list-unit-files 2>/dev/null | grep -q '^netfilter-persistent\.service'; then
        systemctl restart netfilter-persistent || true
    fi
}

# Resolve hostname -> IPs (IPv4/IPv6)
resolve_to_ips() {
    local host="$1"
    if is_ip "$host"; then
        echo "$host"
        return 0
    fi
    # getent may return multiple lines; take unique first field (address)
    getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u
}

# Manage /etc/hosts entries safely
hosts_has_domain() {
    local domain="$1"
    grep -Eq "^[[:space:]]*(0\.0\.0\.0|127\.0\.0\.1|::1)[[:space:]]+$domain([[:space:]]|$)" "$HOSTS_FILE"
}

hosts_add_domain() {
    local domain="$1"
    if hosts_has_domain "$domain"; then
        return 0
    fi
    echo "0.0.0.0 $domain" >> "$HOSTS_FILE"
}

hosts_remove_domain() {
    local domain="$1"
    # Remove lines mapping domain to 0.0.0.0/127.0.0.1/::1 (only our style)
    sed -i.bak -E "/^[[:space:]]*(0\.0\.0\.0|127\.0\.0\.1|::1)[[:space:]]+${domain//\./\\.}([[:space:]]|$)/d" "$HOSTS_FILE"
}

# -----------------------------------------------------------------------------
# Validate required files
# -----------------------------------------------------------------------------
ensure_file_exists "$TRACKERS_FILE"
ensure_file_exists "$HOSTS_TRACKERS_FILE"

# -----------------------------------------------------------------------------
# Core actions
# -----------------------------------------------------------------------------
add_host() {
    local host_or_ip="$1"
    [ -n "${host_or_ip:-}" ] || { print_error "No host/IP provided."; return 1; }

    # Trackers file should store the original entry (domain or IP), one per line
    if grep -Fxq "$host_or_ip" "$TRACKERS_FILE" || grep -Fxq "$host_or_ip" "$HOSTS_TRACKERS_FILE"; then
        print_warning "$host_or_ip is already in the list."
    else
        echo "$host_or_ip" >> "$TRACKERS_FILE"
        echo "$host_or_ip" >> "$HOSTS_TRACKERS_FILE"
        print_success "Added $host_or_ip to tracker lists."
    fi

    # If it's a domain, add to /etc/hosts for DNS sinkhole style blocking
    if ! is_ip "$host_or_ip"; then
        hosts_add_domain "$host_or_ip"
        print_success "Added $host_or_ip to $HOSTS_FILE as 0.0.0.0 mapping."
    fi

    # Resolve to IPs and block them (best-effort; still keep domain block even if resolve fails)
    local ips
    ips="$(resolve_to_ips "$host_or_ip" || true)"
    if [ -z "${ips:-}" ]; then
        print_warning "Could not resolve $host_or_ip to IP addresses right now (domain block may still work)."
        save_iptables_rules
        return 0
    fi

    while IFS= read -r ip; do
        [ -n "$ip" ] || continue
        local cmd
        cmd="$(iptables_cmd_for_ip "$ip")"

        # Inbound from that IP
        iptables_ensure_rule "$cmd" INPUT  -s "$ip" -j DROP
        # Outbound to that IP
        iptables_ensure_rule "$cmd" OUTPUT -d "$ip" -j DROP
        # Forwarded traffic both ways (router / docker bridge scenarios)
        iptables_ensure_rule "$cmd" FORWARD -s "$ip" -j DROP
        iptables_ensure_rule "$cmd" FORWARD -d "$ip" -j DROP

        # Docker chain (only if present)
        if have_chain "$cmd" DOCKER-USER; then
            iptables_ensure_rule "$cmd" DOCKER-USER -d "$ip" -j DROP
        fi

        print_success "$ip has been blocked successfully."
    done <<< "$ips"

    save_iptables_rules
}

remove_host() {
    local host_or_ip="$1"
    [ -n "${host_or_ip:-}" ] || { print_error "No host/IP provided."; return 1; }

    # Remove from list files
    if [ -f "$TRACKERS_FILE" ]; then
        grep -Fvx "$host_or_ip" "$TRACKERS_FILE" > "${TRACKERS_FILE}.tmp" || true
        mv "${TRACKERS_FILE}.tmp" "$TRACKERS_FILE"
    fi
    if [ -f "$HOSTS_TRACKERS_FILE" ]; then
        grep -Fvx "$host_or_ip" "$HOSTS_TRACKERS_FILE" > "${HOSTS_TRACKERS_FILE}.tmp" || true
        mv "${HOSTS_TRACKERS_FILE}.tmp" "$HOSTS_TRACKERS_FILE"
    fi

    # Remove host mapping if it's a domain
    if ! is_ip "$host_or_ip"; then
        hosts_remove_domain "$host_or_ip"
        print_success "Removed $host_or_ip mapping from $HOSTS_FILE (backup created with .bak)."
    fi

    # Resolve to IPs and remove iptables rules (best-effort)
    local ips
    ips="$(resolve_to_ips "$host_or_ip" || true)"
    if [ -z "${ips:-}" ]; then
        print_warning "Could not resolve $host_or_ip to IP addresses right now; removed list/hosts entries."
        save_iptables_rules
        return 0
    fi

    while IFS= read -r ip; do
        [ -n "$ip" ] || continue
        local cmd
        cmd="$(iptables_cmd_for_ip "$ip")"

        iptables_delete_rule_if_exists "$cmd" INPUT  -s "$ip" -j DROP
        iptables_delete_rule_if_exists "$cmd" OUTPUT -d "$ip" -j DROP
        iptables_delete_rule_if_exists "$cmd" FORWARD -s "$ip" -j DROP
        iptables_delete_rule_if_exists "$cmd" FORWARD -d "$ip" -j DROP
        if have_chain "$cmd" DOCKER-USER; then
            iptables_delete_rule_if_exists "$cmd" DOCKER-USER -d "$ip" -j DROP
        fi

        print_success "$ip has been unblocked successfully."
    done <<< "$ips"

    save_iptables_rules
}

list_hosts() {
    print_header "Blocked entries (from $TRACKERS_FILE):"
    if [ -s "$TRACKERS_FILE" ]; then
        nl -ba "$TRACKERS_FILE"
    else
        echo "(empty)"
    fi
}

# -----------------------------------------------------------------------------
# Menu loop
# -----------------------------------------------------------------------------
show_menu() {
    clear || true
    print_header "=============================="
    print_header "   Block Menu (bmenu)         "
    print_header "=============================="
    echo "1) List blocked entries"
    echo "2) Add host/domain/IP"
    echo "3) Remove host/domain/IP"
    echo "4) Exit"
    echo
}

while true; do
    show_menu
    read -r -p "Choose an option [1-4]: " choice
    case "$choice" in
        1)
            list_hosts
            read -r -p "Press Enter to continue..." _
            ;;
        2)
            read -r -p "Enter host/domain/IP to block: " entry
            add_host "${entry:-}"
            read -r -p "Press Enter to continue..." _
            ;;
        3)
            read -r -p "Enter host/domain/IP to unblock: " entry
            remove_host "${entry:-}"
            read -r -p "Press Enter to continue..." _
            ;;
        4)
            print_success "Exiting."
            exit 0
            ;;
        *)
            print_error "Invalid option."
            read -r -p "Press Enter to continue..." _
            ;;
    esac
done
