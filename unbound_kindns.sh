#!/usr/bin/env bash
# unbound_kindns.sh - Recursive DNS and OSPF Routing Deploy in Docker or Podman
# Installs Docker or Podman, Compose, and configures Unbound (compiled), FRR, and Chrony.
# Author: Marcelo Gondim <gondim@gmail.com>
# Version: 1.1.1

# Loads system environment variables to preserve existing values
if [ -f /etc/environment ]; then
    # set -a exports all loaded variables from the file
    set -a
    source /etc/environment
    set +a
fi

# ==============================================================================
# DEPLOY SETTINGS (Adjust the values below before running the script)
# ==============================================================================
CORES="4"         # CPU cores dedicated to Unbound (defines num-threads in local.conf)
OSPF_INTERFACE="" # Physical interface for OSPF (e.g. ens20). If empty, disables Anycast (FRR/teste_dns)
APPARMOR="0"      # 0 to disable (performance) or 1 to enable AppArmor
MITIGATIONS="off" # off to turn CPU mitigations off (performance) or auto for automatic
CONTAINER_ENGINE="${CONTAINER_ENGINE:-docker}" # Container engine: docker (default) or podman
ZBX_HOSTNAME="${ZBX_HOSTNAME:-}" # Zabbix Hostname identifier (empty = uses OS hostname)
CERT_DOMAIN="${CERT_DOMAIN:-doh.brasil.com.br}" # Let's Encrypt domain for DOH/DOT
ZBX_SERVER_HOST="${ZBX_SERVER_HOST:-127.0.0.1}" # Zabbix Server IP
ZBX_SERVER_ACTIVE="${ZBX_SERVER_ACTIVE:-127.0.0.1}" # Active Zabbix Server IP
ZBX_LISTENIP="${ZBX_LISTENIP:-0.0.0.0}" # Zabbix Agent 2 listen IP
# ==============================================================================

set -Eeuo pipefail

# Constants/Colors
COLOR_RESET="\033[0m"
COLOR_INFO="\033[1;34m"
COLOR_SUCCESS="\033[1;32m"
COLOR_WARN="\033[1;33m"
COLOR_ERROR="\033[1;31m"

log_info()    { echo -e "${COLOR_INFO}[INFO]${COLOR_RESET} $*"; }
log_success() { echo -e "${COLOR_SUCCESS}[SUCCESS]${COLOR_RESET} $*"; }
log_warn()    { echo -e "${COLOR_WARN}[WARN]${COLOR_RESET} $*"; }
log_error()   { echo -e "${COLOR_ERROR}[ERROR]${COLOR_RESET} $*"; }

setup_terminal() {
    if [ -t 1 ] && command -v tput &>/dev/null; then
        tput smcup
        local lines
        lines=$(tput lines)
        tput csr 12 $((lines - 1))
        clear
        draw_banner
        tput cup 12 0
    fi
}

draw_banner() {
    local AMBER="\033[38;5;214m"
    local RESET="\033[0m"
    
    tput cup 0 0
    echo -ne "${AMBER}"
    cat << 'EOF'
'##::::'##:'##::: ##:'########:::'#######::'##::::'##:'##::: ##:'########:::::::::::'##:::'##:'####:'##::: ##:'########::'##::: ##::'######::
 ##:::: ##: ###:: ##: ##.... ##:'##.... ##: ##:::: ##: ###:: ##: ##.... ##:::::::::: ##::'##::. ##:: ###:: ##: ##.... ##: ###:: ##:'##... ##:
 ##:::: ##: ####: ##: ##:::: ##: ##:::: ##: ##:::: ##: ####: ##: ##:::: ##:::::::::: ##:'##:::: ##:: ####: ##: ##:::: ##: ####: ##: ##:::..::
 ##:::: ##: ## ## ##: ########:: ##:::: ##: ##:::: ##: ## ## ##: ##:::: ##:'#######: #####::::: ##:: ## ## ##: ##:::: ##: ## ## ##:. ######::
 ##:::: ##: ##. ####: ##.... ##: ##:::: ##: ##:::: ##: ##. ####: ##:::: ##:........: ##. ##:::: ##:: ##. ####: ##:::: ##: ##. ####::..... ##:
 ##:::: ##: ##:. ###: ##:::: ##: ##:::: ##: ##:::: ##: ##:. ###: ##:::: ##:::::::::: ##:. ##::: ##:: ##:. ###: ##:::: ##: ##:. ###:'##::: ##:
. #######:: ##::. ##: ########::. #######::. #######:: ##::. ##: ########::::::::::: ##::. ##:'####: ##::. ##: ########:: ##::. ##:. ######::
:.......:::..::::..::........::::.......::::.......:::..::::..::........::::::::::::..::::..::....::..::::..::........:::..::::..:::......:::
============================================================================================================================================================
EOF
    printf "Hostname: %-22s | Engine: %-8s | OSPF: %-15s | Cores: %s\n" "${HOSTNAME}" "${CONTAINER_ENGINE^^}" "${OSPF_INTERFACE:-N/A}" "${CORES}"
    printf "Version: %-26s | Author: %-33s | %s\n" "1.1.1" "Marcelo Gondim <gondim@gmail.com>" "https://ispfocus.net.br"
    echo -e "============================================================================================================================================================${RESET}"
}

cleanup_terminal() {
    local exit_code=$?
    if [ -t 1 ] && command -v tput &>/dev/null; then
        if [ $exit_code -ne 0 ]; then
            echo ""
            log_error "An error occurred during script execution (Exit code: $exit_code)."
            read -p "Press [Enter] to exit and return to the terminal..."
        fi
        local lines
        lines=$(tput lines)
        tput csr 0 $((lines - 1))
        tput rmcup
        if [ $exit_code -eq 0 ]; then
            clear
        fi
    fi
}

setup_grub_tuning() {
    log_info "Configuring AppArmor=$APPARMOR and Mitigations=$MITIGATIONS in Grub..."
    mkdir -p /etc/default/grub.d
    cat << EOF > /etc/default/grub.d/apparmor.cfg
GRUB_CMDLINE_LINUX_DEFAULT="\$GRUB_CMDLINE_LINUX_DEFAULT mitigations=$MITIGATIONS apparmor=$APPARMOR"
EOF
    if command -v update-grub &>/dev/null; then
        update-grub
        log_success "Grub settings saved. A host reboot will be required to apply them."
    else
        log_warn "'update-grub' command not found on the host."
    fi
}

# Validates command line parameters and options
HOSTNAME=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --engine|-e)
            if [ -n "${2:-}" ]; then
                CONTAINER_ENGINE="${2,,}"
                shift 2
            else
                log_error "Option $1 requires an argument (docker or podman)."
                exit 1
            fi
            ;;
        --engine=*)
            CONTAINER_ENGINE="${1#*=}"
            CONTAINER_ENGINE="${CONTAINER_ENGINE,,}"
            shift
            ;;
        -h|--help)
            echo "Usage: sudo $0 [OPTIONS] <HOSTNAME>"
            echo ""
            echo "Options:"
            echo "  -e, --engine <docker|podman>  Container engine to use (default: docker)"
            echo "  -h, --help                    Show this help message"
            echo ""
            echo "Example:"
            echo "  sudo $0 AMA-UNBOUND-01"
            echo "  sudo $0 --engine podman AMA-UNBOUND-01"
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            log_error "Usage: sudo $0 [-e docker|podman] <HOSTNAME>"
            exit 1
            ;;
        *)
            if [ -z "${HOSTNAME}" ]; then
                HOSTNAME="$1"
            else
                log_warn "Ignoring extra argument: $1"
            fi
            shift
            ;;
    esac
done

if [ -z "${HOSTNAME}" ]; then
    log_error "Error: You must specify the HOSTNAME as a script parameter!"
    log_error "Usage: sudo $0 [-e docker|podman] <HOSTNAME>"
    log_error "Example: sudo $0 AMA-UNBOUND-01"
    log_error "Example: sudo $0 --engine podman AMA-UNBOUND-01"
    exit 1
fi

if [ "${CONTAINER_ENGINE}" != "docker" ] && [ "${CONTAINER_ENGINE}" != "podman" ]; then
    log_warn "Unknown engine '${CONTAINER_ENGINE}'. Defaulting to 'docker'."
    CONTAINER_ENGINE="docker"
fi

if [ "${CONTAINER_ENGINE}" = "podman" ]; then
    VOL_BASE="/var/lib/containers/storage/volumes"
    CTR_CMD="podman"
    COMPOSE_CMD="podman compose"
else
    VOL_BASE="/var/lib/docker/volumes"
    CTR_CMD="docker"
    COMPOSE_CMD="docker compose"
fi

if [ -z "${ZBX_HOSTNAME}" ]; then
    ZBX_HOSTNAME="${HOSTNAME}"
fi

# Configures terminal and registers restoration trap
trap cleanup_terminal EXIT
setup_terminal

setup_hostname() {
    log_info "Configuring host hostname to $HOSTNAME..."
    echo "$HOSTNAME" > /etc/hostname
    hostname -F /etc/hostname

    log_info "Configuring /etc/hosts..."
    cat << EOF > /etc/hosts
127.0.0.1       localhost
127.0.1.1       $HOSTNAME

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

    log_info "Configuring public DNS resolvers in /etc/resolv.conf..."
    cat << EOF > /etc/resolv.conf
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 2001:4860:4860::8888
EOF
    log_success "Hostname, hosts and resolv.conf configured on the host."
}

