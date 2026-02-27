#!/bin/bash
#══════════════════════════════════════════════════════════════
#
#   ██████╗ ███████╗███╗   ███╗
#   ██╔══██╗██╔════╝████╗ ████║
#   ██████╔╝█████╗  ██╔████╔██║
#   ██╔═══╝ ██╔══╝  ██║╚██╔╝██║
#   ██║     ██║     ██║ ╚═╝ ██║
#   ╚═╝     ╚═╝     ╚═╝     ╚═╝
#
#   Port Forward Manager v1.6
#
#   Telegram: https://t.me/AbrAfagh
#
#══════════════════════════════════════════════════════════════

PFM_DIR="/etc/pfm"
USERS_DIR="$PFM_DIR/users"
PORTS_DIR="$PFM_DIR/ports"
USAGE_DIR="$PFM_DIR/usage"
MTU_DIR="$PFM_DIR/mtu"
REALM_DIR="$PFM_DIR/realm"
REALM_BIN="/usr/local/bin/realm"
HAPROXY_CFG="$PFM_DIR/haproxy.cfg"
LOG_FILE="/var/log/pfm.log"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'
W='\033[1;37m'; GR='\033[0;90m'; NC='\033[0m'; B='\033[1m'
MAG='\033[0;35m'

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null; }
check_root() { [[ $EUID -ne 0 ]] && { echo -e "${R}Run as root${NC}"; exit 1; }; }

human_bytes() {
    local b=${1:-0}
    if (( b >= 1000000000000 )); then awk "BEGIN{printf \"%.2f TB\",$b/1000000000000}"
    elif (( b >= 1000000000 )); then awk "BEGIN{printf \"%.2f GB\",$b/1000000000}"
    elif (( b >= 1000000 )); then awk "BEGIN{printf \"%.2f MB\",$b/1000000}"
    elif (( b >= 1000 )); then awk "BEGIN{printf \"%.2f KB\",$b/1000}"
    else echo "${b} B"; fi
}

gb_to_bytes() { awk "BEGIN{printf \"%.0f\",$1*1000000000}"; }
is_ipv6() { [[ "$1" == *:* ]]; }
ipt() { is_ipv6 "$1" && echo "ip6tables" || echo "iptables"; }

# ═══════════════ REALM ═══════════════
realm_installed() { [[ -x "$REALM_BIN" ]]; }
install_realm() {
    if realm_installed; then echo -e "  ${G}realm OK${NC}"; return 0; fi
    echo -e "  ${C}Installing realm...${NC}"
    local arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="x86_64-unknown-linux-gnu" ;;
        aarch64) arch="aarch64-unknown-linux-gnu" ;;
        armv7l)  arch="armv7-unknown-linux-gnueabihf" ;;
        *) echo -e "  ${R}Unsupported: $arch${NC}"; return 1 ;;
    esac
    local tmp=$(mktemp -d)
    if curl -sL --connect-timeout 10 --max-time 60 \
        "https://github.com/zhboner/realm/releases/latest/download/realm-${arch}.tar.gz" \
        -o "$tmp/realm.tar.gz" 2>/dev/null; then
        tar xzf "$tmp/realm.tar.gz" -C "$tmp/" 2>/dev/null
        if [[ -f "$tmp/realm" ]]; then
            mv "$tmp/realm" "$REALM_BIN"; chmod +x "$REALM_BIN"
            rm -rf "$tmp"; echo -e "  ${G}realm installed${NC}"; return 0
        fi
    fi
    rm -rf "$tmp"; echo -e "  ${R}Failed. Check internet.${NC}"; return 1
}
realm_conf() { echo "$REALM_DIR/${1}.toml"; }
realm_svc() { echo "pfm-realm-${1}"; }
create_realm_service() {
    local port="$1" dest="$2"; mkdir -p "$REALM_DIR"
    cat > "$(realm_conf "$port")" << EOF
[network]
no_tcp = false
use_udp = true

[[endpoints]]
listen = "0.0.0.0:${port}"
remote = "${dest}:${port}"
EOF
    cat > "/etc/systemd/system/$(realm_svc "$port").service" << EOF
[Unit]
Description=PFM Realm ${port}
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=120
StartLimitBurst=20

[Service]
Type=simple
ExecStart=${REALM_BIN} -c $(realm_conf "$port")
ExecStopPost=/bin/sh -c 'sleep 1'
Restart=always
RestartSec=2
LimitNOFILE=1048576
LimitNPROC=65535
# Kill cleanly, then force after 10s
TimeoutStopSec=10
KillMode=mixed
# Prevent memory leak: auto-restart every 6h
RuntimeMaxSec=21600

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$(realm_svc "$port")" > /dev/null 2>&1
    systemctl start "$(realm_svc "$port")"
}
remove_realm_service() {
    local port="$1"
    systemctl stop "$(realm_svc "$port")" 2>/dev/null
    systemctl disable "$(realm_svc "$port")" 2>/dev/null
    rm -f "/etc/systemd/system/$(realm_svc "$port").service" "$(realm_conf "$port")"
    systemctl daemon-reload
}
stop_realm_service() { systemctl stop "$(realm_svc "$1")" 2>/dev/null; }
start_realm_service() {
    systemctl enable "$(realm_svc "$1")" > /dev/null 2>&1
    systemctl restart "$(realm_svc "$1")"
}
realm_is_running() { systemctl is-active "$(realm_svc "$1")" > /dev/null 2>&1; }

# Health check: test if realm is actually forwarding (not just running)
realm_health_check() {
    local port="$1"
    [[ ! -f "$PORTS_DIR/$port" ]] && return 0
    local P_DEST="" P_METHOD="" P_BLOCKED=0; source "$PORTS_DIR/$port"
    [[ "$P_METHOD" != "realm" || "$P_BLOCKED" == "1" ]] && return 0
    if ! realm_is_running "$port"; then
        start_realm_service "$port"
        log "REALM-RESTART $port (was dead)"
        return 1
    fi
    # Check if process is stuck (using too much memory or too many FDs)
    local pid=$(systemctl show -p MainPID --value "$(realm_svc "$port")" 2>/dev/null)
    if [[ -n "$pid" && "$pid" != "0" && -d "/proc/$pid" ]]; then
        local mem_kb=$(awk '/VmRSS/{print $2}' /proc/$pid/status 2>/dev/null || echo 0)
        local fds=$(ls /proc/$pid/fd 2>/dev/null | wc -l)
        # If using >300MB RAM or >50000 FDs, restart
        if (( mem_kb > 307200 || fds > 50000 )); then
            systemctl restart "$(realm_svc "$port")"
            log "REALM-RESTART $port (mem=${mem_kb}KB fds=${fds})"
            return 1
        fi
    fi
    return 0
}

# ═══════════════ HAPROXY ═══════════════
haproxy_installed() { command -v haproxy > /dev/null 2>&1; }
install_haproxy() {
    if haproxy_installed; then echo -e "  ${G}haproxy OK${NC}"; return 0; fi
    echo -e "  ${C}Installing haproxy...${NC}"
    apt-get update -qq > /dev/null 2>&1
    apt-get install -y -qq haproxy > /dev/null 2>&1
    if haproxy_installed; then
        systemctl stop haproxy 2>/dev/null; systemctl disable haproxy 2>/dev/null
        echo -e "  ${G}haproxy installed${NC}"; return 0
    fi
    echo -e "  ${R}Failed${NC}"; return 1
}
rebuild_haproxy_cfg() {
    local has_ports=0
    for pf in "$PORTS_DIR"/*; do
        [[ -f "$pf" ]] || continue; local P_METHOD=""; source "$pf"
        [[ "$P_METHOD" == "haproxy" ]] && { has_ports=1; break; }
    done
    if [[ $has_ports -eq 0 ]]; then
        systemctl stop pfm-haproxy 2>/dev/null; rm -f "$HAPROXY_CFG"; return
    fi
    cat > "$HAPROXY_CFG" << 'HEADER'
global
    maxconn 100000
    nbthread 4
    log /dev/log local0

defaults
    mode tcp
    timeout connect 5s
    timeout client 300s
    timeout server 300s
    option splice-auto

HEADER
    for pf in "$PORTS_DIR"/*; do
        [[ -f "$pf" ]] || continue
        local P_METHOD="" P_DEST="" P_DPORT="" P_BLOCKED=0; source "$pf"
        [[ "$P_METHOD" != "haproxy" || "$P_BLOCKED" == "1" ]] && continue
        local port=$(basename "$pf")
        cat >> "$HAPROXY_CFG" << EOF
frontend ft_${port}
    bind *:${port}
    default_backend bk_${port}

backend bk_${port}
    server srv1 ${P_DEST}:${port}

EOF
    done
    if [[ ! -f /etc/systemd/system/pfm-haproxy.service ]]; then
        cat > /etc/systemd/system/pfm-haproxy.service << EOF
[Unit]
Description=PFM HAProxy
After=network-online.target
[Service]
Type=simple
ExecStart=/usr/sbin/haproxy -f ${HAPROXY_CFG} -W
ExecReload=/bin/kill -USR2 \$MAINPID
Restart=always
RestartSec=3
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi
    systemctl enable pfm-haproxy > /dev/null 2>&1
    if systemctl is-active pfm-haproxy > /dev/null 2>&1; then
        systemctl reload pfm-haproxy 2>/dev/null || systemctl restart pfm-haproxy
    else systemctl start pfm-haproxy; fi
}
haproxy_is_running() { systemctl is-active pfm-haproxy > /dev/null 2>&1; }

# ═══════════════ TRAFFIC ═══════════════
get_mangle_chain() {
    local port="$1"
    [[ ! -f "$PORTS_DIR/$port" ]] && { echo "FORWARD"; return; }
    local P_METHOD="iptables"; source "$PORTS_DIR/$port"
    [[ "$P_METHOD" == "iptables" ]] && echo "FORWARD" || echo "OUTPUT"
}
get_port_usage() {
    local port="$1"
    cat "$USAGE_DIR/$port" 2>/dev/null || echo 0
}
sync_port_usage() {
    local port="$1"
    [[ ! -f "$PORTS_DIR/$port" ]] && return
    local P_DEST="" P_METHOD="iptables"; source "$PORTS_DIR/$port"
    local cmd=$(ipt "$P_DEST") chain=$(get_mangle_chain "$port")
    local total=0 nums=()
    # Read counters (without zeroing)
    while IFS= read -r line; do
        if echo "$line" | grep -q "pfm_dl_${port} "; then
            local rn=$(echo "$line" | awk '{print $1}')
            local b=$(echo "$line" | awk '{print $3}')
            if [[ "$b" =~ ^[0-9]+$ && "$b" -gt 0 ]]; then
                total=$((total + b)); nums+=("$rn")
            fi
        fi
    done < <($cmd -t mangle -L "$chain" -v -n -x --line-numbers 2>/dev/null)
    # Save to file and zero only THIS port's rules
    if [[ $total -gt 0 ]]; then
        local saved=$(cat "$USAGE_DIR/$port" 2>/dev/null || echo 0)
        echo $((saved + total)) > "$USAGE_DIR/$port"
        for n in "${nums[@]}"; do $cmd -t mangle -Z "$chain" "$n" 2>/dev/null; done
    fi
}
sync_all() {
    # Prevent concurrent syncs (cron + bot + script)
    (
        flock -w 5 200 || return
        for f in "$PORTS_DIR"/*; do [[ -f "$f" ]] && sync_port_usage "$(basename "$f")"; done
    ) 200>/tmp/pfm_sync.lock
}

# ═══════════════ IPTABLES RULES ═══════════════
apply_rules_iptables() {
    local port="$1" dest="$2"; local cmd=$(ipt "$dest") p
    for p in tcp udp; do
        $cmd -t nat -A PREROUTING -p "$p" -m multiport --dports "$port" -j DNAT --to-destination "$dest"
        $cmd -t nat -A POSTROUTING -p "$p" -m multiport --dports "$port" -j MASQUERADE
        $cmd -t mangle -A FORWARD -p "$p" -s "$dest" --sport "$port" -m comment --comment "pfm_dl_${port}"
    done
}
remove_rules_iptables() {
    local port="$1" dest="$2"; local cmd=$(ipt "$dest") p
    for p in tcp udp; do
        while $cmd -t nat -D PREROUTING -p "$p" -m multiport --dports "$port" -j DNAT --to-destination "$dest" 2>/dev/null; do :; done
        while $cmd -t nat -D POSTROUTING -p "$p" -m multiport --dports "$port" -j MASQUERADE 2>/dev/null; do :; done
        while $cmd -t mangle -D FORWARD -p "$p" -s "$dest" --sport "$port" -m comment --comment "pfm_dl_${port}" 2>/dev/null; do :; done
    done
}
apply_accounting_userspace() {
    local port="$1" dest="$2"; local cmd=$(ipt "$dest") p
    for p in tcp udp; do
        $cmd -t mangle -A OUTPUT -p "$p" --sport "$port" -m comment --comment "pfm_dl_${port}"
    done
}
remove_accounting_userspace() {
    local port="$1" dest="$2"; local cmd=$(ipt "$dest") p
    for p in tcp udp; do
        while $cmd -t mangle -D OUTPUT -p "$p" --sport "$port" -m comment --comment "pfm_dl_${port}" 2>/dev/null; do :; done
    done
}
apply_rules() {
    local port="$1" dest="$2" method="$3"
    case "$method" in
        haproxy) apply_accounting_userspace "$port" "$dest"; rebuild_haproxy_cfg ;;
        realm)   apply_accounting_userspace "$port" "$dest"; create_realm_service "$port" "$dest" ;;
        *)       apply_rules_iptables "$port" "$dest" ;;
    esac
}
remove_rules() {
    local port="$1"; [[ ! -f "$PORTS_DIR/$port" ]] && return
    local P_DEST="" P_METHOD="iptables"; source "$PORTS_DIR/$port"
    case "$P_METHOD" in
        haproxy) remove_accounting_userspace "$port" "$P_DEST" ;;
        realm)   remove_accounting_userspace "$port" "$P_DEST"; remove_realm_service "$port" ;;
        *)       remove_rules_iptables "$port" "$P_DEST" ;;
    esac
    local cmd=$(ipt "$P_DEST") p
    for p in tcp udp; do
        while $cmd -D INPUT -p "$p" --dport "$port" -m comment --comment "pfm_block_${port}" -j DROP 2>/dev/null; do :; done
        while $cmd -D FORWARD -p "$p" --dport "$port" -m comment --comment "pfm_block_${port}" -j DROP 2>/dev/null; do :; done
    done
}

# ═══════════════ BLOCK/UNBLOCK ═══════════════
block_port() {
    local port="$1"; [[ ! -f "$PORTS_DIR/$port" ]] && return
    local P_DEST="" P_METHOD="iptables"; source "$PORTS_DIR/$port"
    sync_port_usage "$port"; local cmd=$(ipt "$P_DEST") p
    case "$P_METHOD" in
        haproxy)
            sed -i "s/P_BLOCKED=0/P_BLOCKED=1/" "$PORTS_DIR/$port"
            rebuild_haproxy_cfg
            for p in tcp; do
                $cmd -C INPUT -p "$p" --dport "$port" -m comment --comment "pfm_block_${port}" -j DROP 2>/dev/null || \
                $cmd -I INPUT 1 -p "$p" --dport "$port" -m comment --comment "pfm_block_${port}" -j DROP
            done; return ;;
        realm)
            stop_realm_service "$port"
            for p in tcp udp; do
                $cmd -C INPUT -p "$p" --dport "$port" -m comment --comment "pfm_block_${port}" -j DROP 2>/dev/null || \
                $cmd -I INPUT 1 -p "$p" --dport "$port" -m comment --comment "pfm_block_${port}" -j DROP
            done ;;
        *)
            for p in tcp udp; do
                $cmd -C FORWARD -p "$p" --dport "$port" -m comment --comment "pfm_block_${port}" -j DROP 2>/dev/null || \
                $cmd -I FORWARD 1 -p "$p" --dport "$port" -m comment --comment "pfm_block_${port}" -j DROP
            done ;;
    esac
    sed -i "s/P_BLOCKED=0/P_BLOCKED=1/" "$PORTS_DIR/$port"
}
unblock_port() {
    local port="$1"; [[ ! -f "$PORTS_DIR/$port" ]] && return
    local P_DEST="" P_METHOD="iptables"; source "$PORTS_DIR/$port"
    local cmd=$(ipt "$P_DEST") p
    case "$P_METHOD" in
        haproxy)
            for p in tcp; do while $cmd -D INPUT -p "$p" --dport "$port" -m comment --comment "pfm_block_${port}" -j DROP 2>/dev/null; do :; done; done
            sed -i "s/P_BLOCKED=1/P_BLOCKED=0/" "$PORTS_DIR/$port"; rebuild_haproxy_cfg; return ;;
        realm)
            for p in tcp udp; do while $cmd -D INPUT -p "$p" --dport "$port" -m comment --comment "pfm_block_${port}" -j DROP 2>/dev/null; do :; done; done
            start_realm_service "$port" ;;
        *)
            for p in tcp udp; do while $cmd -D FORWARD -p "$p" --dport "$port" -m comment --comment "pfm_block_${port}" -j DROP 2>/dev/null; do :; done; done ;;
    esac
    sed -i "s/P_BLOCKED=1/P_BLOCKED=0/" "$PORTS_DIR/$port"
}
check_limits() {
    for f in "$PORTS_DIR"/*; do
        [[ -f "$f" ]] || continue
        local port=$(basename "$f") P_LIMIT=0 P_BLOCKED=0 P_USER=""; source "$f"
        [[ "$P_LIMIT" -eq 0 || "$P_BLOCKED" == "1" ]] && continue
        local usage=$(cat "$USAGE_DIR/$port" 2>/dev/null || echo 0)
        (( usage >= P_LIMIT )) && { block_port "$port"; log "BLOCKED $port ($P_USER)"; }
    done
}

# ═══════════════ MTU ═══════════════
save_mtu() {
    local dev="$1" val="$2"; mkdir -p "$MTU_DIR"
    if [[ ! -f "$MTU_DIR/$dev" ]]; then
        echo -e "MTU_ORIG=\"$(ip link show "$dev" 2>/dev/null | grep -oP 'mtu \K[0-9]+')\"\nMTU_SET=\"$val\"" > "$MTU_DIR/$dev"
    else sed -i "s/MTU_SET=.*/MTU_SET=\"$val\"/" "$MTU_DIR/$dev"; fi
    ip link set mtu "$val" dev "$dev"
    local cr=$(crontab -l 2>/dev/null | grep -v "ip link set mtu.*dev $dev")
    (echo "$cr"; echo "@reboot /sbin/ip link set mtu $val dev $dev") | grep -v '^$' | crontab -
}
reset_mtu() {
    local dev="$1"
    if [[ -f "$MTU_DIR/$dev" ]]; then
        local MTU_ORIG=""; source "$MTU_DIR/$dev"
        [[ -n "$MTU_ORIG" ]] && ip link set mtu "$MTU_ORIG" dev "$dev" 2>/dev/null
        rm -f "$MTU_DIR/$dev"
    fi
    crontab -l 2>/dev/null | grep -v "ip link set mtu.*dev $dev" | crontab -
}
apply_all_mtu() {
    [[ ! -d "$MTU_DIR" ]] && return
    for f in "$MTU_DIR"/*; do [[ -f "$f" ]] || continue
        local dev=$(basename "$f") MTU_SET=""; source "$f"
        [[ -n "$MTU_SET" ]] && ip link set mtu "$MTU_SET" dev "$dev" 2>/dev/null
    done
}
remove_all_mtu() {
    [[ ! -d "$MTU_DIR" ]] && return
    for f in "$MTU_DIR"/*; do [[ -f "$f" ]] && reset_mtu "$(basename "$f")"; done
}

# ═══════════════ CLEANUP ═══════════════
cleanup_old() {
    local c; for c in iptables ip6tables; do
        $c -D FORWARD -j PFM_ACCOUNT 2>/dev/null || true
        $c -D FORWARD -j PFM_FORWARD 2>/dev/null || true
        $c -F PFM_ACCOUNT 2>/dev/null; $c -X PFM_ACCOUNT 2>/dev/null
        $c -F PFM_FORWARD 2>/dev/null; $c -X PFM_FORWARD 2>/dev/null
        $c -t nat -D POSTROUTING -j MASQUERADE 2>/dev/null || true
        $c -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        local chain
        for chain in FORWARD INPUT OUTPUT; do
            while $c -L $chain --line-numbers -n 2>/dev/null | grep -q "pfm_"; do
                local ln=$($c -L $chain --line-numbers -n 2>/dev/null | grep "pfm_" | head -1 | awk '{print $1}')
                [[ "$ln" =~ ^[0-9]+$ ]] && $c -D $chain "$ln" 2>/dev/null || break
            done; done
        local t; for t in "nat PREROUTING" "nat POSTROUTING"; do
            while $c -t ${t% *} -L ${t#* } --line-numbers -n 2>/dev/null | grep -q "pfm_"; do
                local ln=$($c -t ${t% *} -L ${t#* } --line-numbers -n 2>/dev/null | grep "pfm_" | head -1 | awk '{print $1}')
                [[ "$ln" =~ ^[0-9]+$ ]] && $c -t ${t% *} -D ${t#* } "$ln" 2>/dev/null || break
            done; done
        for chain in FORWARD OUTPUT; do
            while $c -t mangle -L $chain --line-numbers -n 2>/dev/null | grep -q "pfm_"; do
                local ln=$($c -t mangle -L $chain --line-numbers -n 2>/dev/null | grep "pfm_" | head -1 | awk '{print $1}')
                [[ "$ln" =~ ^[0-9]+$ ]] && $c -t mangle -D $chain "$ln" 2>/dev/null || break
            done; done
    done
}

header() {
    clear
    echo -e "  ${B}${C}"
    echo -e "        ██████╗ ███████╗███╗   ███╗"
    echo -e "        ██╔══██╗██╔════╝████╗ ████║"
    echo -e "        ██████╔╝█████╗  ██╔████╔██║"
    echo -e "        ██╔═══╝ ██╔══╝  ██║╚██╔╝██║"
    echo -e "        ██║     ██║     ██║ ╚═╝ ██║"
    echo -e "        ╚═╝     ╚═╝     ╚═╝     ╚═╝${NC}"
    echo -e "  ${C}──────────────────────────────────────────${NC}"
    echo -e "  ${B}${C}       PFM - Port Forward Manager v1.6${NC}"
    echo -e "  ${GR}            https://t.me/AbrAfagh${NC}"
    echo -e "  ${C}──────────────────────────────────────────${NC}\n"
}

# ═══════════════ PFM-CMD (used by remote bot via SSH) ═══════════════
create_bot_cmd_helper() {
    cat > /usr/local/bin/pfm-cmd << 'CMDEOF'
#!/bin/bash
# PFM command helper for bot
PFM_DIR="/etc/pfm"
PORTS_DIR="$PFM_DIR/ports"
USAGE_DIR="$PFM_DIR/usage"

gb_to_bytes() { awk "BEGIN{printf \"%.0f\",$1*1000000000}"; }

case "$1" in
    block)
        [[ ! -f "$PORTS_DIR/$2" ]] && { echo "Port not found" >&2; exit 1; }
        /usr/local/bin/pfm sync 2>/dev/null
        source "$PORTS_DIR/$2"
        # Inline block logic
        sed -i "s/P_BLOCKED=0/P_BLOCKED=1/" "$PORTS_DIR/$2"
        case "$P_METHOD" in
            haproxy)
                for p in tcp; do
                    iptables -C INPUT -p "$p" --dport "$2" -m comment --comment "pfm_block_${2}" -j DROP 2>/dev/null || \
                    iptables -I INPUT 1 -p "$p" --dport "$2" -m comment --comment "pfm_block_${2}" -j DROP
                done
                /usr/local/bin/pfm restore 2>/dev/null ;;
            realm)
                systemctl stop "pfm-realm-${2}" 2>/dev/null
                for p in tcp udp; do
                    iptables -C INPUT -p "$p" --dport "$2" -m comment --comment "pfm_block_${2}" -j DROP 2>/dev/null || \
                    iptables -I INPUT 1 -p "$p" --dport "$2" -m comment --comment "pfm_block_${2}" -j DROP
                done ;;
            *)
                for p in tcp udp; do
                    iptables -C FORWARD -p "$p" --dport "$2" -m comment --comment "pfm_block_${2}" -j DROP 2>/dev/null || \
                    iptables -I FORWARD 1 -p "$p" --dport "$2" -m comment --comment "pfm_block_${2}" -j DROP
                done ;;
        esac ;;
    unblock)
        [[ ! -f "$PORTS_DIR/$2" ]] && { echo "Port not found" >&2; exit 1; }
        source "$PORTS_DIR/$2"
        sed -i "s/P_BLOCKED=1/P_BLOCKED=0/" "$PORTS_DIR/$2"
        case "$P_METHOD" in
            haproxy)
                for p in tcp; do
                    while iptables -D INPUT -p "$p" --dport "$2" -m comment --comment "pfm_block_${2}" -j DROP 2>/dev/null; do :; done
                done
                /usr/local/bin/pfm restore 2>/dev/null ;;
            realm)
                for p in tcp udp; do
                    while iptables -D INPUT -p "$p" --dport "$2" -m comment --comment "pfm_block_${2}" -j DROP 2>/dev/null; do :; done
                done
                systemctl start "pfm-realm-${2}" 2>/dev/null ;;
            *)
                for p in tcp udp; do
                    while iptables -D FORWARD -p "$p" --dport "$2" -m comment --comment "pfm_block_${2}" -j DROP 2>/dev/null; do :; done
                done ;;
        esac ;;
    limit)
        [[ ! -f "$PORTS_DIR/$2" ]] && { echo "Port not found" >&2; exit 1; }
        nb=$(gb_to_bytes "$3")
        sed -i "s/P_LIMIT=.*/P_LIMIT=$nb/" "$PORTS_DIR/$2"
        sed -i "s/P_LIMIT_GB=.*/P_LIMIT_GB=$3/" "$PORTS_DIR/$2" ;;
    reset)
        [[ ! -f "$PORTS_DIR/$2" ]] && { echo "Port not found" >&2; exit 1; }
        echo "0" > "$USAGE_DIR/$2"
        source "$PORTS_DIR/$2"
        [[ "$P_BLOCKED" == "1" ]] && $0 unblock "$2" ;;
    addlimit)
        [[ ! -f "$PORTS_DIR/$2" ]] && { echo "Port not found" >&2; exit 1; }
        source "$PORTS_DIR/$2"
        add=$(gb_to_bytes "$3")
        new=$((P_LIMIT + add))
        newgb=$(awk "BEGIN{printf \"%.1f\",$new/1000000000}")
        sed -i "s/P_LIMIT=.*/P_LIMIT=$new/" "$PORTS_DIR/$2"
        sed -i "s/P_LIMIT_GB=.*/P_LIMIT_GB=$newgb/" "$PORTS_DIR/$2"
        [[ "$P_BLOCKED" == "1" ]] && $0 unblock "$2" ;;
    sublimit)
        [[ ! -f "$PORTS_DIR/$2" ]] && { echo "Port not found" >&2; exit 1; }
        source "$PORTS_DIR/$2"
        sub=$(gb_to_bytes "$3")
        new=$((P_LIMIT - sub))
        (( new < 0 )) && new=0
        newgb=$(awk "BEGIN{printf \"%.1f\",$new/1000000000}")
        sed -i "s/P_LIMIT=.*/P_LIMIT=$new/" "$PORTS_DIR/$2"
        sed -i "s/P_LIMIT_GB=.*/P_LIMIT_GB=$newgb/" "$PORTS_DIR/$2" ;;
    *) echo "Unknown: $1" >&2; exit 1 ;;