setup_kernel_tuning() {
    log_info "Configuring Kernel optimizations (sysctl)..."
    cat << EOF > /etc/sysctl.d/51-net-core.conf
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.netdev_max_backlog=5000
net.core.optmem_max=33554432
net.core.somaxconn=4096
EOF

    cat << EOF > /etc/sysctl.d/90-override.conf
net.core.default_qdisc=fq
EOF

    cat << EOF > /etc/sysctl.d/52-net-tcp-ipv4.conf
net.ipv4.tcp_sack=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_max_syn_backlog=4096
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_max_tw_buckets=2000000
net.ipv4.tcp_syn_retries=5
net.ipv4.tcp_synack_retries=5
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.secure_redirects=0
net.ipv4.conf.default.secure_redirects=0
EOF

    cat << EOF > /etc/sysctl.d/56-port-range-ipv4.conf
net.ipv4.ip_local_port_range=1024 65535
EOF

    cat << EOF > /etc/sysctl.d/62-default-ttl-ipv4.conf
net.ipv4.ip_default_ttl=128
EOF

    cat << EOF > /etc/sysctl.d/63-neigh-ipv4.conf
net.ipv4.neigh.default.gc_interval = 30
net.ipv4.neigh.default.gc_stale_time = 60
net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 8192
net.ipv4.neigh.default.gc_thresh3 = 12288

net.ipv4.ipfrag_high_thresh=4194304
net.ipv4.ipfrag_low_thresh=3145728
net.ipv4.ipfrag_max_dist=64
net.ipv4.ipfrag_secret_interval=0
net.ipv4.ipfrag_time=30
EOF

    cat << EOF > /etc/sysctl.d/64-neigh-ipv6.conf
net.ipv6.neigh.default.gc_interval = 30
net.ipv6.neigh.default.gc_stale_time = 60
net.ipv6.neigh.default.gc_thresh1 = 4096
net.ipv6.neigh.default.gc_thresh2 = 8192
net.ipv6.neigh.default.gc_thresh3 = 12288

net.ipv6.ip6frag_high_thresh=4194304
net.ipv6.ip6frag_low_thresh=3145728
net.ipv6.ip6frag_secret_interval=0
net.ipv6.ip6frag_time=60
EOF

    cat << EOF > /etc/sysctl.d/65-default-foward-ipv4.conf
net.ipv4.conf.default.forwarding=1
EOF

    cat << EOF > /etc/sysctl.d/66-default-foward-ipv6.conf
net.ipv6.conf.default.forwarding=1
EOF

    cat << EOF > /etc/sysctl.d/67-all-foward-ipv4.conf
net.ipv4.conf.all.forwarding=1
EOF

    cat << EOF > /etc/sysctl.d/68-all-foward-ipv6.conf
net.ipv6.conf.all.forwarding=1
EOF

    cat << EOF > /etc/sysctl.d/69-ipv4-forward.conf
net.ipv4.ip_forward=1
EOF

    cat << EOF > /etc/sysctl.d/72-fs-options.conf
fs.file-max = 9223372036854775807
fs.aio-max-nr=3263776
fs.mount-max=1048576
fs.mqueue.msg_max=128
fs.mqueue.msgsize_max=131072
fs.mqueue.queues_max=4096
fs.pipe-max-size=8388608
EOF

    cat << EOF > /etc/sysctl.d/73-swappiness.conf 
vm.swappiness=1
EOF

    cat << EOF > /etc/sysctl.d/74-vfs-cache-pressure.conf
vm.vfs_cache_pressure=100
EOF

    cat << EOF > /etc/sysctl.d/81-kernel-panic.conf
kernel.panic=3
EOF

    cat << EOF > /etc/sysctl.d/82-kernel-threads.conf
kernel.threads-max=1031306
EOF

    cat << EOF > /etc/sysctl.d/83-kernel-pid.conf
kernel.pid_max=4194304
EOF

    cat << EOF > /etc/sysctl.d/84-kernel-msgmax.conf
kernel.msgmax=327680
EOF

    cat << EOF > /etc/sysctl.d/85-kernel-msgmnb.conf
kernel.msgmnb=655360
EOF

    cat << EOF > /etc/sysctl.d/86-kernel-msgmni.conf
kernel.msgmni=32768
EOF

    cat << EOF > /etc/sysctl.d/87-kernel-free-min-kb.conf
vm.min_free_kbytes=90112
EOF

    cat << EOF > /etc/sysctl.d/90-netfilter-max.conf
net.nf_conntrack_max=8000000
EOF

    cat << EOF > /etc/sysctl.d/91-netfilter-generic.conf
net.netfilter.nf_conntrack_buckets=512000
net.netfilter.nf_conntrack_checksum=1
net.netfilter.nf_conntrack_events=1
net.netfilter.nf_conntrack_expect_max=4096
net.netfilter.nf_conntrack_timestamp=0
EOF

    cat << EOF > /etc/sysctl.d/93-netfilter-icmp.conf
net.netfilter.nf_conntrack_icmp_timeout=30
net.netfilter.nf_conntrack_icmpv6_timeout=30
EOF

    cat << EOF > /etc/sysctl.d/94-netfilter-tcp.conf
net.netfilter.nf_conntrack_tcp_be_liberal=0
net.netfilter.nf_conntrack_tcp_loose=1
net.netfilter.nf_conntrack_tcp_max_retrans=3
net.netfilter.nf_conntrack_tcp_timeout_close=10
net.netfilter.nf_conntrack_tcp_timeout_close_wait=10
net.netfilter.nf_conntrack_tcp_timeout_established=600
net.netfilter.nf_conntrack_tcp_timeout_fin_wait=10
net.netfilter.nf_conntrack_tcp_timeout_last_ack=10
net.netfilter.nf_conntrack_tcp_timeout_max_retrans=60
net.netfilter.nf_conntrack_tcp_timeout_syn_recv=5
net.netfilter.nf_conntrack_tcp_timeout_syn_sent=5
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
net.netfilter.nf_conntrack_tcp_timeout_unacknowledged=300
EOF

    cat << EOF > /etc/sysctl.d/95-netfilter-udp.conf
net.netfilter.nf_conntrack_udp_timeout=30
net.netfilter.nf_conntrack_udp_timeout_stream=180
EOF

    cat << EOF > /etc/sysctl.d/96-netfilter-sctp.conf
net.netfilter.nf_conntrack_sctp_timeout_closed=10
net.netfilter.nf_conntrack_sctp_timeout_cookie_echoed=3
net.netfilter.nf_conntrack_sctp_timeout_cookie_wait=3
net.netfilter.nf_conntrack_sctp_timeout_established=432000
net.netfilter.nf_conntrack_sctp_timeout_heartbeat_acked=210
net.netfilter.nf_conntrack_sctp_timeout_heartbeat_sent=30
net.netfilter.nf_conntrack_sctp_timeout_shutdown_ack_sent=3
net.netfilter.nf_conntrack_sctp_timeout_shutdown_recd=0
net.netfilter.nf_conntrack_sctp_timeout_shutdown_sent=0
EOF

    cat << EOF > /etc/sysctl.d/97-netfilter-dccp.conf
net.netfilter.nf_conntrack_dccp_loose=1
net.netfilter.nf_conntrack_dccp_timeout_closereq=64
net.netfilter.nf_conntrack_dccp_timeout_closing=64
net.netfilter.nf_conntrack_dccp_timeout_open=43200
net.netfilter.nf_conntrack_dccp_timeout_partopen=480
net.netfilter.nf_conntrack_dccp_timeout_request=240
net.netfilter.nf_conntrack_dccp_timeout_respond=480
net.netfilter.nf_conntrack_dccp_timeout_timewait=240
EOF

    cat << EOF > /etc/sysctl.d/99-netfilter-ipv6.conf
net.netfilter.nf_conntrack_frag6_high_thresh=4194304
net.netfilter.nf_conntrack_frag6_low_thresh=3145728
net.netfilter.nf_conntrack_frag6_timeout=60
EOF

    cat << EOF > /etc/sysctl.d/100-fs-inotify.conf
fs.inotify.max_user_watches=524288
EOF

    echo nf_conntrack > /etc/modules-load.d/conntrack.conf
    echo tcp_bbr > /etc/modules-load.d/tcp_bbr.conf
    modprobe nf_conntrack 2>/dev/null || true
    modprobe tcp_bbr 2>/dev/null || true
    sysctl --system

    log_info "Configuring system file limits..."
    ulimit -n 65536
    cat << 'EOF' > /etc/security/limits.d/99-ispfocus.conf
# Limits for high performance
* soft nofile 65536
* hard nofile 65536
root soft nofile 65536
root hard nofile 65536
EOF

    log_info "Configuring disable-thp.service..."
    cat << EOF > /etc/systemd/system/disable-thp.service
[Unit]
Description=Disables Transparent Huge Pages (THP) if supported by the Kernel
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c "if [ -d /sys/kernel/mm/transparent_hugepage ]; then echo never > /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/defrag; else echo 'THP is not supported by this Kernel (e.g. Raspberry Pi)'; fi"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now disable-thp || true

    log_info "Installing system utilities and IRQBalance..."
    apt-get update && apt-get -y install needrestart grc net-tools nftables htop iotop sipcalc tcpdump vim-nox curl gnupg rsync wget bind9-host bind9-dnsutils mtr-tiny bmon sudo tmux whois ethtool dnstop apparmor-utils openssl openssh-client openssh-server iproute2 nmap ncdu bind9-utils conntrack psmisc uuid uuid-runtime fping zstd rsyslog apticron logwatch irqbalance || true
    systemctl enable --now irqbalance || true

    log_info "Configuring bash prompt and history for root..."
    cat << 'EOF' > /root/.bash_profile
PS1='\[\e[1;34m\]\342\224\214\342\224\200\[\e[1;34m\][\[\e[1;36m\]\u\[\e[1;33m\]@\[\e[1;37m\]\h\[\e[1;34m\]]\[\e[1;34m\]\342\224\200\[\e[1;34m\][\[\e[1;33m\]\w\[\e[1;34m\]]\[\e[1;34m\]\342\224\200[\[\e[1;37m\]\d \t\[\e[1;34m\]]\n\[\e[1;34m\]\342\224\224\342\224\200\342\224\200\342\225\274\[\e[1;32m\] \$ \[\e[0m\]'

alias l="ls -la --color=auto"
alias rm="rm -i"
alias mv="mv -i"
alias cp="cp -i"

alias grep='grep --color'
alias egrep='egrep --color'
alias ip='ip -c'
alias diff='diff --color'
alias tail='grc tail'
alias ping='grc ping'
alias ps='grc ps'
EOF
    echo 'export HISTTIMEFORMAT="%d/%m/%y %T "' >> /root/.bash_profile

    log_info "Configuring /root/.vimrc..."
    cat << 'EOF' > /root/.vimrc
syntax on
set number
set background=dark
EOF
    log_success "Kernel and system optimizations configured on the host."
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root."
        exit 1
    fi
}

install_docker() {
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        log_success "Docker and Docker Compose are already installed."
        return
    fi

    log_info "Installing prerequisite dependencies..."
    apt-get update
    apt-get install -y ca-certificates curl gnupg lsb-release

    log_info "Adding official Docker repository..."
    mkdir -p /etc/apt/keyrings
    rm -f /etc/apt/keyrings/docker.gpg
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    log_info "Installing Docker Engine and Docker Compose..."
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    log_success "Docker and Docker Compose successfully installed."
}

setup_docker_dns() {
    log_info "Configuring public fallback DNS for the Docker daemon..."
    mkdir -p /etc/docker
    local restart_needed=false
    if [ ! -f /etc/docker/daemon.json ]; then
        echo '{"dns": ["1.1.1.1", "8.8.8.8"]}' > /etc/docker/daemon.json
        restart_needed=true
    else
        if ! grep -q '"dns"' /etc/docker/daemon.json; then
            cp /etc/docker/daemon.json /etc/docker/daemon.json.bak 2>/dev/null || true
            echo '{"dns": ["1.1.1.1", "8.8.8.8"]}' > /etc/docker/daemon.json
            restart_needed=true
        fi
    fi

    if [ "$restart_needed" = true ]; then
        systemctl restart docker || true
        log_success "Docker daemon fallback DNS configured and service restarted."
    else
        log_success "Docker daemon fallback DNS already configured."
    fi
}

install_podman() {
    local apparmor_conf=""
    if [ "${APPARMOR}" = "0" ]; then
        apparmor_conf=$'\napparmor_profile = "unconfined"'
    fi

    write_configs() {
        mkdir -p /etc/containers/registries.conf.d /etc/containers/containers.conf.d
        echo 'unqualified-search-registries = ["docker.io", "quay.io"]' > /etc/containers/registries.conf
        echo 'unqualified-search-registries = ["docker.io", "quay.io"]' > /etc/containers/registries.conf.d/01-registries.conf
        cat << EOF > /etc/containers/containers.conf
[engine]
compose_warning_logs = false
runtime = "crun"

[containers]${apparmor_conf}
dns_servers = ["1.1.1.1", "8.8.8.8"]
EOF
        cat << EOF > /etc/containers/containers.conf.d/01-compose.conf
[engine]
compose_warning_logs = false
runtime = "crun"

[containers]${apparmor_conf}
dns_servers = ["1.1.1.1", "8.8.8.8"]
EOF
    }

    if command -v podman &>/dev/null && podman compose version &>/dev/null; then
        systemctl enable --now podman.socket 2>/dev/null || true
        systemctl enable --now podman-restart.service 2>/dev/null || true
        write_configs
        log_success "Podman and Podman Compose are already installed and configured."
        return
    fi

    log_info "Installing prerequisite dependencies..."
    apt-get update
    apt-get install -y ca-certificates curl gnupg lsb-release

    log_info "Installing Podman, Podman Compose, native tools and OCI runtimes (runc, crun)..."
    apt-get install -y podman podman-compose catatonit buildah runc crun

    log_info "Enabling and starting Podman API socket and auto-restart service..."
    systemctl enable --now podman.socket
    systemctl enable --now podman-restart.service

    log_info "Configuring container registries and Podman preferences..."
    write_configs

    log_success "Podman, Podman Compose, runtimes and services successfully configured."
}

install_container_engine() {
    if [ "${CONTAINER_ENGINE}" = "podman" ]; then
        install_podman
    else
        install_docker
        setup_docker_dns
    fi
}

setup_container_volumes() {
    log_info "Creating named volumes for engine (${CONTAINER_ENGINE})..."
    ${CTR_CMD} volume create chrony_config &>/dev/null || true
    ${CTR_CMD} volume create chrony_lib &>/dev/null || true
    ${CTR_CMD} volume create frr_config &>/dev/null || true
    ${CTR_CMD} volume create unbound_config &>/dev/null || true
    ${CTR_CMD} volume create unbound_lib &>/dev/null || true
    ${CTR_CMD} volume create zabbix_agent2_config &>/dev/null || true
    log_success "Volumes for engine (${CONTAINER_ENGINE}) created successfully."
}

apply_apparmor_compose_tuning() {
    local compose_file="$1"
    if [ "${APPARMOR}" = "0" ] && [ -f "${compose_file}" ]; then
        if ! grep -q "apparmor=unconfined" "${compose_file}"; then
            sed -i '/restart: always/a \    security_opt:\n      - apparmor=unconfined' "${compose_file}"
        fi
    fi
}

setup_chrony() {
    log_info "Configuring Chrony in /usr/local/src/chrony..."
    local base_dir="/usr/local/src/chrony"
    mkdir -p "${base_dir}"

    # docker-compose.yml
    cat << 'EOF' > "${base_dir}/docker-compose.yml"
services:
  chrony:
    build:
      context: .
    container_name: chrony
    network_mode: host
    restart: always
    cap_add:
      - SYS_TIME
    volumes:
      - chrony_config:/etc/chrony
      - chrony_lib:/var/lib/chrony
      - /etc/localtime:/etc/localtime:ro
      - /etc/timezone:/etc/timezone:ro

volumes:
  chrony_config:
    external: true
  chrony_lib:
    external: true
EOF
    apply_apparmor_compose_tuning "${base_dir}/docker-compose.yml"

    # Dockerfile
    cat << 'EOF' > "${base_dir}/Dockerfile"
FROM alpine:latest
RUN apk add --no-cache chrony
ENTRYPOINT ["/usr/sbin/chronyd", "-d", "-s"]
EOF

    local config_dir="${VOL_BASE}/chrony_config/_data"
    mkdir -p "${config_dir}/sources.d" "${config_dir}/conf.d"

    # chrony.conf
    if [[ ! -f "${config_dir}/chrony.conf" ]]; then
        cat << 'EOF' > "${config_dir}/chrony.conf"
confdir /etc/chrony/conf.d
driftfile /var/lib/chrony/chrony.drift
keyfile /etc/chrony/chrony.keys
leapsectz right/UTC
log measurements statistics tracking rtc refclocks tempcomp
logdir /var/log/chrony
makestep 1 3
maxntsconnections 1024
maxupdateskew 100.0
ntsdumpdir /var/lib/chrony
rtcsync
sourcedir /etc/chrony/sources.d
EOF
    fi

    # nic.sources
    if [[ ! -f "${config_dir}/sources.d/nic.sources" ]]; then
        cat << 'EOF' > "${config_dir}/sources.d/nic.sources"
server a.st1.ntp.br iburst nts
server b.st1.ntp.br iburst nts
server c.st1.ntp.br iburst nts
server d.st1.ntp.br iburst nts
EOF
    fi

    # ntp_acl.conf
    if [[ ! -f "${config_dir}/conf.d/ntp_acl.conf" ]]; then
        cat << 'EOF' > "${config_dir}/conf.d/ntp_acl.conf"
# Allowed Private Networks
allow 100.64.0.0/10
allow 10.0.0.0/8
allow 172.16.0.0/12
allow 192.168.0.0/16
EOF
    fi

    log_success "Chrony structure created."
}