esac
CMDEOF
    chmod +x /usr/local/bin/pfm-cmd
}


# ═══════════════ INSTALL ═══════════════
cmd_install() {
    check_root; header
    mkdir -p "$USERS_DIR" "$PORTS_DIR" "$USAGE_DIR" "$MTU_DIR" "$REALM_DIR"
    touch "$LOG_FILE"
    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
    sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null 2>&1
    grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    grep -q "^net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf 2>/dev/null || echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
    cat > /etc/sysctl.d/99-pfm.conf << 'SYSCTL'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.netdev_max_backlog = 5000
net.core.somaxconn = 4096
net.core.optmem_max = 65536
net.netfilter.nf_conntrack_max = 131072
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.ipv4.tcp_max_tw_buckets = 32768
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
SYSCTL
    sysctl -p /etc/sysctl.d/99-pfm.conf > /dev/null 2>&1 || true
    modprobe tcp_bbr 2>/dev/null || true
    grep -q "tcp_bbr" /etc/modules-load.d/bbr.conf 2>/dev/null || echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    cleanup_old
    create_bot_cmd_helper
    (crontab -l 2>/dev/null | grep -v "pfm sync"; echo "*/5 * * * * /usr/local/bin/pfm sync > /dev/null 2>&1") | crontab -
    cat > /etc/systemd/system/pfm-restore.service << 'EOF'
[Unit]
Description=PFM Restore and Save
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/pfm restore
ExecStop=/usr/local/bin/pfm sync
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable pfm-restore.service > /dev/null 2>&1
    echo -e "  ${G}PFM v1.6 installed${NC}"
    log "PFM v1.6 installed"; sleep 1; cmd_menu
}

cmd_restore() {
    check_root
    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
    sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null 2>&1
    [[ -f /etc/sysctl.d/99-pfm.conf ]] && sysctl -p /etc/sysctl.d/99-pfm.conf > /dev/null 2>&1
    apply_all_mtu
    local need_hp=0
    for f in "$PORTS_DIR"/*; do
        [[ -f "$f" ]] || continue
        local port=$(basename "$f") P_DEST="" P_METHOD="iptables" P_BLOCKED=0; source "$f"
        case "$P_METHOD" in
            haproxy) apply_accounting_userspace "$port" "$P_DEST"; need_hp=1 ;;
            realm)   apply_accounting_userspace "$port" "$P_DEST"; create_realm_service "$port" "$P_DEST"
                     [[ "$P_BLOCKED" == "1" ]] && stop_realm_service "$port" ;;
            *)       apply_rules_iptables "$port" "$P_DEST"
                     [[ "$P_BLOCKED" == "1" ]] && block_port "$port" ;;
        esac
    done
    [[ $need_hp -eq 1 ]] && rebuild_haproxy_cfg
    log "Restored"
}

cmd_sync() {
    sync_all; check_limits
    # Health check all realm services
    for f in "$PORTS_DIR"/*; do
        [[ -f "$f" ]] || continue
        realm_health_check "$(basename "$f")"
    done
}

# ═══════════════ MENU ═══════════════
cmd_menu() {
    while true; do
        header
        echo -e "  ${W}1)${NC}  Add Tunnel"
        echo -e "  ${W}2)${NC}  Manage Tunnels"
        echo -e "  ${W}3)${NC}  View Traffic"
        echo -e "  ${W}4)${NC}  Live Monitor"
        echo -e "  ${W}5)${NC}  Users"
        echo -e "  ${W}6)${NC}  MTU Settings"
        echo -e "  ${W}7)${NC}  Delete All Tunnels"
        echo -e "  ${W}8)${NC}  ${R}Uninstall Completely${NC}"
        echo -e "  ${W}0)${NC}  Exit"
        echo -ne "\n  ${C}Select:${NC} "
        read -r opt
        case "$opt" in
            1) menu_add ;; 2) menu_manage ;; 3) menu_view ;; 4) cmd_monitor ;;
            5) menu_users ;; 6) menu_mtu ;;
            7) menu_reset ;; 8) cmd_uninstall ;;
            0) exit 0 ;;
        esac
    done
}

# ═══════════════ ADD TUNNEL ═══════════════
menu_add() {
    header; echo -e "  ${B}${W}Add Tunnel${NC}\n"
    echo -e "  ${C}Forwarding engine:${NC}"
    echo -e "    ${W}1)${NC} haproxy     ${Y}TCP only${NC}  ${GR}(splice, fastest for TCP)${NC}"
    echo -e "    ${W}2)${NC} iptables    ${GR}(kernel NAT, TCP+UDP)${NC}"
    echo -e "    ${W}3)${NC} realm       ${GR}(zero-copy, TCP+UDP)${NC}"
    echo -e "    ${W}0)${NC} Back"
    echo -ne "  ${C}Select:${NC} "; read -r mopt
    [[ "$mopt" == "0" || -z "$mopt" ]] && return
    local method="haproxy"
    case "$mopt" in
        2) method="iptables" ;;
        3) method="realm"; if ! realm_installed; then install_realm || return; fi ;;
        *) method="haproxy"; if ! haproxy_installed; then install_haproxy || return; fi ;;
    esac
    echo ""
    echo -ne "  ${C}Port:${NC} "; read -r port
    [[ -z "$port" ]] && return
    [[ -f "$PORTS_DIR/$port" ]] && { echo -e "  ${R}Port $port exists${NC}"; sleep 1; return; }
    echo -ne "  ${C}Destination IP:${NC} "; read -r dest
    [[ -z "$dest" ]] && return
    echo -ne "  ${C}Owner:${NC} "; read -r owner
    [[ -z "$owner" ]] && return
    if [[ ! -f "$USERS_DIR/$owner" ]]; then
        echo -ne "  ${Y}Telegram ID:${NC} "; read -r tgid
        echo -e "CREATED=$(date +%s)\nENABLED=1\nTG_ID=${tgid:-0}" > "$USERS_DIR/$owner"
    fi
    echo -ne "  ${C}DL Limit GB (0=unlimited):${NC} "; read -r lgb; lgb="${lgb:-0}"
    cat > "$PORTS_DIR/$port" << EOF
P_USER="$owner"
P_DEST="$dest"
P_DPORT="$port"
P_LIMIT=$(gb_to_bytes "$lgb")
P_LIMIT_GB=$lgb
P_METHOD="$method"
P_PROTO="both"
P_CREATED=$(date +%s)
P_BLOCKED=0
EOF
    echo "0" > "$USAGE_DIR/$port"
    apply_rules "$port" "$dest" "$method"
    local mtag=""; case "$method" in haproxy) mtag="${Y}haproxy${NC}";; realm) mtag="${MAG}realm${NC}";; *) mtag="${G}iptables${NC}";; esac
    echo -e "\n  ${G}OK!${NC} :${port} -> ${dest}:${port} [${mtag}]"
    log "Added $port -> $dest method=$method user=$owner"
    echo -ne "\n  ${GR}Enter...${NC}"; read -r
}

# ═══════════════ MANAGE TUNNELS ═══════════════
menu_manage() {
    while true; do
        header; sync_all
        echo -e "  ${B}${W}Manage Tunnels${NC}\n"

        # List all tunnels
        local ports=() idx=0
        for pf in "$PORTS_DIR"/*; do
            [[ -f "$pf" ]] || continue
            local lp=$(basename "$pf")
            local P_USER="" P_DEST="" P_DPORT="" P_LIMIT=0 P_BLOCKED=0 P_METHOD="iptables"
            source "$pf"
            idx=$((idx + 1))
            ports+=("$lp")
            local u=$(get_port_usage "$lp")
            local uh=$(human_bytes $u)
            local st="🟢" mclr="$G"
            [[ "$P_BLOCKED" == "1" ]] && st="🔴"
            case "$P_METHOD" in haproxy) mclr="$Y";; realm) mclr="$MAG";; esac
            printf "  ${W}%2d)${NC} Port ${C}%-6s${NC} → ${W}%-18s${NC} [${mclr}%s${NC}] %s  ${GR}%s${NC}  %s\n" \
                "$idx" "$lp" "${P_DEST}:${lp}" "$P_METHOD" "$st" "$uh" "$P_USER"
        done

        if [[ $idx -eq 0 ]]; then
            echo -e "  ${GR}No tunnels yet.${NC}"
            echo -ne "\n  ${GR}Enter...${NC}"; read -r; return
        fi

        echo -e "\n  ${W}0)${NC} Back"
        echo -ne "\n  ${C}Select tunnel:${NC} "; read -r sel
        [[ -z "$sel" || "$sel" == "0" ]] && return
        [[ ! "$sel" =~ ^[0-9]+$ || "$sel" -gt "$idx" || "$sel" -lt 1 ]] && continue

        local sport="${ports[$((sel-1))]}"
        menu_tunnel_detail "$sport"
    done
}

menu_tunnel_detail() {
    local port="$1"
    while true; do
        [[ ! -f "$PORTS_DIR/$port" ]] && return
        header
        local P_USER="" P_DEST="" P_DPORT="" P_LIMIT=0 P_LIMIT_GB=0 P_BLOCKED=0 P_METHOD="iptables"
        source "$PORTS_DIR/$port"
        local u=$(get_port_usage "$port")
        local uh=$(human_bytes $u)
        local lh="Unlimited"; [[ "$P_LIMIT" -gt 0 ]] && lh=$(human_bytes $P_LIMIT)
        local st="${G}Active${NC}"; [[ "$P_BLOCKED" == "1" ]] && st="${R}Blocked${NC}"
        local mclr="$G"; case "$P_METHOD" in haproxy) mclr="$Y";; realm) mclr="$MAG";; esac

        echo -e "  ${B}${W}Tunnel — Port ${port}${NC}\n"
        echo -e "  ${GR}Destination:${NC}  ${W}${P_DEST}:${port}${NC}"
        echo -e "  ${GR}Engine:${NC}       ${mclr}${P_METHOD}${NC}"
        echo -e "  ${GR}Owner:${NC}        ${W}${P_USER}${NC}"
        echo -e "  ${GR}Used:${NC}         ${C}${uh}${NC} / ${lh}"
        echo -e "  ${GR}Status:${NC}       ${st}"
        echo ""

        local btxt="Block"; [[ "$P_BLOCKED" == "1" ]] && btxt="Unblock"
        echo -e "  ${W}1)${NC} Edit Destination IP"
        echo -e "  ${W}2)${NC} Edit Port"
        echo -e "  ${W}3)${NC} Edit Limit"
        echo -e "  ${W}4)${NC} Edit Owner"
        echo -e "  ${W}5)${NC} Reset Usage"
        echo -e "  ${W}6)${NC} ${btxt}"
        echo -e "  ${R}7)${NC} Delete Tunnel"
        echo -e "  ${W}0)${NC} Back"
        echo -ne "\n  ${C}Select:${NC} "; read -r opt

        case "$opt" in
            1)  # Edit Destination IP
                echo -ne "  ${C}New Destination IP [${P_DEST}]:${NC} "; read -r newdest
                [[ -z "$newdest" ]] && continue
                sync_port_usage "$port"
                remove_rules "$port"
                sed -i "s|P_DEST=\"$P_DEST\"|P_DEST=\"$newdest\"|" "$PORTS_DIR/$port"
                source "$PORTS_DIR/$port"
                apply_rules "$port" "$newdest" "$P_METHOD"
                [[ "$P_BLOCKED" == "1" ]] && block_port "$port"
                rebuild_haproxy_cfg 2>/dev/null
                echo -e "  ${G}IP changed: ${P_DEST}${NC}"
                log "Edit $port dest=$newdest"; sleep 1 ;;

            2)  # Edit Port
                echo -ne "  ${C}New Port [${port}]:${NC} "; read -r newport
                [[ -z "$newport" ]] && continue
                [[ -f "$PORTS_DIR/$newport" ]] && { echo -e "  ${R}Port $newport already exists${NC}"; sleep 1; continue; }
                sync_port_usage "$port"
                remove_rules "$port"
                # Move files
                local old_usage=$(cat "$USAGE_DIR/$port" 2>/dev/null || echo 0)
                mv "$PORTS_DIR/$port" "$PORTS_DIR/$newport"
                echo "$old_usage" > "$USAGE_DIR/$newport"
                rm -f "$USAGE_DIR/$port"
                # Update port in config
                sed -i "s/P_DPORT=\"$port\"/P_DPORT=\"$newport\"/" "$PORTS_DIR/$newport"
                source "$PORTS_DIR/$newport"
                apply_rules "$newport" "$P_DEST" "$P_METHOD"
                [[ "$P_BLOCKED" == "1" ]] && block_port "$newport"
                rebuild_haproxy_cfg 2>/dev/null
                echo -e "  ${G}Port changed: ${port} → ${newport}${NC}"
                log "Edit port $port -> $newport"
                port="$newport"; sleep 1 ;;

            3)  # Edit Limit
                echo -ne "  ${C}New Limit GB (0=unlimited) [${P_LIMIT_GB}]:${NC} "; read -r newlimit
                [[ -z "$newlimit" ]] && continue
                local nb=$(gb_to_bytes "$newlimit")
                sed -i "s/P_LIMIT=.*/P_LIMIT=$nb/" "$PORTS_DIR/$port"
                sed -i "s/P_LIMIT_GB=.*/P_LIMIT_GB=$newlimit/" "$PORTS_DIR/$port"
                echo -e "  ${G}Limit set to ${newlimit} GB${NC}"
                log "Edit $port limit=$newlimit GB"; sleep 1 ;;

            4)  # Edit Owner
                echo -ne "  ${C}New Owner [${P_USER}]:${NC} "; read -r newowner
                [[ -z "$newowner" ]] && continue
                if [[ ! -f "$USERS_DIR/$newowner" ]]; then
                    echo -ne "  ${Y}User not found. Create? Telegram ID:${NC} "; read -r tgid
                    [[ -z "$tgid" ]] && continue
                    echo -e "CREATED=$(date +%s)\nENABLED=1\nTG_ID=${tgid}" > "$USERS_DIR/$newowner"
                fi
                sed -i "s/P_USER=\"$P_USER\"/P_USER=\"$newowner\"/" "$PORTS_DIR/$port"
                echo -e "  ${G}Owner changed: ${newowner}${NC}"
                log "Edit $port owner=$newowner"; sleep 1 ;;

            5)  # Reset Usage
                echo "0" > "$USAGE_DIR/$port"
                local cmd=$(ipt "$P_DEST") chain=$(get_mangle_chain "$port")
                while IFS= read -r line; do
                    if echo "$line" | grep -q "pfm_dl_${port} "; then
                        local rn=$(echo "$line" | awk '{print $1}')
                        [[ "$rn" =~ ^[0-9]+$ ]] && $cmd -t mangle -Z "$chain" "$rn" 2>/dev/null
                    fi
                done < <($cmd -t mangle -L "$chain" -v -n -x --line-numbers 2>/dev/null)
                [[ "$P_BLOCKED" == "1" ]] && unblock_port "$port"
                echo -e "  ${G}Usage reset${NC}"; sleep 1 ;;

            6)  # Block/Unblock
                if [[ "$P_BLOCKED" == "1" ]]; then
                    unblock_port "$port"
                    echo -e "  ${G}Unblocked${NC}"
                else
                    block_port "$port"
                    echo -e "  ${Y}Blocked${NC}"
                fi; sleep 1 ;;

            7)  # Delete
                echo -ne "  ${R}Delete tunnel ${port}? (y/N):${NC} "; read -r yn
                [[ "$yn" != "y" && "$yn" != "Y" ]] && continue
                sync_port_usage "$port"
                remove_rules "$port"
                rm -f "$PORTS_DIR/$port" "$USAGE_DIR/$port"
                rebuild_haproxy_cfg 2>/dev/null
                echo -e "  ${G}Tunnel ${port} deleted${NC}"
                log "Deleted $port"; sleep 1; return ;;

            0) return ;;
        esac
    done
}