setup_frr() {
    log_info "Configuring FRR in /usr/local/src/frr..."
    local base_dir="/usr/local/src/frr"
    mkdir -p "${base_dir}"

    # docker-compose.yml
    cat << 'EOF' > "${base_dir}/docker-compose.yml"
services:
  frr:
    image: quay.io/frrouting/frr:10.0.1
    container_name: frr
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
      - NET_RAW
      - SYS_ADMIN
    volumes:
      - frr_config:/etc/frr
      - /etc/localtime:/etc/localtime:ro
      - /etc/timezone:/etc/timezone:ro

volumes:
  frr_config:
    external: true
EOF
    apply_apparmor_compose_tuning "${base_dir}/docker-compose.yml"

    local config_dir="${VOL_BASE}/frr_config/_data"
    mkdir -p "${config_dir}"

    # daemons
    if [[ ! -f "${config_dir}/daemons" ]]; then
        cat << 'EOF' > "${config_dir}/daemons"
zebra=yes
bgpd=no
ospfd=yes
ospf6d=yes
ripd=no
ripngd=no
isisd=no
pimd=no
ldpd=no
nhrpd=no
eigrpd=no
babeld=no
sharpd=no
pbrd=no
bfdd=no
fabricd=no
vrrpd=no
pathd=no
gpz=no
EOF
    fi

    # vtysh.conf
    if [[ ! -f "${config_dir}/vtysh.conf" ]]; then
        cat << EOF > "${config_dir}/vtysh.conf"
service integrated-vtysh-config
hostname ${HOSTNAME}
username root nopassword
EOF
    fi

    # frr.conf
    if [[ ! -f "${config_dir}/frr.conf" ]]; then
        cat << EOF > "${config_dir}/frr.conf"
!
frr version 10.0.1
frr defaults traditional
hostname ${HOSTNAME}
log syslog informational
no ip forwarding
no ipv6 forwarding
service integrated-vtysh-config
!
ip prefix-list NO-DEFAULT seq 5 deny 0.0.0.0/0
ip prefix-list NO-DEFAULT seq 10 permit any
!
ipv6 prefix-list NO-DEFAULTv6 seq 5 deny ::/0
ipv6 prefix-list NO-DEFAULTv6 seq 10 permit any
!
route-map BLOCK-DEFAULT permit 10
 match ip address prefix-list NO-DEFAULT
exit
!
route-map BLOCK-DEFAULTv6 permit 10
 match ipv6 address prefix-list NO-DEFAULTv6
exit
!
interface ${OSPF_INTERFACE}
 ip ospf area 0.0.0.0
 ip ospf message-digest-key 5 md5 Cu3Xhmf2
 ip ospf network point-to-point
 ipv6 ospf6 area 0.0.0.0
 ipv6 ospf6 network point-to-point
exit
!
interface lo
 description LOOPBACKS
 ip ospf area 0.0.0.0
 ip ospf passive
 ipv6 ospf6 area 0.0.0.0
 ipv6 ospf6 passive
exit
!
router ospf
 ospf router-id 172.20.24.14
 area 0 authentication message-digest
exit
!
router ospf6
 ospf6 router-id 172.20.24.14
exit
!
ip protocol ospf route-map BLOCK-DEFAULT
!
ipv6 protocol ospf6 route-map BLOCK-DEFAULTv6
!
end
EOF
    fi

    # Adjusts secure permissions for the 'frr' user/group (UID/GID 92) of the container
    chown -R 92:92 "${config_dir}"
    chmod 750 "${config_dir}"
    chmod 640 "${config_dir}"/*

    log_success "FRR structure created."
}

setup_unbound() {
    log_info "Configuring Unbound in /usr/local/src/unbound..."
    local base_dir="/usr/local/src/unbound"
    mkdir -p "${base_dir}"

    # entrypoint.sh
    cat << 'EOF' > "${base_dir}/entrypoint.sh"
#!/bin/sh
set -e

# Initializes the DNSSEC anchor key (root.key) if it does not exist
if [ ! -f /var/lib/unbound/root.key ]; then
    echo "Initializing DNSSEC anchor key (root.key)..."
    mkdir -p /var/lib/unbound
    unbound-anchor -a /var/lib/unbound/root.key || true
fi

# Ensures the unbound user has write permission in the data volume
mkdir -p /var/lib/unbound
chown -R unbound:unbound /var/lib/unbound

exec "$@"
EOF
    chmod +x "${base_dir}/entrypoint.sh"
    
    mkdir -p /var/log/unbound
    chown -R 88:88 /var/log/unbound
    chmod 750 /var/log/unbound
    touch /var/log/unbound/unbound.log
    chown 88:88 /var/log/unbound/unbound.log

    # docker-compose.yml
    cat << 'EOF' > "${base_dir}/docker-compose.yml"
services:
  unbound:
    build:
      context: .
    container_name: unbound
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    volumes:
      - unbound_config:/etc/unbound
      - unbound_lib:/var/lib/unbound
      - /var/log/unbound:/var/log/unbound
      - /etc/localtime:/etc/localtime:ro
      - /etc/timezone:/etc/timezone:ro

volumes:
  unbound_config:
    external: true
  unbound_lib:
    external: true
EOF
    apply_apparmor_compose_tuning "${base_dir}/docker-compose.yml"

    # Dockerfile
    cat << 'EOF' > "${base_dir}/Dockerfile"
# Stage 1: Compiling Unbound
FROM alpine:latest AS builder

RUN apk add --no-cache \
    build-base \
    libevent-dev \
    openssl-dev \
    expat-dev \
    nghttp2-dev \
    fstrm-dev \
    protobuf-c-dev \
    hiredis-dev \
    python3-dev \
    swig \
    bison \
    flex \
    ca-certificates \
    wget \
    curl-dev

# Downloads and installs named.root (root.hints)
RUN mkdir -p /usr/share/dns && \
    wget -S https://www.internic.net/domain/named.root -O /usr/share/dns/root.hints

WORKDIR /src
RUN wget https://nlnetlabs.nl/downloads/unbound/unbound-latest.tar.gz && \
    tar xzf unbound-latest.tar.gz && \
    rm unbound-latest.tar.gz && \
    mv unbound-* unbound-src

WORKDIR /src/unbound-src

# Advanced compilation flags aligned with Debian rules
RUN ./configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --runstatedir=/run \
    --disable-rpath \
    --with-run-dir=/var/run \
    --with-conf-file=/etc/unbound/unbound.conf \
    --with-pidfile=/run/unbound.pid \
    --with-rootkey-file=/usr/share/dns/root.key \
    --with-root-hints=/usr/share/dns/root.hints \
    --with-dnstap-socket-path=/run/dnstap.sock \
    --with-libevent \
    --with-pthreads \
    --with-libnghttp2 \
    --enable-subnet \
    --enable-dnstap \
    --enable-tfo-client \
    --enable-tfo-server \
    --enable-cachedb \
    --with-libhiredis \
    --with-pythonmodule \
    --with-pyunbound \
    --with-ssl \
    --with-libcurl

RUN make -j$(nproc) && make install

# Stage 2: Final runtime execution image
FROM alpine:latest

# Installs only dynamic dependencies at runtime, including python3
RUN apk add --no-cache \
    libevent \
    openssl \
    expat \
    nghttp2 \
    fstrm \
    protobuf-c \
    hiredis \
    python3 \
    tzdata \
    ca-certificates \
    bind-tools \
    libcurl

COPY --from=builder /usr/sbin/unbound /usr/sbin/unbound
COPY --from=builder /usr/sbin/unbound-anchor /usr/sbin/unbound-anchor
COPY --from=builder /usr/sbin/unbound-checkconf /usr/sbin/unbound-checkconf
COPY --from=builder /usr/sbin/unbound-control /usr/sbin/unbound-control
COPY --from=builder /usr/sbin/unbound-control-setup /usr/sbin/unbound-control-setup
COPY --from=builder /usr/share/dns /usr/share/dns
COPY --from=builder /usr/lib/python3* /usr/lib/
COPY --from=builder /usr/lib/libunbound* /usr/lib/

# Creates default UID/GID 88 for the unbound user in Alpine
RUN addgroup -g 88 -S unbound && \
    adduser -u 88 -S -D -H -h /etc/unbound -s /sbin/nologin -G unbound unbound

RUN mkdir -p /etc/unbound /var/log/unbound /var/run && \
    chown -R unbound:unbound /etc/unbound /var/log/unbound

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh



ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/sbin/unbound", "-d", "-c", "/etc/unbound/unbound.conf"]
EOF

    local config_dir="${VOL_BASE}/unbound_config/_data"
    local lib_dir="${VOL_BASE}/unbound_lib/_data"
    mkdir -p "${config_dir}/unbound.conf.d"
    mkdir -p "${lib_dir}"

    # unbound.conf
    if [[ ! -f "${config_dir}/unbound.conf" ]]; then
        cat << 'EOF' > "${config_dir}/unbound.conf"
# Unbound base configuration file
include: "/etc/unbound/unbound.conf.d/*.conf"
EOF
    fi

    # local.conf
    if [[ ! -f "${config_dir}/unbound.conf.d/local.conf" ]]; then
        cat << EOF > "${config_dir}/unbound.conf.d/local.conf"
server:
        verbosity: 1
        statistics-interval: 0
        statistics-cumulative: no
        extended-statistics: yes
        num-threads: ${CORES}
        serve-expired: yes
        interface: 127.0.0.1
        #interface: 198.12.224.1
        #interface: 198.12.224.2
        #interface: 198.12.224.1@443
        #interface: 198.12.224.2@443
        #interface: 198.12.224.1@853
        #interface: 198.12.224.2@853
        #interface: 172.20.54.110
        interface: ::1
        interface-automatic: no
        #outgoing-interface: 177.XX.XX.46
        #outgoing-interface: 2804:XXXX:c900:4::2
        outgoing-range: 8192
        outgoing-num-tcp: 1024
        incoming-num-tcp: 2048
        so-rcvbuf: 4m
        so-sndbuf: 4m
        so-reuseport: yes
        edns-buffer-size: 1232
        msg-cache-size: 1g
        msg-cache-slabs: 4
        num-queries-per-thread: 4096
        rrset-cache-size: 2g
        rrset-cache-slabs: 4
        infra-cache-slabs: 4
        do-ip4: yes
        do-ip6: yes
        do-udp: yes
        do-tcp: yes
        chroot: ""
        username: "unbound"
        directory: "/etc/unbound"
        logfile: "/var/log/unbound/unbound.log"
        use-syslog: no
        log-time-ascii: yes
        log-queries: no
        pidfile: "/var/run/unbound.pid"
        root-hints: "/usr/share/dns/root.hints"
        hide-identity: yes
        hide-version: yes
        unwanted-reply-threshold: 10000000
        prefetch: yes
        prefetch-key: yes
        rrset-roundrobin: yes
        minimal-responses: yes
        module-config: "respip validator iterator"
        val-clean-additional: yes
        val-log-level: 1
        key-cache-slabs: 4
        deny-any: yes
        cache-min-ttl: 60
        key-cache-size: 128m
        neg-cache-size: 64m
        cache-max-ttl: 86400
        infra-cache-numhosts: 100000
        #tls-service-key: "/etc/unbound/privkey.pem"
        #tls-service-pem: "/etc/unbound/fullchain.pem"

python:

auth-zone:
    name: "."
    master: "b.root-servers.net"
    master: "c.root-servers.net"
    master: "d.root-servers.net"
    master: "f.root-servers.net"
    master: "g.root-servers.net"
    master: "k.root-servers.net"
    master: "lax.xfr.dns.icann.org"
    master: "iad.xfr.dns.icann.org"
    fallback-enabled: yes
    for-downstream: no
    for-upstream: yes
    zonefile: "/var/lib/unbound/root.zone"

auth-zone:
    name: "arpa."
    master: "lax.xfr.dns.icann.org"
    master: "iad.xfr.dns.icann.org"
    fallback-enabled: yes
    for-downstream: no
    for-upstream: yes
    zonefile: "/var/lib/unbound/arpa.zone"
EOF
    fi

    # controle-acesso.conf
    if [[ ! -f "${config_dir}/unbound.conf.d/controle-acesso.conf" ]]; then
        cat << 'EOF' > "${config_dir}/unbound.conf.d/controle-acesso.conf"
server:
    # List of allowed recursive networks
    # Private
    access-control: 100.64.0.0/10 allow
    access-control: 10.0.0.0/8 allow
    access-control: 172.16.0.0/12 allow
    access-control: 192.168.0.0/16 allow
EOF
    fi





    # root-auto-trust-anchor-file.conf
    if [[ ! -f "${config_dir}/unbound.conf.d/root-auto-trust-anchor-file.conf" ]]; then
        cat << 'EOF' > "${config_dir}/unbound.conf.d/root-auto-trust-anchor-file.conf"
server:
        auto-trust-anchor-file: "/var/lib/unbound/root.key"
EOF
    fi

    # remote-control.conf
    if [[ ! -f "${config_dir}/unbound.conf.d/remote-control.conf" ]]; then
        cat << 'EOF' > "${config_dir}/unbound.conf.d/remote-control.conf"
remote-control:
        control-enable: yes
        control-interface: 127.0.0.1
        control-interface: ::1
        control-port: 8953
        server-key-file: "/etc/unbound/unbound_server.key"
        server-cert-file: "/etc/unbound/unbound_server.pem"
        control-key-file: "/etc/unbound/unbound_control.key"
        control-cert-file: "/etc/unbound/unbound_control.pem"
EOF
    fi

    # Adjusts permissions of the unbound user (UID/GID 88) of the container
    local lib_dir="${VOL_BASE}/unbound_lib/_data"
    mkdir -p "${lib_dir}"
    chown -R 88:88 "${config_dir}"
    chown -R 88:88 "${lib_dir}" 2>/dev/null || true

    # Configuração de Logrotate para o Unbound Containerizado no Host
    log_info "Configuring logrotate for Unbound on host..."
    cat << EOF > /etc/logrotate.d/unbound
/var/log/unbound/unbound.log {
    rotate 5
    weekly
    missingok
    notifempty
    compress
    delaycompress
    create 0640 88 88
    postrotate
        ${CTR_CMD} exec unbound unbound-control log_reopen >/dev/null 2>&1 || true
    endscript
}
EOF
    chmod 644 /etc/logrotate.d/unbound
    if systemctl is-active --quiet logrotate.service || systemctl is-enabled --quiet logrotate.service &>/dev/null; then
        systemctl restart logrotate.service || true
    fi

    log_success "Unbound structure created."
}



setup_zabbix_agent2() {
    log_info "Configuring Zabbix Agent 2 in /usr/local/src/zabbix-agent2..."
    local base_dir="/usr/local/src/zabbix-agent2"
    mkdir -p "${base_dir}"

    local engine_sock="/var/run/docker.sock"
    if [ "${CONTAINER_ENGINE}" = "podman" ]; then
        engine_sock="/run/podman/podman.sock"
    fi

    # docker-compose.yml
    cat << EOF > "${base_dir}/docker-compose.yml"
services:
  zabbix-agent2:
    image: docker.io/zabbix/zabbix-agent2:alpine-7.0-latest
    container_name: zabbix-agent2
    network_mode: host
    restart: always
    privileged: true
    user: root
    init: true
    stop_signal: SIGINT
    stop_grace_period: 3s
    volumes:
      - zabbix_agent2_config:/etc/zabbix
      - ${engine_sock}:/var/run/docker.sock:ro
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /etc/localtime:/etc/localtime:ro
      - /etc/timezone:/etc/timezone:ro
    tmpfs:
      - /run/zabbix:size=10M,mode=0777
      - /var/run/zabbix:size=10M,mode=0777
    env_file:
      - /etc/environment

volumes:
  zabbix_agent2_config:
    external: true
EOF
    apply_apparmor_compose_tuning "${base_dir}/docker-compose.yml"

    # Ensures the volume data folder starts clean only if it is a new installation
    local config_dir="${VOL_BASE}/zabbix_agent2_config/_data"
    if [ -d "${config_dir}" ] && [ ! -f "${config_dir}/zabbix_agent2.conf" ]; then
        rm -rf "${config_dir}"/*
    fi

    log_success "Zabbix Agent 2 structure created."
}

setup_host_environment() {
    log_info "Configuring environment and helper scripts on the host..."
    mkdir -p /root/scripts /root/backup /root/download

    # Configures the CERT_DOMAIN environment variable in /etc/environment
    touch /etc/environment
    if ! grep -q "CERT_DOMAIN=" /etc/environment; then
        echo "CERT_DOMAIN=\"${CERT_DOMAIN}\"" >> /etc/environment
    else
        sed -i "s|CERT_DOMAIN=.*|CERT_DOMAIN=\"${CERT_DOMAIN}\"|" /etc/environment
    fi

    # Configures Hostname and Zabbix variables in /etc/environment
    for var in ZBX_HOSTNAME ZBX_SERVER_HOST ZBX_SERVER_ACTIVE ZBX_LISTENIP; do
        if ! grep -q "^${var}=" /etc/environment; then
            echo "${var}=\"${!var}\"" >> /etc/environment
        else
            sed -i "s|^${var}=.*|${var}=\"${!var}\"|" /etc/environment
        fi
    done

    # 1. Zabbix Stats Sender (unboundSend.sh)
    cat << 'EOF' > /root/scripts/unboundSend.sh
#!/bin/bash
# Adapted for Docker and Podman
if [ -z ${1} ] || [ -z ${2} ] ; then
        echo "Usage: ./unboundSend.sh <ZABBIX_SERVER_IP> <HOST_NAME>"
        exit 1
fi
IP_ZABBIX=$1
NAME_HOST=$2
DIR_TEMP=/var/tmp/
FILE="${DIR_TEMP}dump_unbound_control_stats.txt"
FILE_PREV="${DIR_TEMP}unboundSend.${NAME_HOST}.last_vals.txt"
STATE_TS="${DIR_TEMP}unboundSend.${NAME_HOST}.last_ts"

NOW=$(date +%s)
ELAPSED=300
FIRST_RUN=1
if [ -f "${STATE_TS}" ]; then
    PREV_TS=$(cat "${STATE_TS}")
    if [ -n "${PREV_TS}" ] && [ "${PREV_TS}" -gt 0 ] 2>/dev/null; then
        ELAPSED=$(( NOW - PREV_TS ))
        FIRST_RUN=0
    fi
fi

# Detects container engine (podman or docker)
CTR="docker"
if [ -S /run/podman/podman.sock ] || { command -v podman &>/dev/null && podman ps -a --filter "name=unbound" 2>/dev/null | grep -q unbound; }; then
    CTR="podman"
fi

# Collects statistics using stats_noreset from inside the container
${CTR} exec unbound unbound-control stats_noreset > ${FILE}
echo "${NOW}" > "${STATE_TS}"
 
TOTAL_NUM_QUERIES=$(cat ${FILE} | grep -w 'total.num.queries' | cut -d '=' -f2)
TOTAL_NUM_CACHEHITS=$(cat ${FILE} | grep -w 'total.num.cachehits' | cut -d '=' -f2)
TOTAL_NUM_CACHEMISS=$(cat ${FILE} | grep -w 'total.num.cachemiss' | cut -d '=' -f2)
TOTAL_NUM_PREFETCH=$(cat ${FILE} | grep -w 'total.num.prefetch' | cut -d '=' -f2)
TOTAL_NUM_RECURSIVEREPLIES=$(cat ${FILE} | grep -w 'total.num.recursivereplies' | cut -d '=' -f2)
TOTAL_REQ_MAX=$(cat ${FILE} | grep -w 'total.requestlist.max' | cut -d '=' -f2)
TOTAL_REQ_AVG=$(cat ${FILE} | grep -w 'total.requestlist.avg' | cut -d '=' -f2)
TOTAL_REQ_OVERWRITTEN=$(cat ${FILE} | grep -w 'total.requestlist.overwritten' | cut -d '=' -f2)
TOTAL_REQ_EXCEEDED=$(cat ${FILE} | grep -w 'total.requestlist.exceeded' | cut -d '=' -f2)
TOTAL_REQ_CURRENT_ALL=$(cat ${FILE} | grep -w 'total.requestlist.current.all' | cut -d '=' -f2)
TOTAL_REQ_CURRENT_USER=$(cat ${FILE} | grep -w 'total.requestlist.current.user' | cut -d '=' -f2)
TOTAL_TCPUSAGE=$(cat ${FILE} | grep -w 'total.tcpusage' | cut -d '=' -f2)
NUM_QUERY_TYPE_A=$(cat ${FILE} | grep -w 'num.query.type.A' | cut -d '=' -f2)
NUM_QUERY_TYPE_NS=$(cat ${FILE} | grep -w 'num.query.type.NS' | cut -d '=' -f2)
NUM_QUERY_TYPE_MX=$(cat ${FILE} | grep -w 'num.query.type.MX' | cut -d '=' -f2)
NUM_QUERY_TYPE_TXT=$(cat ${FILE} | grep -w 'num.query.type.TXT' | cut -d '=' -f2)
NUM_QUERY_TYPE_PTR=$(cat ${FILE} | grep -w 'num.query.type.PTR' | cut -d '=' -f2)
NUM_QUERY_TYPE_AAAA=$(cat ${FILE} | grep -w 'num.query.type.AAAA' | cut -d '=' -f2)
NUM_QUERY_TYPE_SRV=$(cat ${FILE} | grep -w 'num.query.type.SRV' | cut -d '=' -f2)
NUM_QUERY_TYPE_SOA=$(cat ${FILE} | grep -w 'num.query.type.SOA' | cut -d '=' -f2)
NUM_QUERY_TYPE_HTTPS=$(cat ${FILE} | grep -w 'num.query.type.HTTPS' | cut -d '=' -f2)
NUM_QUERY_TYPE_TYPE0=$(cat ${FILE} | grep -w 'num.query.type.TYPE0' | cut -d '=' -f2)
NUM_QUERY_TYPE_CNAME=$(cat ${FILE} | grep -w 'num.query.type.CNAME' | cut -d '=' -f2)
NUM_QUERY_TYPE_WKS=$(cat ${FILE} | grep -w 'num.query.type.WKS' | cut -d '=' -f2)
NUM_QUERY_TYPE_HINFO=$(cat ${FILE} | grep -w 'num.query.type.HINFO' | cut -d '=' -f2)
NUM_QUERY_TYPE_X25=$(cat ${FILE} | grep -w 'num.query.type.X25' | cut -d '=' -f2)
NUM_QUERY_TYPE_NAPTR=$(cat ${FILE} | grep -w 'num.query.type.NAPTR' | cut -d '=' -f2)
NUM_QUERY_TYPE_DS=$(cat ${FILE} | grep -w 'num.query.type.DS' | cut -d '=' -f2)
NUM_QUERY_TYPE_DNSKEY=$(cat ${FILE} | grep -w 'num.query.type.DNSKEY' | cut -d '=' -f2)
NUM_QUERY_TYPE_TLSA=$(cat ${FILE} | grep -w 'num.query.type.TLSA' | cut -d '=' -f2)
NUM_QUERY_TYPE_SVCB=$(cat ${FILE} | grep -w 'num.query.type.SVCB' | cut -d '=' -f2)
NUM_QUERY_TYPE_SPF=$(cat ${FILE} | grep -w 'num.query.type.SPF' | cut -d '=' -f2)
NUM_QUERY_TYPE_ANY=$(cat ${FILE} | grep -w 'num.query.type.ANY' | cut -d '=' -f2)
NUM_QUERY_TYPE_OTHER=$(cat ${FILE} | grep -w 'num.query.type.other' | cut -d '=' -f2)
NUM_ANSWER_RCODE_NOERROR=$(cat ${FILE} | grep -w 'num.answer.rcode.NOERROR' | cut -d '=' -f2)
NUM_ANSWER_RCODE_NXDOMAIN=$(cat ${FILE} | grep -w 'num.answer.rcode.NXDOMAIN' | cut -d '=' -f2)
NUM_ANSWER_RCODE_SERVFAIL=$(cat ${FILE} | grep -w 'num.answer.rcode.SERVFAIL' | cut -d '=' -f2)
NUM_ANSWER_RCODE_REFUSED=$(cat ${FILE} | grep -w 'num.answer.rcode.REFUSED' | cut -d '=' -f2)
NUM_ANSWER_RCODE_nodata=$(cat ${FILE} | grep -w 'num.answer.rcode.nodata' | cut -d '=' -f2)
NUM_ANSWER_secure=$(cat ${FILE} | grep -w 'num.answer.secure' | cut -d '=' -f2)

send_rate() {
    local file_key="$1"
    local zbx_key="$2"
    local cur_val="$3"
    if [ "${FIRST_RUN}" -eq 1 ] || [ ! -f "${FILE_PREV}" ]; then return; fi
    local prev_val
    prev_val=$(cat "${FILE_PREV}" | grep -w "${file_key}" | cut -d '=' -f2)
    prev_val=${prev_val:-0}
    if ! [[ "$cur_val" =~ ^[0-9]+$ ]]; then cur_val=0; fi
    if ! [[ "$prev_val" =~ ^[0-9]+$ ]]; then prev_val=0; fi
    local diff
    if [ "$cur_val" -ge "$prev_val" ]; then
        diff=$(( cur_val - prev_val ))
    else
        diff="$cur_val"
    fi
    local rate
    rate=$(LC_NUMERIC=C awk -v d="${diff}" -v e="${ELAPSED}" 'BEGIN{ printf "%.4f", d/e }')
    zabbix_sender -z "${IP_ZABBIX}" -s "${NAME_HOST}" -k "${zbx_key}" -o "${rate}" >/dev/null 2>&1
}

send_rate total.num.queries          total.num.queries          "${TOTAL_NUM_QUERIES}"
send_rate total.num.cachehits        total.num.cachehits        "${TOTAL_NUM_CACHEHITS}"
send_rate total.num.cachemiss        total.num.cachemiss        "${TOTAL_NUM_CACHEMISS}"
send_rate total.num.prefetch         total.num.prefetch         "${TOTAL_NUM_PREFETCH}"
send_rate total.num.recursivereplies total.num.recursivereplies "${TOTAL_NUM_RECURSIVEREPLIES}"
zabbix_sender -z ${IP_ZABBIX} -s ${NAME_HOST} -k total.requestlist.max          -o "${TOTAL_REQ_MAX:-0}"          >/dev/null 2>&1
zabbix_sender -z ${IP_ZABBIX} -s ${NAME_HOST} -k total.requestlist.avg          -o "${TOTAL_REQ_AVG:-0}"          >/dev/null 2>&1
zabbix_sender -z ${IP_ZABBIX} -s ${NAME_HOST} -k total.requestlist.current.all  -o "${TOTAL_REQ_CURRENT_ALL:-0}"  >/dev/null 2>&1
zabbix_sender -z ${IP_ZABBIX} -s ${NAME_HOST} -k total.requestlist.current.user -o "${TOTAL_REQ_CURRENT_USER:-0}" >/dev/null 2>&1
zabbix_sender -z ${IP_ZABBIX} -s ${NAME_HOST} -k total.tcpusage                 -o "${TOTAL_TCPUSAGE:-0}"                 >/dev/null 2>&1
send_rate total.requestlist.overwritten total.requestlist.overwritten "${TOTAL_REQ_OVERWRITTEN}"
send_rate total.requestlist.exceeded    total.requestlist.exceeded    "${TOTAL_REQ_EXCEEDED}"
send_rate num.query.type.A     num.query.a     "${NUM_QUERY_TYPE_A}"
send_rate num.query.type.NS    num.query.ns    "${NUM_QUERY_TYPE_NS}"
send_rate num.query.type.MX    num.query.mx    "${NUM_QUERY_TYPE_MX}"
send_rate num.query.type.TXT   num.query.txt   "${NUM_QUERY_TYPE_TXT}"
send_rate num.query.type.PTR   num.query.ptr   "${NUM_QUERY_TYPE_PTR}"
send_rate num.query.type.AAAA  num.query.aaaa  "${NUM_QUERY_TYPE_AAAA}"
send_rate num.query.type.SRV   num.query.srv   "${NUM_QUERY_TYPE_SRV}"
send_rate num.query.type.SOA   num.query.soa   "${NUM_QUERY_TYPE_SOA}"
send_rate num.query.type.HTTPS num.query.https "${NUM_QUERY_TYPE_HTTPS}"
send_rate num.query.type.TYPE0 num.query.type0 "${NUM_QUERY_TYPE_TYPE0}"
send_rate num.query.type.CNAME num.query.cname "${NUM_QUERY_TYPE_CNAME}"
send_rate num.query.type.WKS   num.query.wks   "${NUM_QUERY_TYPE_WKS}"
send_rate num.query.type.HINFO num.query.hinfo "${NUM_QUERY_TYPE_HINFO}"
send_rate num.query.type.X25   num.query.X25   "${NUM_QUERY_TYPE_X25}"
send_rate num.query.type.NAPTR num.query.naptr "${NUM_QUERY_TYPE_NAPTR}"
send_rate num.query.type.DS    num.query.ds    "${NUM_QUERY_TYPE_DS}"
send_rate num.query.type.DNSKEY num.query.dnskey "${NUM_QUERY_TYPE_DNSKEY}"
send_rate num.query.type.TLSA  num.query.tlsa  "${NUM_QUERY_TYPE_TLSA}"
send_rate num.query.type.SVCB  num.query.svcb  "${NUM_QUERY_TYPE_SVCB}"
send_rate num.query.type.SPF   num.query.spf   "${NUM_QUERY_TYPE_SPF}"
send_rate num.query.type.ANY   num.query.any   "${NUM_QUERY_TYPE_ANY}"
send_rate num.query.type.other num.query.other "${NUM_QUERY_TYPE_OTHER}"
send_rate num.answer.rcode.NOERROR  num.answer.rcode.NOERROR  "${NUM_ANSWER_RCODE_NOERROR}"
send_rate num.answer.rcode.NXDOMAIN num.answer.rcode.NXDOMAIN "${NUM_ANSWER_RCODE_NXDOMAIN}"
send_rate num.answer.rcode.SERVFAIL num.answer.rcode.SERVFAIL "${NUM_ANSWER_RCODE_SERVFAIL}"
send_rate num.answer.rcode.REFUSED  num.answer.rcode.REFUSED  "${NUM_ANSWER_RCODE_REFUSED}"
send_rate num.answer.rcode.nodata   num.answer.rcode.nodata   "${NUM_ANSWER_RCODE_nodata}"
send_rate num.answer.secure         num.answer.secure         "${NUM_ANSWER_secure}"

cp "${FILE}" "${FILE_PREV}"
EOF
    chmod 700 /root/scripts/unboundSend.sh

    # 2. Test DNS & Anycast Gating (teste_dns.sh) - Only if OSPF_INTERFACE is defined
    if [ -n "${OSPF_INTERFACE}" ]; then
        cat << 'EOF' > /root/scripts/teste_dns.sh
#!/usr/bin/env bash
# ==============================================================================
# Script: /root/scripts/teste_dns.sh
# Função: Health-check de DNS Recursivo e Gating Anycast (OSPFv2 / OSPFv3 / BGP)
# Suporte: Docker CE e Podman (Daemonless) com Self-Healing e Máquina de Estados
# ==============================================================================

dominios_testar=(
www.google.com
www.terra.com.br
www.uol.com.br
www.globo.com
www.facebook.com
www.youtube.com
www.twitch.com
www.discord.com
www.debian.org
www.redhat.com
)
corte_taxa_falha=100
STATE_FILE="/run/teste_dns.state"

# 1. Detecção da Engine de Container
CTR_BIN="${CTR_CMD:-}"
if ! command -v "${CTR_BIN}" >/dev/null 2>&1; then
    if command -v podman >/dev/null 2>&1; then CTR_BIN="podman"; else CTR_BIN="docker"; fi
fi

# 2. Descoberta Automática de IPs Anycast da Loopback
V4_LOOPBACKS=$(ip -o -4 addr show dev lo scope global 2>/dev/null | awk '{print $4}')
V6_LOOPBACKS=$(ip -o -6 addr show dev lo scope global 2>/dev/null | awk '{print $4}')

# 3. Descoberta dos Protocolos Ativos no FRR
RUNNING_CONFIG=$(${CTR_BIN} exec frr vtysh -c 'show running-config' 2>/dev/null || true)
DAEMONS_LIST=$(${CTR_BIN} exec frr vtysh -c 'show daemons' 2>/dev/null || true)

HAS_OSPF2="no"
if echo "$DAEMONS_LIST" | grep -qw "ospfd" || echo "$RUNNING_CONFIG" | grep -q "^router ospf\b"; then
   HAS_OSPF2="yes"
fi

HAS_OSPF3="no"
if echo "$DAEMONS_LIST" | grep -qw "ospf6d" || echo "$RUNNING_CONFIG" | grep -q "^router ospf6\b"; then
   HAS_OSPF3="yes"
fi

HAS_BGP="no"
if echo "$DAEMONS_LIST" | grep -qw "bgpd" || echo "$RUNNING_CONFIG" | grep -q "^router bgp "; then
   HAS_BGP="yes"
fi

BGP_ASN=$(echo "$RUNNING_CONFIG" | awk '/^router bgp / {print $3}' | head -n 1)

is_anycast_active() {
   local run_cfg
   run_cfg=$(${CTR_BIN} exec frr vtysh -c 'show running-config' 2>/dev/null || true)
   local lo_block
   lo_block=$(echo "$run_cfg" | awk '/^interface lo$/,/^exit$/')

   if [ "$HAS_OSPF2" = "yes" ] && echo "$lo_block" | grep -q "ip ospf area"; then
      return 0
   fi

   if [ "$HAS_OSPF3" = "yes" ] && echo "$lo_block" | grep -q "ipv6 ospf6 area"; then
      return 0
   fi

   if [ "$HAS_BGP" = "yes" ]; then
      for net in $V4_LOOPBACKS $V6_LOOPBACKS; do
         if echo "$run_cfg" | grep -q "network $net"; then
            return 0
         fi
      done
   fi

   return 1
}

# Inicialização da Máquina de Estados
CURRENT_STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "")
if [ -z "$CURRENT_STATE" ]; then
   if is_anycast_active; then
      CURRENT_STATE="UP"
      echo "UP" > "$STATE_FILE"
   else
      CURRENT_STATE="DOWN"
      echo "DOWN" > "$STATE_FILE"
   fi
fi

remove_ospf() {
   local VTYSH_ARGS=("-c" "conf t" "-c" "interface lo")
   local NEED=0

   if [ "$HAS_OSPF2" = "yes" ]; then
      VTYSH_ARGS+=("-c" "no ip ospf area 0.0.0.0" "-c" "no ip ospf passive")
      NEED=1
   fi

   if [ "$HAS_OSPF3" = "yes" ]; then
      VTYSH_ARGS+=("-c" "no ipv6 ospf6 area 0.0.0.0" "-c" "no ipv6 ospf6 passive")
      NEED=1
   fi

   VTYSH_ARGS+=("-c" "no description" "-c" "exit")

   if [ "$HAS_BGP" = "yes" ] && [ -n "$BGP_ASN" ]; then
      VTYSH_ARGS+=("-c" "router bgp ${BGP_ASN}")
      if [ -n "$V6_LOOPBACKS" ]; then
         VTYSH_ARGS+=("-c" "address-family ipv6 unicast")
         for net in $V6_LOOPBACKS; do
            VTYSH_ARGS+=("-c" "no network ${net}")
         done
         VTYSH_ARGS+=("-c" "exit-address-family")
         NEED=1
      fi
      if [ -n "$V4_LOOPBACKS" ]; then
         VTYSH_ARGS+=("-c" "address-family ipv4 unicast")
         for net in $V4_LOOPBACKS; do
            VTYSH_ARGS+=("-c" "no network ${net}")
         done
         VTYSH_ARGS+=("-c" "exit-address-family")
         NEED=1
      fi
      VTYSH_ARGS+=("-c" "exit")
   fi

   if [ "$NEED" -eq 1 ]; then
      VTYSH_ARGS+=("-c" "end" "-c" "write memory")
      ${CTR_BIN} exec frr vtysh "${VTYSH_ARGS[@]}" >/dev/null 2>&1
   fi
}

adiciona_ospf() {
   local VTYSH_ARGS=("-c" "conf t" "-c" "interface lo" "-c" "description LOOPBACKS")
   local NEED=0

   if [ "$HAS_OSPF2" = "yes" ]; then
      VTYSH_ARGS+=("-c" "ip ospf area 0.0.0.0" "-c" "ip ospf passive")
      NEED=1
   fi

   if [ "$HAS_OSPF3" = "yes" ]; then
      VTYSH_ARGS+=("-c" "ipv6 ospf6 area 0.0.0.0" "-c" "ipv6 ospf6 passive")
      NEED=1
   fi

   VTYSH_ARGS+=("-c" "exit")

   if [ "$HAS_BGP" = "yes" ] && [ -n "$BGP_ASN" ]; then
      VTYSH_ARGS+=("-c" "router bgp ${BGP_ASN}")
      if [ -n "$V6_LOOPBACKS" ]; then
         VTYSH_ARGS+=("-c" "address-family ipv6 unicast")
         for net in $V6_LOOPBACKS; do
            VTYSH_ARGS+=("-c" "network ${net}")
         done
         VTYSH_ARGS+=("-c" "exit-address-family")
         NEED=1
      fi
      if [ -n "$V4_LOOPBACKS" ]; then
         VTYSH_ARGS+=("-c" "address-family ipv4 unicast")
         for net in $V4_LOOPBACKS; do
            VTYSH_ARGS+=("-c" "network ${net}")
         done
         VTYSH_ARGS+=("-c" "exit-address-family")
         NEED=1
      fi
      VTYSH_ARGS+=("-c" "exit")
   fi

   if [ "$NEED" -eq 1 ]; then
      VTYSH_ARGS+=("-c" "end" "-c" "write memory")
      ${CTR_BIN} exec frr vtysh "${VTYSH_ARGS[@]}" >/dev/null 2>&1
   fi
}

# 4. Verificação de Saúde do Container Unbound
if ! ${CTR_BIN} ps --filter "name=unbound" --filter "status=running" 2>/dev/null | grep -q unbound; then
   echo "Servidor $HOSTNAME morreu DNS mas tentando levantar!" | /usr/local/sbin/telegram-notify --error --text - 2>/dev/null || true
   ${CTR_BIN} restart unbound
   sleep 3
   if ! ${CTR_BIN} ps --filter "name=unbound" --filter "status=running" 2>/dev/null | grep -q unbound; then
      if is_anycast_active || [ "$CURRENT_STATE" != "DOWN" ]; then
         remove_ospf
         echo "DOWN" > "$STATE_FILE"
         echo "Servidor $HOSTNAME falhou no teste de DNS - Anúncios Anycast removidos!" | /usr/local/sbin/telegram-notify --error --text - 2>/dev/null || true
      fi
      exit 1
   fi
   echo "Servidor $HOSTNAME servico DNS voltou mas tinha morrido!" | /usr/local/sbin/telegram-notify --success --text - 2>/dev/null || true
fi

# 5. Função de Testes de Resolução Recursiva
qt_total="${#dominios_testar[@]}"

testar_resolucao() {
   qt_falhas=0
   for site in "${dominios_testar[@]}"; do
      ${CTR_BIN} exec unbound unbound-control flush $site &> /dev/null
      resolver="127.0.0.1"
      printf "Testando %-20s ... " "$site"
      if ! host -W 2 $site $resolver &> /dev/null; then
         echo "[ FALHOU ]"
         ((qt_falhas++))
      else
         echo "[ OK ]"
      fi
   done
}

testar_resolucao
taxa_falha=$((qt_falhas * 100 / qt_total))

echo "--------------------------------------------------------"
echo "Resumo: $qt_falhas falha(s) de $qt_total testados (Taxa de falha: ${taxa_falha}%)"
echo "--------------------------------------------------------"

# 6. Self-Healing: Se falha for crítica (100%), tenta reiniciar Unbound para limpar infra-cache e sockets
if [ "$taxa_falha" -ge "$corte_taxa_falha" ]; then
   echo "Falha crítica na resolução. Reiniciando Unbound para destravar infra-cache e sockets..."
   ${CTR_BIN} restart unbound
   sleep 3

   # Re-testa após o restart
   echo "Re-testando domínios após o reinício do Unbound..."
   testar_resolucao
   taxa_falha=$((qt_falhas * 100 / qt_total))
   echo "--------------------------------------------------------"
   echo "Resumo pós-restart: $qt_falhas falha(s) de $qt_total testados (Taxa de falha: ${taxa_falha}%)"
   echo "--------------------------------------------------------"

   if [ "$taxa_falha" -ge "$corte_taxa_falha" ]; then
      if is_anycast_active || [ "$CURRENT_STATE" != "DOWN" ]; then
         remove_ospf
         echo "DOWN" > "$STATE_FILE"
         echo "Servidor $HOSTNAME falhou no teste de DNS - Anúncios Anycast removidos!" | /usr/local/sbin/telegram-notify --error --text - 2>/dev/null || true
      fi
      exit 0
   fi
fi

# 7. Restauração: Só atua e notifica se o estado anterior era DOWN ou se Anycast está inativo
if ! is_anycast_active || [ "$CURRENT_STATE" != "UP" ]; then
   adiciona_ospf
   echo "UP" > "$STATE_FILE"
   echo "Servidor $HOSTNAME com DNS funcional - Anúncios Anycast restaurados!" | /usr/local/sbin/telegram-notify --success --text - 2>/dev/null || true
fi
EOF
        chmod 700 /root/scripts/teste_dns.sh
    fi

    # 10. Crontabs configuration
    if [ -n "${OSPF_INTERFACE}" ]; then
        cat << 'EOF' > /etc/cron.d/teste_dns
MAILTO=""
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
#*/1 *   * * *   root    /root/scripts/teste_dns.sh
EOF
        chmod 644 /etc/cron.d/teste_dns
    fi


    # Adds the example comment line of unboundSend.sh to the crontab of all servers
    if ! grep -q "unboundSend.sh" /etc/crontab; then
        echo "#*/5 * * * *     root    /root/scripts/unboundSend.sh 10.254.254.5 $HOSTNAME 1> /dev/null" >> /etc/crontab
    fi

    systemctl restart cron.service || true


    log_success "Environment structure and helper scripts successfully configured."
}