# ═══════════════ VIEW ═══════════════
menu_view() {
    header; sync_all
    echo -e "  ${B}${W}Traffic${NC}  ${GR}(Download Only)${NC}"
    echo -e "  ${GR}$(printf '%.0s─' $(seq 1 82))${NC}\n"
    local has=0
    for uf in "$USERS_DIR"/*; do
        [[ -f "$uf" ]] || continue
        local name=$(basename "$uf") ENABLED="" TG_ID=""; source "$uf"
        local hp=0
        for pf in "$PORTS_DIR"/*; do [[ -f "$pf" ]] || continue; local P_USER=""; source "$pf"
            [[ "$P_USER" == "$name" ]] && { hp=1; break; }; done
        [[ $hp -eq 0 ]] && continue; has=1
        local st="ON" sc="$G"; [[ "$ENABLED" == "0" ]] && { st="OFF"; sc="$R"; }
        echo -e "  ${B}${W}${name}${NC} [${sc}${st}${NC}]  ${GR}TG:${TG_ID}${NC}\n"
        printf "  ${GR}%-7s %-18s %-9s %-13s %-13s %-10s %-8s${NC}\n" "PORT" "DESTINATION" "ENGINE" "USED" "LIMIT" "REMAIN" "STATUS"
        echo -e "  ${GR}$(printf '%.0s─' $(seq 1 82))${NC}"
        local tu=0 tl=0
        for pf in "$PORTS_DIR"/*; do
            [[ -f "$pf" ]] || continue; local lp=$(basename "$pf")
            local P_USER="" P_DEST="" P_DPORT="" P_LIMIT=0 P_LIMIT_GB=0 P_BLOCKED=0 P_METHOD="iptables"; source "$pf"
            [[ "$P_USER" != "$name" ]] && continue
            local u=$(get_port_usage "$lp")
            local uh=$(human_bytes $u) lh="Unlimited" rh="-"
            local stxt="Active" sclr="$G" uclr="$G" rclr=""
            local mclr="$G"; case "$P_METHOD" in haproxy) mclr="$Y";; realm) mclr="$MAG";; esac
            tu=$((tu+u))
            if [[ "$P_LIMIT" -gt 0 ]]; then
                lh=$(human_bytes $P_LIMIT); tl=$((tl+P_LIMIT))
                local rb=$((P_LIMIT-u)); ((rb<0))&&rb=0; rh=$(human_bytes $rb)
                local pct=$((u*100/P_LIMIT))
                ((pct>=90)) && { uclr="$R"; rclr="$R"; }; ((pct>=70&&pct<90)) && { uclr="$Y"; rclr="$Y"; }
                ((pct<70)) && rclr="$G"
            fi
            [[ "$P_BLOCKED" == "1" ]] && { stxt="Blocked"; sclr="$R"; }
            printf "  %-7s %-18s ${mclr}%-9s${NC} ${uclr}%-13s${NC} %-13s " "$lp" "${P_DEST}:${P_DPORT}" "$P_METHOD" "$uh" "$lh"
            [[ -n "$rclr" ]] && printf "${rclr}%-10s${NC} " "$rh" || printf "%-10s " "$rh"
            echo -e "${sclr}${stxt}${NC}"
        done
        echo -e "  ${GR}$(printf '%.0s─' $(seq 1 82))${NC}"
        local tlh="Unlimited" trh="-"
        [[ $tl -gt 0 ]] && { tlh=$(human_bytes $tl); local trb=$((tl-tu)); ((trb<0))&&trb=0; trh=$(human_bytes $trb); }
        printf "  ${W}%-7s %-18s %-9s %-13s %-13s %-10s${NC}\n\n" "TOTAL" "" "" "$(human_bytes $tu)" "$tlh" "$trh"
    done
    [[ $has -eq 0 ]] && echo -e "  ${GR}No tunnels yet.${NC}"
    echo -ne "  ${GR}Enter...${NC}"; read -r
}

# ═══════════════ MONITOR ═══════════════
cmd_monitor() {
    while true; do
        sync_all; clear
        echo -e "\n  ${B}${C}PFM Monitor${NC}  ${GR}$(date '+%H:%M:%S')${NC}"
        echo -e "  ${GR}$(printf '%.0s═' $(seq 1 78))${NC}"
        printf "\n  ${GR}%-7s %-18s %-9s %-8s %-15s %-6s${NC}\n" "PORT" "DEST" "ENGINE" "USER" "USED/LIMIT" "STATUS"
        echo -e "  ${GR}$(printf '%.0s─' $(seq 1 78))${NC}"
        for f in "$PORTS_DIR"/*; do
            [[ -f "$f" ]] || continue; local lp=$(basename "$f")
            local P_USER="" P_DEST="" P_DPORT="" P_LIMIT=0 P_BLOCKED=0 P_METHOD="iptables"; source "$f"
            local u=$(get_port_usage "$lp")
            local uh=$(human_bytes $u) lh="Unlim" st="ON" sc="$G" uc=""
            local mclr="$G"; case "$P_METHOD" in haproxy) mclr="$Y";; realm) mclr="$MAG";; esac
            [[ "$P_LIMIT" -gt 0 ]] && { lh=$(human_bytes $P_LIMIT); local pct=$((u*100/P_LIMIT))
                ((pct>=90)) && uc="$R"; ((pct>=70&&pct<90)) && uc="$Y"; }
            [[ "$P_BLOCKED" == "1" ]] && { st="OFF"; sc="$R"; }
            if [[ "$P_BLOCKED" != "1" ]]; then case "$P_METHOD" in
                realm) realm_is_running "$lp" || { st="ERR"; sc="$R"; } ;;
                haproxy) haproxy_is_running || { st="ERR"; sc="$R"; } ;; esac; fi
            printf "  %-7s %-18s ${mclr}%-9s${NC} %-8s " "$lp" "${P_DEST}:${P_DPORT}" "$P_METHOD" "$P_USER"
            [[ -n "$uc" ]] && printf "${uc}%-15s${NC} " "${uh}/${lh}" || printf "%-15s " "${uh}/${lh}"
            echo -e "${sc}${st}${NC}"
        done
        echo -e "  ${GR}$(printf '%.0s─' $(seq 1 78))${NC}\n  ${GR}Ctrl+C to exit${NC}"; sleep 2
    done
}

# ═══════════════ TELEGRAM BOT MENU ═══════════════

# ═══════════════ MTU ═══════════════
menu_mtu() {
    header; echo -e "  ${B}${W}MTU Settings${NC}\n"
    echo -e "  ${GR}Current MTU per interface:${NC}"
    while IFS= read -r line; do
        local dev=$(echo "$line" | awk '{print $2}' | tr -d ':')
        local mtu=$(echo "$line" | grep -oP 'mtu \K[0-9]+')
        if [[ -n "$dev" && -n "$mtu" ]]; then
            local mark=""; [[ -f "$MTU_DIR/$dev" ]] && { local MTU_ORIG=""; source "$MTU_DIR/$dev"; mark="  ${GR}(was ${MTU_ORIG})${NC}"; }
            echo -e "    ${W}${dev}${NC}  MTU=${C}${mtu}${NC}${mark}"
        fi
    done < <(ip link show 2>/dev/null | grep "^[0-9]")
    echo -e "\n  ${W}1)${NC} Set MTU  ${W}2)${NC} Reset MTU  ${W}0)${NC} Back"
    echo -ne "\n  ${C}Select:${NC} "; read -r opt
    case "$opt" in
        1)  echo -ne "  ${C}Interface:${NC} "; read -r dev; [[ -z "$dev" ]] && return
            ip link show "$dev" > /dev/null 2>&1 || { echo -e "  ${R}Not found${NC}"; sleep 1; return; }
            echo -ne "  ${C}MTU value:${NC} "; read -r val; [[ ! "$val" =~ ^[0-9]+$ ]] && return
            save_mtu "$dev" "$val"; echo -e "  ${G}${dev} = ${val} (persistent)${NC}"; sleep 1 ;;
        2)  echo -ne "  ${C}Interface to reset:${NC} "; read -r dev; [[ -z "$dev" ]] && return
            if [[ -f "$MTU_DIR/$dev" ]]; then local MTU_ORIG=""; source "$MTU_DIR/$dev"; reset_mtu "$dev"
                echo -e "  ${G}${dev} restored to ${MTU_ORIG}${NC}"
            else echo -e "  ${Y}No saved MTU${NC}"; fi; sleep 1 ;;
        0) return ;;
    esac
}

# ═══════════════ USERS ═══════════════
menu_users() {
    while true; do
        header; echo -e "  ${W}1)${NC} Add  ${W}2)${NC} Remove  ${W}3)${NC} Toggle  ${W}4)${NC} List  ${W}0)${NC} Back"
        echo -ne "  ${C}Select:${NC} "; read -r opt
        case "$opt" in
            1) echo -ne "  ${C}Name:${NC} "; read -r un; echo -ne "  ${C}TG ID:${NC} "; read -r tg
               [[ -z "$un" || -z "$tg" ]] && continue
               [[ -f "$USERS_DIR/$un" ]] && { echo -e "  ${R}Exists${NC}"; sleep 1; continue; }
               echo -e "CREATED=$(date +%s)\nENABLED=1\nTG_ID=$tg" > "$USERS_DIR/$un"
               echo -e "  ${G}OK${NC}"; sleep 1 ;;
            2) echo -ne "  ${C}Name:${NC} "; read -r un
               [[ ! -f "$USERS_DIR/$un" ]] && { echo -e "  ${R}Not found${NC}"; sleep 1; continue; }
               for pf in "$PORTS_DIR"/*; do [[ -f "$pf" ]] || continue; local P_USER=""; source "$pf"
                   [[ "$P_USER" == "$un" ]] && { local lp=$(basename "$pf"); sync_port_usage "$lp"; remove_rules "$lp"
                   rm -f "$PORTS_DIR/$lp" "$USAGE_DIR/$lp"; }; done; rm -f "$USERS_DIR/$un"
               rebuild_haproxy_cfg 2>/dev/null; echo -e "  ${G}Removed${NC}"; sleep 1 ;;
            3) echo -ne "  ${C}Name:${NC} "; read -r un
               [[ ! -f "$USERS_DIR/$un" ]] && { echo -e "  ${R}Not found${NC}"; sleep 1; continue; }
               local ENABLED=""; source "$USERS_DIR/$un"
               if [[ "$ENABLED" == "1" ]]; then
                   sed -i "s/ENABLED=1/ENABLED=0/" "$USERS_DIR/$un"
                   for pf in "$PORTS_DIR"/*; do [[ -f "$pf" ]] || continue; source "$pf"
                       [[ "$P_USER" == "$un" ]] && block_port "$(basename "$pf")"; done
                   echo -e "  ${Y}Disabled${NC}"
               else
                   sed -i "s/ENABLED=0/ENABLED=1/" "$USERS_DIR/$un"
                   for pf in "$PORTS_DIR"/*; do [[ -f "$pf" ]] || continue; source "$pf"
                       [[ "$P_USER" == "$un" ]] && unblock_port "$(basename "$pf")"; done
                   echo -e "  ${G}Enabled${NC}"
               fi; sleep 1 ;;
            4) header; for uf in "$USERS_DIR"/*; do [[ -f "$uf" ]] || continue
                   local n=$(basename "$uf") ENABLED="" TG_ID=""; source "$uf"
                   local s="ON" c="$G"; [[ "$ENABLED" == "0" ]] && { s="OFF"; c="$R"; }
                   echo -e "  ${W}$n${NC} [${c}${s}${NC}] TG:${TG_ID}"; done
               echo -ne "\n  ${GR}Enter...${NC}"; read -r ;;
            0) return ;;
        esac
    done
}

# ═══════════════ PORTS ═══════════════
menu_ports() {
    while true; do
        header; echo -e "  ${W}1)${NC} Remove  ${W}2)${NC} Limit  ${W}3)${NC} Reset Usage  ${W}4)${NC} Block/Unblock  ${W}0)${NC} Back"
        echo -ne "  ${C}Select:${NC} "; read -r opt
        case "$opt" in
            1) echo -ne "  ${C}Port:${NC} "; read -r p; [[ ! -f "$PORTS_DIR/$p" ]] && { echo -e "  ${R}Not found${NC}"; sleep 1; continue; }
               sync_port_usage "$p"; remove_rules "$p"; rm -f "$PORTS_DIR/$p" "$USAGE_DIR/$p"
               rebuild_haproxy_cfg 2>/dev/null; echo -e "  ${G}Removed${NC}"; sleep 1 ;;
            2) echo -ne "  ${C}Port:${NC} "; read -r p; [[ ! -f "$PORTS_DIR/$p" ]] && { echo -e "  ${R}Not found${NC}"; sleep 1; continue; }
               echo -ne "  ${C}New limit GB:${NC} "; read -r nl
               sed -i "s/P_LIMIT=.*/P_LIMIT=$(gb_to_bytes "$nl")/" "$PORTS_DIR/$p"
               sed -i "s/P_LIMIT_GB=.*/P_LIMIT_GB=$nl/" "$PORTS_DIR/$p"; echo -e "  ${G}OK${NC}"; sleep 1 ;;
            3) echo -ne "  ${C}Port:${NC} "; read -r p; [[ ! -f "$PORTS_DIR/$p" ]] && { echo -e "  ${R}Not found${NC}"; sleep 1; continue; }
               echo "0" > "$USAGE_DIR/$p"; local P_DEST="" P_BLOCKED=0 P_METHOD="iptables"; source "$PORTS_DIR/$p"
               local cmd=$(ipt "$P_DEST") chain=$(get_mangle_chain "$p")
               while IFS= read -r line; do
                   echo "$line" | grep -q "pfm_dl_${p} " && { local rn=$(echo "$line"|awk '{print $1}')
                   [[ "$rn" =~ ^[0-9]+$ ]] && $cmd -t mangle -Z "$chain" "$rn" 2>/dev/null; }
               done < <($cmd -t mangle -L "$chain" -v -n -x --line-numbers 2>/dev/null)
               [[ "$P_BLOCKED" == "1" ]] && unblock_port "$p"; echo -e "  ${G}Reset OK${NC}"; sleep 1 ;;
            4) echo -ne "  ${C}Port:${NC} "; read -r p; [[ ! -f "$PORTS_DIR/$p" ]] && { echo -e "  ${R}Not found${NC}"; sleep 1; continue; }
               local P_BLOCKED=0; source "$PORTS_DIR/$p"
               if [[ "$P_BLOCKED" == "1" ]]; then unblock_port "$p"; echo -e "  ${G}Unblocked${NC}"
               else block_port "$p"; echo -e "  ${Y}Blocked${NC}"; fi; sleep 1 ;;
            0) return ;;
        esac
    done
}