build_images() {
    log_info "Building and preparing container images (${CONTAINER_ENGINE})..."
    export COMPOSE_BAKE=false

    # Chrony
    log_info "Building Chrony image..."
    cd /usr/local/src/chrony
    if [ "${CONTAINER_ENGINE}" = "podman" ]; then
        podman build --network host --dns 1.1.1.1 --dns 8.8.8.8 -t chrony_chrony:latest -t localhost/chrony_chrony:latest .
    else
        ${COMPOSE_CMD} build
    fi

    # Unbound
    log_info "Building Unbound image..."
    cd /usr/local/src/unbound
    if [ "${CONTAINER_ENGINE}" = "podman" ]; then
        podman build --network host --dns 1.1.1.1 --dns 8.8.8.8 -t unbound_unbound:latest -t localhost/unbound_unbound:latest .
    else
        ${COMPOSE_CMD} build
    fi

    # Generates remote control keys and root DNSSEC key if they do not exist in the volume before starting services
    local unbound_vol_dir="${VOL_BASE}/unbound_config/_data"
    local unbound_lib_dir="${VOL_BASE}/unbound_lib/_data"
    if [[ ! -f "${unbound_vol_dir}/unbound_control.key" ]]; then
        log_info "Generating unbound-control authentication keys in temporary container..."
        ${COMPOSE_CMD} run --rm --entrypoint unbound-control-setup unbound -d /etc/unbound || true
        chown -R 88:88 "${unbound_vol_dir}"
    fi

    if [[ ! -f "${unbound_lib_dir}/root.key" ]]; then
        log_info "Initializing root.key for DNSSEC via unbound-anchor in temporary container..."
        ${COMPOSE_CMD} run --rm --entrypoint unbound-anchor unbound -a /var/lib/unbound/root.key || true
        chown -R 88:88 "${unbound_lib_dir}" 2>/dev/null || true
    fi

    log_success "All container images built successfully."
}