menu_reset() {
    header; echo -ne "  ${R}Delete ALL tunnels? Type YES:${NC} "; read -r c
    [[ "$c" != "YES" ]] && return
    for f in "$PORTS_DIR"/*; do [[ -f "$f" ]] && remove_rules "$(basename "$f")"; done
    rm -f "$PORTS_DIR"/* "$USAGE_DIR"/*; rebuild_haproxy_cfg 2>/dev/null
    echo -e "  ${G}All tunnels deleted${NC}"; log "Reset"; echo -ne "  ${GR}Enter...${NC}"; read -r
}

cmd_json() {
    # NO sync here - caller is responsible (bot: pfm sync; pfm json / menu: sync_all before)
    echo "{\"timestamp\":$(date +%s),\"users\":["
    local fu=1; for uf in "$USERS_DIR"/*; do [[ -f "$uf" ]] || continue
        local name=$(basename "$uf") ENABLED="" TG_ID=""; source "$uf"
        [[ $fu -eq 0 ]] && echo ","; fu=0
        echo "{\"name\":\"$name\",\"tg_id\":\"$TG_ID\",\"enabled\":$ENABLED,\"ports\":["
        local fp=1; for pf in "$PORTS_DIR"/*; do [[ -f "$pf" ]] || continue
            local P_USER="" P_DEST="" P_DPORT="" P_LIMIT=0 P_LIMIT_GB=0 P_BLOCKED=0 P_METHOD="iptables"; source "$pf"
            if [[ "$P_USER" == "$name" ]]; then
                local lp=$(basename "$pf")
                local u=$(cat "$USAGE_DIR/$lp" 2>/dev/null || echo 0)
                [[ $fp -eq 0 ]] && echo ","; fp=0
                echo "{\"port\":$lp,\"dest\":\"${P_DEST}:${P_DPORT}\",\"method\":\"$P_METHOD\",\"dl_bytes\":$u,\"dl_human\":\"$(human_bytes $u)\",\"limit_bytes\":$P_LIMIT,\"limit_gb\":$P_LIMIT_GB,\"blocked\":$P_BLOCKED}"
            fi; done; echo -n "]}"; done; echo "]}"
}

cmd_uninstall() {
    check_root
    echo -e "\n  ${R}${B}This will remove EVERYTHING:${NC}"
    echo -e "  ${GR}- All tunnels and rules${NC}"
    echo -e "  ${GR}- All users and traffic data${NC}"
    echo -e "  ${GR}- HAProxy config and service${NC}"
    echo -e "  ${GR}- Realm services and binary${NC}"
    echo -e "  ${GR}- MTU settings${NC}"
    echo -e "  ${GR}- PFM config and binary${NC}"
    echo -ne "\n  ${R}Type YES to confirm:${NC} "; read -r c
    [[ "$c" != "YES" ]] && return
    for f in "$PORTS_DIR"/*; do [[ -f "$f" ]] && remove_rules "$(basename "$f")"; done
    cleanup_old; remove_all_mtu
    for svc in /etc/systemd/system/pfm-realm-*.service; do
        [[ -f "$svc" ]] && { local sn=$(basename "$svc" .service); systemctl stop "$sn" 2>/dev/null; systemctl disable "$sn" 2>/dev/null; rm -f "$svc"; }
    done
    rm -f "$REALM_BIN"
    systemctl stop pfm-haproxy pfm-bot 2>/dev/null
    systemctl disable pfm-haproxy pfm-bot 2>/dev/null
    rm -f /etc/systemd/system/pfm-haproxy.service /etc/systemd/system/pfm-bot.service
    systemctl daemon-reload
    crontab -l 2>/dev/null | grep -v "pfm sync" | grep -v "ip link set mtu" | crontab -
    systemctl disable pfm-restore.service pfm-save.service 2>/dev/null || true
    rm -f /etc/systemd/system/pfm-restore.service /etc/systemd/system/pfm-save.service
    rm -rf "$PFM_DIR" /usr/local/bin/pfm /usr/local/bin/pfm-bot /usr/local/bin/pfm-cmd /etc/sysctl.d/99-pfm.conf "$LOG_FILE"
    systemctl daemon-reload
    echo -e "\n  ${G}PFM completely removed${NC}"; exit 0
}

main() {
    case "${1:-menu}" in
        install) cmd_install ;; uninstall) cmd_uninstall ;;
        restore) cmd_restore ;; sync) cmd_sync ;;
        json) cmd_json ;; monitor) cmd_monitor ;;
        *) check_root; cmd_menu ;;
    esac
}

main "$@"