start_services() {
    log_info "Starting services via ${CONTAINER_ENGINE^^} Compose..."
    export COMPOSE_BAKE=false
    
    # Chrony
    cd /usr/local/src/chrony
    ${COMPOSE_CMD} down 2>/dev/null || true
    ${COMPOSE_CMD} up -d
    
    # FRR
    if [ -n "${OSPF_INTERFACE}" ]; then
        cd /usr/local/src/frr
        ${COMPOSE_CMD} down 2>/dev/null || true
        ${COMPOSE_CMD} up -d
    fi
    
    # Unbound
    cd /usr/local/src/unbound
    ${COMPOSE_CMD} down 2>/dev/null || true
    ${COMPOSE_CMD} up -d

    # Zabbix Agent 2
    cd /usr/local/src/zabbix-agent2
    ${COMPOSE_CMD} down 2>/dev/null || true
    ${COMPOSE_CMD} up -d
    
    log_success "All services started successfully!"
}

# Main Flow
check_root
setup_hostname
setup_grub_tuning
setup_kernel_tuning
install_container_engine
setup_container_volumes
setup_chrony
if [ -n "${OSPF_INTERFACE}" ]; then
    setup_frr
fi
setup_unbound
setup_zabbix_agent2
setup_host_environment
build_images
start_services

log_success "Installation completed successfully!"
if [ -t 1 ]; then
    echo ""
    read -p "Installation finished. Press [Enter] to return to the normal terminal..."
fi
