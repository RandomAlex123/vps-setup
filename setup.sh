#!/usr/bin/env bash
# Safe baseline VPS preparation for VPN panels on Ubuntu and Debian.

vps_setup_entrypoint() {

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

SCRIPT_VERSION="6.0.0"
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
SCRIPT_NAME="$(basename "$SCRIPT_SOURCE")"
SCRIPT_PATH="$(readlink -f -- "$SCRIPT_SOURCE" 2>/dev/null || printf '%s' "$SCRIPT_SOURCE")"
TMUX_SESSION="vps-setup-v6"
BOOTSTRAP_TEMP_SCRIPT=""

case "$SCRIPT_NAME" in
    stdin|fd|[0-9]*|pipe:*) SCRIPT_NAME="setup-v6.sh" ;;
esac

script_path_is_persistent() {
    [[ -n $SCRIPT_PATH && -f $SCRIPT_PATH && -r $SCRIPT_PATH ]] || return 1
    case "$SCRIPT_PATH" in
        /dev/fd/*|/dev/stdin|/proc/*/fd/*|*'pipe:['*) return 1 ;;
    esac
    return 0
}

prepare_script_for_tmux() {
    local temp_script

    script_path_is_persistent && return 0

    if [[ -z ${SETUP_SOURCE_URL:-} ]]; then
        printf '%s\n' \
            'WARNING: The script was started from an ephemeral pipe or file descriptor.' \
            'tmux continuation requires SETUP_SOURCE_URL; continuing without tmux.' >&2
        return 1
    fi

    case "$SETUP_SOURCE_URL" in
        https://*) ;;
        *)
            printf 'ERROR: SETUP_SOURCE_URL must use HTTPS.\n' >&2
            exit 1
            ;;
    esac

    temp_script=$(mktemp /var/tmp/setup-v6.XXXXXX.sh)
    if ! curl -fsSL "$SETUP_SOURCE_URL" -o "$temp_script"; then
        rm -f -- "$temp_script"
        printf 'ERROR: Unable to download a persistent script copy for tmux.\n' >&2
        exit 1
    fi
    chmod 0700 "$temp_script"
    if ! bash -n "$temp_script"; then
        rm -f -- "$temp_script"
        printf 'ERROR: The downloaded script copy failed the Bash syntax check.\n' >&2
        exit 1
    fi

    SCRIPT_PATH=$temp_script
    BOOTSTRAP_TEMP_SCRIPT=$temp_script
    printf 'Saved a temporary script copy for tmux: %s\n' "$temp_script"
}


bootstrap_tmux() {
    # Run the interactive setup in tmux
    [[ -n ${TMUX:-} || ${SETUP_TMUX_REEXEC:-0} == 1 ]] && return 0

    [[ ${EUID:-$(id -u)} -eq 0 ]] || {
        printf 'ERROR: Run this script as root: sudo bash %s\n' "$SCRIPT_NAME" >&2
        exit 1
    }
    [[ -t 1 && -r /dev/tty ]] || {
        printf 'WARNING: No interactive terminal detected; continuing without tmux.\n'
        return 0
    }

    [[ -r /etc/os-release ]] || {
        printf 'ERROR: /etc/os-release was not found.\n' >&2
        exit 1
    }
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}:${VERSION_ID:-}" in
        ubuntu:22.04|ubuntu:24.04|ubuntu:26.04|debian:11|debian:12|debian:13) ;;
        *)
            printf 'ERROR: Unsupported system: %s.\n' "${PRETTY_NAME:-unknown}" >&2
            exit 1
            ;;
    esac

    export DEBIAN_FRONTEND=noninteractive
    if ! command -v tmux >/dev/null 2>&1; then
        printf 'Installing tmux before continuing...\n'
        apt-get -o DPkg::Lock::Timeout=120 update
        apt-get -o DPkg::Lock::Timeout=120 install -y --no-install-recommends tmux
    fi
    command -v tmux >/dev/null 2>&1 || {
        printf 'ERROR: tmux installation did not complete successfully.\n' >&2
        exit 1
    }

    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        printf 'Attaching to the existing tmux session: %s\n' "$TMUX_SESSION"
        exec tmux attach-session -t "$TMUX_SESSION" </dev/tty
    fi

    prepare_script_for_tmux || return 0

    local quoted_script quoted_temp quoted_args='' quoted_arg arg tmux_command
    printf -v quoted_script '%q' "$SCRIPT_PATH"
    printf -v quoted_temp '%q' "$BOOTSTRAP_TEMP_SCRIPT"
    for arg in "$@"; do
        printf -v quoted_arg '%q' "$arg"
        quoted_args+=" $quoted_arg"
    done

    printf -v tmux_command \
        'env SETUP_TMUX_REEXEC=1 SETUP_TEMP_SCRIPT_PATH=%s bash %s%s; rc=$?; printf "\\nSetup script finished with exit code %%s.\\n" "$rc"; printf "Press Enter to close this tmux session... "; read -r; exit "$rc"' \
        "$quoted_temp" "$quoted_script" "$quoted_args"

    printf 'Starting setup version %s inside tmux session: %s\n' "$SCRIPT_VERSION" "$TMUX_SESSION"
    printf 'If SSH disconnects, reconnect and run: tmux attach -t %s\n' "$TMUX_SESSION"
    if ! tmux new-session -d -s "$TMUX_SESSION" "$tmux_command"; then
        [[ -n $BOOTSTRAP_TEMP_SCRIPT ]] && rm -f -- "$BOOTSTRAP_TEMP_SCRIPT"
        printf 'ERROR: Unable to create tmux session %s.\n' "$TMUX_SESSION" >&2
        exit 1
    fi
    exec tmux attach-session -t "$TMUX_SESSION" </dev/tty
}

bootstrap_tmux "$@"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="/var/log/setup.log"
BACKUP_DIR="/var/backups/setup/${RUN_ID}"
RUNTIME_DIR="/run/setup-${RUN_ID}"

mkdir -p "$BACKUP_DIR" "$RUNTIME_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

CHANGES=()
WARNINGS=()
SSH_TX_ACTIVE=0
SSH_UFW_RULE_ADDED=0
SSH_NEW_PORT=""
SSH_SOCKET_MODE=0
APT_UPDATED=0
SSH_FINAL_PORTS=()
SSH_CHANGES_START=0

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
info() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*"; WARNINGS+=("$*"); }
die()  {
    printf 'ERROR: %s\n' "$*" >&2
    if (( SSH_TX_ACTIVE )); then rollback_ssh || true; fi
    exit 1
}

on_error() {
    local rc=$? line=${1:-?}
    # Let the parent shell report command-substitution failures only once.
    if (( BASH_SUBSHELL > 0 )); then
        exit "$rc"
    fi
    printf '\nERROR: command failed with exit code %s at line %s.\n' "$rc" "$line" >&2
    if (( SSH_TX_ACTIVE )); then
        printf 'Rolling back incomplete SSH changes...\n' >&2
        rollback_ssh || true
    fi
    printf 'Details: %s\n' "$LOG_FILE" >&2
    exit "$rc"
}
trap 'on_error "$LINENO"' ERR
cleanup() {
    rm -rf -- "$RUNTIME_DIR"
    if [[ -n ${SETUP_TEMP_SCRIPT_PATH:-} && $SETUP_TEMP_SCRIPT_PATH == /var/tmp/setup-v6.*.sh ]]; then
        rm -f -- "$SETUP_TEMP_SCRIPT_PATH"
    fi
}
trap cleanup EXIT

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this script as root: sudo bash $SCRIPT_NAME"
}

join_by() {
    local separator=$1 first=1 item
    shift
    for item in "$@"; do
        if (( first )); then
            printf '%s' "$item"
            first=0
        else
            printf '%s%s' "$separator" "$item"
        fi
    done
}

array_contains() {
    local needle=$1 item
    shift
    for item in "$@"; do
        [[ $item == "$needle" ]] && return 0
    done
    return 1
}

format_local_key_path() {
    local path=$1 rest
    if [[ $path =~ ^~/[A-Za-z0-9._/@+:-]+$ ]]; then
        printf '%s' "$path"
        return 0
    fi
    if [[ $path == '~/'* ]]; then
        rest=${path#\~/}
        rest=${rest//\\/\\\\}
        rest=${rest//\"/\\\"}
        rest=${rest//\$/\\\$}
        rest=${rest//\`/\\\`}
        printf '"$HOME/%s"' "$rest"
        return 0
    fi
    printf '%q' "$path"
}

trim_whitespace() {
    local value=$1
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

read_tty() {
    local variable_name=$1
    if [[ -r /dev/tty ]]; then
        IFS= read -r "$variable_name" </dev/tty
    else
        IFS= read -r "$variable_name"
    fi
}

ask_yes_no() {
    local question=$1 default=${2:-N} answer prompt
    default=${default^^}
    if [[ $default == Y ]]; then prompt='[Y/n]'; else prompt='[y/N]'; fi
    while true; do
        printf '%s %s ' "$question" "$prompt"
        if ! read_tty answer; then answer=""; fi
        answer=$(trim_whitespace "$answer")
        answer=${answer:-$default}
        case ${answer,,} in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) echo "Enter y/yes or n/no." ;;
        esac
    done
}

backup_file() {
    local path=$1 dest
    [[ -e $path || -L $path ]] || return 0
    dest="$BACKUP_DIR/${path#/}"
    [[ -e $dest || -L $dest ]] && return 0
    mkdir -p "$(dirname "$dest")"
    cp -a -- "$path" "$dest"
    log "Backup: $path -> $dest"
}

write_file_if_changed() {
    local target=$1 mode=${2:-0644} tmp
    tmp=$(mktemp "$RUNTIME_DIR/write.XXXXXX")
    cat > "$tmp"
    if [[ -f $target ]] && cmp -s "$tmp" "$target"; then
        rm -f "$tmp"
        log "No changes: $target"
        return 0
    fi
    backup_file "$target"
    install -D -m "$mode" "$tmp" "$target"
    rm -f "$tmp"
    CHANGES+=("Updated $target")
}

snapshot_path() {
    local tag=$1 path=$2
    printf '%s' "$path" > "$RUNTIME_DIR/${tag}.path"
    if [[ -e $path || -L $path ]]; then
        printf '1' > "$RUNTIME_DIR/${tag}.exists"
        cp -a -- "$path" "$RUNTIME_DIR/${tag}.data"
    else
        printf '0' > "$RUNTIME_DIR/${tag}.exists"
    fi
}

restore_snapshot() {
    local tag=$1 path exists
    [[ -f $RUNTIME_DIR/${tag}.path ]] || return 0
    path=$(<"$RUNTIME_DIR/${tag}.path")
    exists=$(<"$RUNTIME_DIR/${tag}.exists")
    if [[ $exists == 1 ]]; then
        mkdir -p "$(dirname "$path")"
        rm -rf -- "$path"
        cp -a -- "$RUNTIME_DIR/${tag}.data" "$path"
    else
        rm -rf -- "$path"
    fi
}

check_os() {
    [[ -r /etc/os-release ]] || die "/etc/os-release was not found."
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID=${ID:-}
    OS_VERSION=${VERSION_ID:-}
    OS_CODENAME=${VERSION_CODENAME:-}

    case "$OS_ID:$OS_VERSION" in
        ubuntu:22.04|ubuntu:24.04|ubuntu:26.04|debian:11|debian:12|debian:13) ;;
        *) die "Supported systems are Ubuntu LTS 22.04/24.04/26.04 and Debian 11/12/13. Detected: ${PRETTY_NAME:-unknown}." ;;
    esac

    [[ -n $OS_CODENAME ]] || die "Unable to determine VERSION_CODENAME."
    log "OS: ${PRETTY_NAME:-$OS_ID $OS_VERSION}; architecture: $(dpkg --print-architecture)"
}

ensure_apt_ready() {
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
}

apt_get() {
    command apt-get \
        -o DPkg::Lock::Timeout=120 \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        "$@"
}

ensure_apt_lists() {
    ensure_apt_ready
    if (( ! APT_UPDATED )); then
        apt_get update
        APT_UPDATED=1
    fi
}

install_packages() {
    ensure_apt_lists
    apt_get install -y --no-install-recommends "$@"
}

configure_system_updates() {
    info "System updates and base utilities"
    if ! ask_yes_no "Update packages and install base utilities?" Y; then
        log "System update skipped."
        return 0
    fi

    ensure_apt_ready
    apt_get update
    APT_UPDATED=1
    apt_get -y full-upgrade
    install_packages \
        ca-certificates curl wget gnupg openssl git jq unzip zip tar rsync \
        lsb-release iproute2 dnsutils socat cron logrotate sudo kmod \
        openssh-client openssh-server ufw fail2ban python3-systemd \
        unattended-upgrades

    CHANGES+=("System updated; base utilities installed")
}

configure_unattended_upgrades() {
    info "Automatic security updates"
    if ! ask_yes_no "Enable automatic installation of security updates?" Y; then
        log "Automatic security updates skipped."
        return 0
    fi

    install_packages unattended-upgrades
    write_file_if_changed /etc/apt/apt.conf.d/52setup-auto-upgrades 0644 <<'EOF'
// Managed by VPS setup script
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

    if systemctl cat unattended-upgrades.service >/dev/null 2>&1; then
        systemctl enable unattended-upgrades.service >/dev/null 2>&1 || true
        systemctl restart unattended-upgrades.service
    fi
    CHANGES+=("Automatic security updates enabled")
}

get_configured_ssh_ports() {
    if command -v sshd >/dev/null 2>&1; then
        sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' || true
    fi
}

get_safe_ssh_ports() {
    local connected_port=""
    get_configured_ssh_ports
    if [[ -n ${SSH_CONNECTION:-} ]]; then
        connected_port=$(awk '{print $4}' <<<"$SSH_CONNECTION")
        [[ $connected_port =~ ^[0-9]+$ ]] && printf '%s\n' "$connected_port"
    fi
}

get_active_ssh_ports_for_rules() {
    if ((${#SSH_FINAL_PORTS[@]})); then
        printf '%s\n' "${SSH_FINAL_PORTS[@]}"
    else
        get_safe_ssh_ports
    fi
}

port_is_listening() {
    local port=$1
    ss -H -ltn "sport = :$port" 2>/dev/null | awk 'NF {found=1} END {exit !found}'
}

port_speaks_ssh() {
    local port=$1
    ssh-keyscan -T 3 -p "$port" 127.0.0.1 2>/dev/null | \
        awk '/^[^#].+[[:space:]](ssh-|ecdsa-)/ {found=1} END {exit !found}'
}

wait_for_ssh() {
    local port=$1 i
    for i in {1..10}; do
        if port_is_listening "$port" && port_speaks_ssh "$port"; then return 0; fi
        sleep 1
    done
    return 1
}

valid_port() {
    local port=$1
    [[ $port =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

ssh_service_name() {
    if systemctl cat ssh.service >/dev/null 2>&1; then
        printf 'ssh.service'
    elif systemctl cat sshd.service >/dev/null 2>&1; then
        printf 'sshd.service'
    else
        return 1
    fi
}

assert_effective_ssh_ports() {
    local expected actual
    expected=$(printf '%s\n' "$@" | sort -nu | paste -sd, -)
    actual=$(get_configured_ssh_ports | sort -nu | paste -sd, -)
    [[ $actual == "$expected" ]]
}

neutralize_existing_ssh_listeners() {
    local file tmp mode owner group
    local -a files=(/etc/ssh/sshd_config)

    while IFS= read -r -d '' file; do
        [[ $file == /etc/ssh/sshd_config.d/00-setup.conf ]] && continue
        files+=("$file")
    done < <(find /etc/ssh/sshd_config.d -maxdepth 1 -type f -name '*.conf' -print0 2>/dev/null || true)

    for file in "${files[@]}"; do
        [[ -f $file ]] || continue
        if grep -Eq '^[[:space:]]*(Port|ListenAddress)[[:space:]]+' "$file"; then
            backup_file "$file"
            tmp=$(mktemp "$RUNTIME_DIR/sshd-listener.XXXXXX")
            sed -E 's/^([[:space:]]*)(Port|ListenAddress)([[:space:]]+)/\1# setup disabled: \2\3/'                 "$file" > "$tmp"
            mode=$(stat -c '%a' "$file")
            owner=$(stat -c '%u' "$file")
            group=$(stat -c '%g' "$file")
            install -o "$owner" -g "$group" -m "$mode" "$tmp" "$file"
            rm -f "$tmp"
            CHANGES+=("Disabled old Port/ListenAddress directives in $file")
        fi
    done
}

reload_ssh() {
    local service
    systemctl daemon-reload
    if (( SSH_SOCKET_MODE )); then
        systemctl restart ssh.socket
    else
        service=$(ssh_service_name) || return 1
        systemctl reload "$service" || systemctl restart "$service"
    fi
}

ufw_is_active() {
    command -v ufw >/dev/null 2>&1 && \
        LC_ALL=C ufw status 2>/dev/null | awk '/^Status: active$/ {found=1} END {exit !found}'
}

ufw_has_explicit_port() {
    local port=$1
    LC_ALL=C ufw status 2>/dev/null | \
        awk -v port="$port" '$0 ~ ("^" port "/tcp[[:space:]]+ALLOW") {found=1} END {exit !found}'
}

rollback_ssh() {
    set +e
    restore_snapshot ssh_user_dir
    restore_snapshot ssh_socket_dropin
    restore_snapshot ssh_etc_dir

    if (( SSH_UFW_RULE_ADDED )) && [[ -n $SSH_NEW_PORT ]] && command -v ufw >/dev/null 2>&1; then
        ufw --force delete allow "${SSH_NEW_PORT}/tcp" >/dev/null 2>&1 || true
    fi
    reload_ssh >/dev/null 2>&1 || true
    SSH_TX_ACTIVE=0
    SSH_FINAL_PORTS=()
    CHANGES=("${CHANGES[@]:0:SSH_CHANGES_START}")
    set -e
    warn "Incomplete SSH changes were rolled back."
}

make_ssh_dropin() {
    local password_auth=$1 kbd_auth=$2
    shift 2
    {
        echo "# Managed by VPS setup script"
        for p in "$@"; do echo "Port $p"; done
        echo "PubkeyAuthentication yes"
        echo "PasswordAuthentication $password_auth"
        echo "KbdInteractiveAuthentication $kbd_auth"
    } | write_file_if_changed /etc/ssh/sshd_config.d/00-setup.conf 0644
}

make_ssh_socket_dropin() {
    local p
    (( SSH_SOCKET_MODE )) || return 0
    {
        echo "# Managed by VPS setup script"
        echo "[Socket]"
        echo "ListenStream="
        for p in "$@"; do echo "ListenStream=$p"; done
    } | write_file_if_changed /etc/systemd/system/ssh.socket.d/00-setup.conf 0644
}

configure_ssh() {
    local default_user target_user user_home user_uid user_gid
    local public_key="" key_tmp key_type local_private_key="" default_private_key
    local rendered_private_key current_password current_kbd sshd_effective disable_password=0
    local change_port=0 desired_port primary_port server_address confirm
    local -a old_ports=() staged_ports=() final_ports=()

    info "Safe SSH configuration"
    if ! ask_yes_no "Configure an SSH key and/or change the SSH port?" Y; then
        log "SSH configuration skipped."
        return 0
    fi

    install_packages openssh-server openssh-client iproute2
    command -v sshd >/dev/null 2>&1 || die "The sshd command was not found."
    sshd -t

    mapfile -t old_ports < <(get_safe_ssh_ports | sort -nu)
    ((${#old_ports[@]})) || old_ports=(22)
    primary_port=${old_ports[0]}

    default_user=${SUDO_USER:-${USER:-root}}
    [[ $default_user == root || $default_user != "" ]] || default_user=root
    printf 'User for the SSH key [%s]: ' "$default_user"
    read_tty target_user || true
    target_user=${target_user:-$default_user}
    getent passwd "$target_user" >/dev/null || die "User '$target_user' does not exist."
    user_home=$(getent passwd "$target_user" | cut -d: -f6)
    user_uid=$(id -u "$target_user")
    user_gid=$(id -g "$target_user")
    [[ -d $user_home ]] || die "User home directory was not found: $user_home"

    if ask_yes_no "Add a public SSH key for '$target_user'?" Y; then
        while true; do
            echo "Paste one public key line (ssh-ed25519/ssh-rsa/ecdsa/...):"
            read_tty public_key || true
            [[ -n $public_key ]] || { echo "The key cannot be empty."; continue; }
            key_tmp=$(mktemp "$RUNTIME_DIR/pubkey.XXXXXX")
            printf '%s\n' "$public_key" > "$key_tmp"
            if ssh-keygen -lf "$key_tmp" >/dev/null 2>&1; then
                rm -f "$key_tmp"
                break
            fi
            rm -f "$key_tmp"
            echo "Invalid public key. Try again."
        done

        key_type=${public_key%%[[:space:]]*}
        case "$key_type" in
            ssh-ed25519) default_private_key='~/.ssh/id_ed25519' ;;
            ssh-rsa) default_private_key='~/.ssh/id_rsa' ;;
            ecdsa-*) default_private_key='~/.ssh/id_ecdsa' ;;
            sk-ssh-ed25519@*) default_private_key='~/.ssh/id_ed25519_sk' ;;
            sk-ecdsa-*) default_private_key='~/.ssh/id_ecdsa_sk' ;;
            *) default_private_key='~/.ssh/id_ed25519' ;;
        esac
        while true; do
            printf 'Path to the matching private key on your LOCAL computer [%s]: ' "$default_private_key"
            read_tty local_private_key || true
            local_private_key=$(trim_whitespace "$local_private_key")
            local_private_key=${local_private_key:-$default_private_key}
            if [[ $local_private_key == *$'\n'* || $local_private_key == *$'\r'* || $local_private_key == -* ]]; then
                echo "Enter a normal file path that does not start with a dash."
                continue
            fi
            break
        done

        if ask_yes_no "After a successful key test, disable password login for all SSH users?" Y; then
            disable_password=1
        fi
    fi

    if ask_yes_no "Change the standard SSH port (current: $(join_by , "${old_ports[@]}"))?" N; then
        change_port=1
        while true; do
            printf 'New SSH port [for example 2222]: '
            read_tty desired_port || true
            if ! valid_port "$desired_port"; then
                echo "The port must be an integer from 1 to 65535."
                continue
            fi
            if ! array_contains "$desired_port" "${old_ports[@]}" && port_is_listening "$desired_port"; then
                echo "Port $desired_port is already in use. Choose another port."
                continue
            fi
            break
        done
    else
        desired_port=$primary_port
    fi

    if [[ -z $public_key ]] && (( ! change_port )); then
        log "No SSH changes were selected."
        return 0
    fi

    # Capture the full output first: early pipeline termination can produce SIGPIPE (141) with pipefail.
    sshd_effective=$(sshd -T)
    current_password=$(awk '$1 == "passwordauthentication" && !found {print $2; found=1}' <<<"$sshd_effective")
    current_kbd=$(awk '$1 == "kbdinteractiveauthentication" && !found {print $2; found=1}' <<<"$sshd_effective")
    current_password=${current_password:-yes}
    current_kbd=${current_kbd:-no}

    SSH_SOCKET_MODE=0
    if systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-enabled --quiet ssh.socket >/dev/null 2>&1; then
        SSH_SOCKET_MODE=1
    fi

    SSH_NEW_PORT=$desired_port
    SSH_UFW_RULE_ADDED=0
    SSH_CHANGES_START=${#CHANGES[@]}
    SSH_TX_ACTIVE=1

    snapshot_path ssh_etc_dir /etc/ssh
    snapshot_path ssh_socket_dropin /etc/systemd/system/ssh.socket.d/00-setup.conf
    snapshot_path ssh_user_dir "$user_home/.ssh"
    backup_file /etc/ssh

    if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
        backup_file /etc/ssh/sshd_config
        {
            echo 'Include /etc/ssh/sshd_config.d/*.conf'
            cat /etc/ssh/sshd_config
        } > "$RUNTIME_DIR/sshd_config.new"
        install -m 0644 "$RUNTIME_DIR/sshd_config.new" /etc/ssh/sshd_config
        CHANGES+=("Added Include directive for sshd_config.d")
    fi

    if [[ -n $public_key ]]; then
        backup_file "$user_home/.ssh/authorized_keys"
        install -d -m 0700 -o "$user_uid" -g "$user_gid" "$user_home/.ssh"
        touch "$user_home/.ssh/authorized_keys"
        chown "$user_uid:$user_gid" "$user_home/.ssh/authorized_keys"
        chmod 0600 "$user_home/.ssh/authorized_keys"
        if ! grep -qxF -- "$public_key" "$user_home/.ssh/authorized_keys"; then
            printf '%s\n' "$public_key" >> "$user_home/.ssh/authorized_keys"
            CHANGES+=("Added an SSH key for $target_user")
        else
            log "The SSH key is already present."
        fi
    fi

    if (( change_port )); then
        neutralize_existing_ssh_listeners
    fi

    staged_ports=("${old_ports[@]}")
    if ! array_contains "$desired_port" "${staged_ports[@]}"; then
        staged_ports+=("$desired_port")
    fi
    mapfile -t staged_ports < <(printf '%s\n' "${staged_ports[@]}" | sort -nu)

    make_ssh_dropin "$current_password" "$current_kbd" "${staged_ports[@]}"
    make_ssh_socket_dropin "${staged_ports[@]}"

    if ufw_is_active && ! ufw_has_explicit_port "$desired_port"; then
        ufw allow "${desired_port}/tcp"
        SSH_UFW_RULE_ADDED=1
    fi

    if ! sshd -t; then
        rollback_ssh
        die "The new SSH configuration failed validation."
    fi
    if (( change_port )) && ! assert_effective_ssh_ports "${staged_ports[@]}"; then
        rollback_ssh
        die "Unexpected Port/ListenAddress directives were detected in the SSH configuration; changes were rolled back."
    fi
    reload_ssh

    for p in "${staged_ports[@]}"; do
        wait_for_ssh "$p" || { rollback_ssh; die "Port $p does not respond as SSH after the staged configuration was applied."; }
    done

    server_address="${SSH_CONNECTION:-}"
    if [[ -n $server_address ]]; then
        server_address=$(awk '{print $3}' <<<"$server_address")
    else
        server_address=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    server_address=${server_address:-SERVER_IP}

    echo
    echo "Open a NEW local terminal and test the connection without closing the current session."
    if [[ -n $public_key ]]; then
        rendered_private_key=$(format_local_key_path "$local_private_key")
        printf '  ssh -i %s -p %s %s@%s\n' \
            "$rendered_private_key" "$desired_port" "$target_user" "$server_address"
    else
        printf '  ssh -p %s %s@%s\n' "$desired_port" "$target_user" "$server_address"
    fi
    echo "The current SSH session and old port are still available."
    printf "After a SUCCESSFUL login, enter exactly YES; any other answer will roll back the SSH changes: "
    read_tty confirm || true

    if [[ $confirm != YES ]]; then
        rollback_ssh
        log "The new SSH session was not confirmed; changes were rolled back."
        return 0
    fi

    if (( change_port )); then
        final_ports=("$desired_port")
    else
        final_ports=("${old_ports[@]}")
    fi

    if (( disable_password )) && [[ -n $public_key ]]; then
        make_ssh_dropin no no "${final_ports[@]}"
        CHANGES+=("Disabled SSH password login after key verification")
    else
        make_ssh_dropin "$current_password" "$current_kbd" "${final_ports[@]}"
    fi
    make_ssh_socket_dropin "${final_ports[@]}"

    sshd -t
    if (( change_port )) && ! assert_effective_ssh_ports "${final_ports[@]}"; then
        rollback_ssh
        die "Unable to keep only the new SSH port; changes were rolled back."
    fi
    reload_ssh
    for p in "${final_ports[@]}"; do
        wait_for_ssh "$p" || { rollback_ssh; die "Final port $p does not respond as SSH."; }
    done
    if (( change_port )); then
        for p in "${old_ports[@]}"; do
            if ! array_contains "$p" "${final_ports[@]}" && port_is_listening "$p"; then
                rollback_ssh
                die "Old SSH port $p is still listening; changes were rolled back."
            fi
        done
    fi

    SSH_TX_ACTIVE=0
    SSH_UFW_RULE_ADDED=0
    SSH_FINAL_PORTS=("${final_ports[@]}")
    CHANGES+=("SSH verified; active ports: $(join_by , "${final_ports[@]}")")
    log "SSH configuration completed successfully."
}

configure_ufw() {
    local was_active=0 failed=0 p
    local -a ports=()

    info "Firewall UFW"
    if ! ask_yes_no "Configure and enable UFW while allowing only the current SSH ports?" Y; then
        log "UFW configuration skipped."
        return 0
    fi

    install_packages ufw
    mapfile -t ports < <(get_active_ssh_ports_for_rules | sort -nu)
    ((${#ports[@]})) || ports=(22)

    ufw_is_active && was_active=1
    snapshot_path ufw_user_rules /etc/ufw/user.rules
    snapshot_path ufw_user6_rules /etc/ufw/user6.rules
    snapshot_path ufw_defaults /etc/default/ufw
    backup_file /etc/default/ufw

    if ! ufw default deny incoming; then failed=1; fi
    if (( ! failed )) && ! ufw default allow outgoing; then failed=1; fi
    if (( ! failed )); then
        for p in "${ports[@]}"; do
            if ! ufw allow "${p}/tcp"; then failed=1; break; fi
        done
    fi
    if (( ! failed )) && ! ufw --force enable; then failed=1; fi

    if (( failed )); then
        restore_snapshot ufw_user_rules
        restore_snapshot ufw_user6_rules
        restore_snapshot ufw_defaults
        if (( was_active )); then ufw reload || true; else ufw --force disable || true; fi
        die "UFW could not be configured safely; previous rules were restored."
    fi

    for p in "${ports[@]}"; do
        if ! ufw_has_explicit_port "$p"; then
            restore_snapshot ufw_user_rules
            restore_snapshot ufw_user6_rules
            restore_snapshot ufw_defaults
            if (( was_active )); then ufw reload || true; else ufw --force disable || true; fi
            die "After enabling UFW, no allow rule was found for SSH port $p; changes were rolled back."
        fi
    done

    CHANGES+=("UFW enabled: incoming traffic denied; allowed SSH ports: $(join_by , "${ports[@]}")")
    echo "The script did not open ports 80, 443, or any VPN ports."
}

wait_for_fail2ban() {
    local attempts=${1:-20} i

    for ((i = 1; i <= attempts; i++)); do
        if fail2ban-client ping >/dev/null 2>&1 \
            && fail2ban-client status sshd >/dev/null 2>&1; then
            return 0
        fi
        systemctl is-failed --quiet fail2ban.service && return 1
        sleep 1
    done
    return 1
}

configure_fail2ban() {
    local ignore_line='ignoreip = 127.0.0.1/8 ::1' remote_ip="" port_csv
    local service_status service_journal
    local -a ports=()

    info "Fail2ban for SSH"
    if ! ask_yes_no "Configure Fail2ban for SSH?" Y; then
        log "Fail2ban configuration skipped."
        return 0
    fi

    install_packages fail2ban python3-systemd
    mapfile -t ports < <(get_active_ssh_ports_for_rules | sort -nu)
    ((${#ports[@]})) || ports=(22)
    port_csv=$(IFS=,; echo "${ports[*]}")

    if [[ -n ${SSH_CONNECTION:-} ]]; then
        remote_ip=$(awk '{print $1}' <<<"$SSH_CONNECTION")
        if [[ -n $remote_ip ]] && ask_yes_no "Add the current IP $remote_ip to the Fail2ban ignore list?" N; then
            ignore_line+=" $remote_ip"
        fi
    fi

    snapshot_path fail2ban_jail /etc/fail2ban/jail.d/00-setup-sshd.local
    write_file_if_changed /etc/fail2ban/jail.d/00-setup-sshd.local 0644 <<EOF
# Managed by VPS setup script
[sshd]
enabled = true
backend = systemd
port = $port_csv
maxretry = 5
findtime = 10m
bantime = 1h
$ignore_line
EOF

    if ! fail2ban-client -t; then
        restore_snapshot fail2ban_jail
        systemctl restart fail2ban >/dev/null 2>&1 || true
        die "The Fail2ban configuration failed validation; changes were rolled back."
    fi

    if ! systemctl enable fail2ban.service; then
        restore_snapshot fail2ban_jail
        systemctl restart fail2ban.service >/dev/null 2>&1 || true
        die "Fail2ban could not be enabled; the previous jail configuration was restored."
    fi

    if ! systemctl restart fail2ban.service || ! wait_for_fail2ban 20; then
        service_status=$(systemctl --no-pager --full status fail2ban.service 2>&1 || true)
        service_journal=$(journalctl -u fail2ban.service -n 30 --no-pager 2>&1 || true)

        restore_snapshot fail2ban_jail
        systemctl restart fail2ban.service >/dev/null 2>&1 || true

        printf '%s\n' "----- fail2ban.service status -----" "$service_status" >&2
        printf '%s\n' "----- recent fail2ban journal -----" "$service_journal" >&2
        die "Fail2ban did not become ready within 20 seconds; the previous jail configuration was restored."
    fi

    CHANGES+=("Fail2ban configured for SSH ports $port_csv")
}

configure_sysctl() {
    local enable_bbr=0 enable_ipv6=0 available_cc=""

    info "VPN system parameters and BBR"
    if ! ask_yes_no "Enable IPv4 forwarding and conservative network settings?" Y; then
        log "sysctl configuration skipped."
        return 0
    fi

    if ask_yes_no "Enable IPv6 forwarding only if the VPN will route IPv6?" N; then
        enable_ipv6=1
    fi

    modprobe tcp_bbr >/dev/null 2>&1 || true
    modprobe sch_fq >/dev/null 2>&1 || true
    available_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    if [[ " $available_cc " == *" bbr "* ]]; then
        if ask_yes_no "The kernel supports BBR. Enable BBR?" Y; then enable_bbr=1; fi
    else
        warn "BBR is not supported by the current kernel; BBR configuration skipped."
    fi

    snapshot_path sysctl_vpn /etc/sysctl.d/99-vps-vpn-bootstrap.conf
    {
        echo "# Managed by VPS setup script"
        echo "net.ipv4.ip_forward = 1"
        if (( enable_ipv6 )); then echo "net.ipv6.conf.all.forwarding = 1"; fi
        if (( enable_bbr )); then
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
        fi
    } | write_file_if_changed /etc/sysctl.d/99-vps-vpn-bootstrap.conf 0644

    if ! sysctl --load /etc/sysctl.d/99-vps-vpn-bootstrap.conf; then
        restore_snapshot sysctl_vpn
        sysctl --system >/dev/null 2>&1 || true
        die "Unable to apply sysctl settings; the previous file was restored."
    fi

    [[ $(sysctl -n net.ipv4.ip_forward) == 1 ]] || die "IPv4 forwarding was not enabled."
    CHANGES+=("Enabled IPv4 forwarding$([[ $enable_bbr == 1 ]] && echo ', BBR' || true)")
}

configure_journald() {
    info "Systemd journal limits"
    if ! ask_yes_no "Limit systemd journals to 200 MB and a maximum retention of 14 days?" Y; then
        log "journald configuration skipped."
        return 0
    fi

    write_file_if_changed /etc/systemd/journald.conf.d/90-setup.conf 0644 <<'EOF'
# Managed by VPS setup script
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=100M
MaxRetentionSec=14day
EOF
    systemctl restart systemd-journald
    journalctl --vacuum-size=200M >/dev/null 2>&1 || true
    CHANGES+=("systemd journals limited to 200 MB and 14 days")
}

swapfile_is_active() {
    swapon --noheadings --raw --show=NAME 2>/dev/null | \
        awk '$0 == "/swapfile" {found=1} END {exit !found}'
}

swap_component_mb() {
    local component=$1

    swapon --noheadings --raw --bytes --show=NAME,SIZE 2>/dev/null | \
        awk -v component="$component" '
            component == "swapfile" && $1 == "/swapfile" {total += $2}
            component == "existing" && $1 != "/swapfile" {total += $2}
            END {printf "%.0f\n", total / 1048576}
        '
}

print_swap_summary() {
    local existing_swap_mb swapfile_mb total_swap_mb

    existing_swap_mb=$(swap_component_mb existing)
    swapfile_mb=$(swap_component_mb swapfile)
    total_swap_mb=$(free -m | awk '/Swap:/ {value=$2} END {print value+0}')

    printf 'Existing swap devices: %s MB\n' "$existing_swap_mb"
    printf '/swapfile size:        %s MB\n' "$swapfile_mb"
    printf 'Total active swap:     %s MB\n' "$total_swap_mb"
}

configure_swap() {
    local size_mb size_bytes free_bytes reserve_bytes existing_size=0 tmp_swap old_swap
    local mem_available swap_used old_was_active=0 fstab_changed=0

    info "Swap"
    if ! ask_yes_no "Check or configure /swapfile?" Y; then
        log "Swap configuration skipped."
        return 0
    fi

    echo "Current swap:"
    swapon --show || true
    print_swap_summary
    while true; do
        printf 'Additional /swapfile size in MB [press Enter to keep the current configuration]: '
        read_tty size_mb || true
        [[ -z $size_mb ]] && { log "Swap size left unchanged."; return 0; }
        if [[ $size_mb =~ ^[0-9]+$ ]] && (( size_mb >= 128 && size_mb <= 131072 )); then
            break
        fi
        echo "Enter an integer from 128 to 131072 MB, or press Enter."
    done

    size_bytes=$((size_mb * 1024 * 1024))
    reserve_bytes=$((512 * 1024 * 1024))
    free_bytes=$(df --output=avail -B1 / | tail -n1 | tr -d ' ')
    tmp_swap=/swapfile.setup.new
    old_swap=/swapfile.setup.old

    [[ ! -e $old_swap ]] || die "Found $old_swap from an incomplete operation. Inspect it manually before running the script again."
    if [[ -e $tmp_swap ]]; then
        if swapon --noheadings --raw --show=NAME 2>/dev/null | \
            awk -v path="$tmp_swap" '$0 == path {found=1} END {exit !found}'; then
            die "$tmp_swap is active as swap; manual inspection is required."
        fi
        rm -f "$tmp_swap"
    fi

    if [[ -e /swapfile ]]; then
        existing_size=$(stat -c %s /swapfile)
        swapfile_is_active && old_was_active=1
        if (( existing_size == size_bytes )) && (( old_was_active )); then
            if ! awk '$1 == "/swapfile" && $3 == "swap" {found=1} END {exit !found}' /etc/fstab; then
                backup_file /etc/fstab
                awk '$1 != "/swapfile" {print}' /etc/fstab > "$RUNTIME_DIR/fstab.new"
                echo '/swapfile none swap sw 0 0' >> "$RUNTIME_DIR/fstab.new"
                install -m 0644 "$RUNTIME_DIR/fstab.new" /etc/fstab
                CHANGES+=("Added /swapfile entry to /etc/fstab")
            fi
            log "/swapfile is already ${size_mb} MB and active."
            return 0
        fi

        swap_used=$(swapon --noheadings --bytes --show=NAME,USED 2>/dev/null |             awk '$1 == "/swapfile" && !found {print $2; found=1}')
        swap_used=${swap_used:-0}
        mem_available=$(awk '/MemAvailable:/ {printf "%.0f", $2 * 1024}' /proc/meminfo)
        (( swap_used < mem_available )) || die "There is not enough available RAM to safely disable the current /swapfile."
    fi

    (( free_bytes > size_bytes + reserve_bytes )) || die "Not enough disk space: the new swap size plus at least 512 MB of free space is required."

    if ! fallocate -l "$size_bytes" "$tmp_swap" 2>/dev/null; then
        dd if=/dev/zero of="$tmp_swap" bs=1M count="$size_mb" status=progress
    fi
    chmod 0600 "$tmp_swap"
    if ! mkswap "$tmp_swap" >/dev/null; then
        rm -f "$tmp_swap"
        die "Unable to create the swap signature."
    fi

    snapshot_path swap_fstab /etc/fstab
    if [[ -e /swapfile ]]; then
        (( old_was_active )) && swapoff /swapfile
        mv /swapfile "$old_swap"
    fi
    mv "$tmp_swap" /swapfile

    if ! swapon /swapfile; then
        rm -f /swapfile
        if [[ -e $old_swap ]]; then
            mv "$old_swap" /swapfile
            (( old_was_active )) && swapon /swapfile || true
        fi
        die "Unable to activate the new swap; the old swap was restored."
    fi

    backup_file /etc/fstab
    awk '$1 != "/swapfile" {print}' /etc/fstab > "$RUNTIME_DIR/fstab.new"
    echo '/swapfile none swap sw 0 0' >> "$RUNTIME_DIR/fstab.new"
    if ! install -m 0644 "$RUNTIME_DIR/fstab.new" /etc/fstab; then
        swapoff /swapfile || true
        rm -f /swapfile
        restore_snapshot swap_fstab
        if [[ -e $old_swap ]]; then
            mv "$old_swap" /swapfile
            (( old_was_active )) && swapon /swapfile || true
        fi
        die "Unable to update /etc/fstab; the old swap was restored."
    fi
    fstab_changed=1

    rm -f "$old_swap"
    (( fstab_changed )) && CHANGES+=("Configured a ${size_mb} MB /swapfile")
}
install_docker() {
    local repo_url key_url arch tmp_key

    info "Docker Engine"
    if command -v docker >/dev/null 2>&1; then
        log "Docker is already installed: $(docker --version 2>/dev/null || true)"
        return 0
    fi
    if ! ask_yes_no "Install Docker Engine from the official Docker repository?" N; then
        log "Docker installation skipped."
        return 0
    fi

    warn "Published Docker ports can bypass expected UFW filtering. Publish container ports deliberately."
    install_packages ca-certificates curl gnupg
    install -d -m 0755 /etc/apt/keyrings

    repo_url="https://download.docker.com/linux/$OS_ID"
    key_url="$repo_url/gpg"
    arch=$(dpkg --print-architecture)
    tmp_key=$(mktemp "$RUNTIME_DIR/docker-key.XXXXXX")
    curl -fsSL "$key_url" -o "$tmp_key"
    backup_file /etc/apt/keyrings/docker.asc
    install -m 0644 "$tmp_key" /etc/apt/keyrings/docker.asc
    rm -f "$tmp_key"

    write_file_if_changed /etc/apt/sources.list.d/docker.sources 0644 <<EOF
Types: deb
URIs: $repo_url
Suites: $OS_CODENAME
Components: stable
Architectures: $arch
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    apt_get update
    install_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    docker version >/dev/null
    CHANGES+=("Installed Docker Engine and the Compose plugin")
}

final_checks() {
    local -a ports=()
    local ssh_ok="no" ufw_state fail2ban_state existing_swap_mb swapfile_mb total_swap_mb sysctl_forward bbr docker_state reboot_state

    info "Final checks"

    if sshd -t >/dev/null 2>&1; then ssh_ok="yes"; fi
    mapfile -t ports < <(get_active_ssh_ports_for_rules | sort -nu)
    ((${#ports[@]})) || ports=("not detected")

    if command -v ufw >/dev/null 2>&1; then
        ufw_state=$(LC_ALL=C ufw status 2>/dev/null | awk 'NR == 1 {first=$0} END {print first}')
        ufw_state=${ufw_state:-"status unknown"}
    else
        ufw_state="not installed"
    fi
    if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client status sshd >/dev/null 2>&1; then
        fail2ban_state="active (sshd jail)"
    else
        fail2ban_state="not active or not configured"
    fi

    existing_swap_mb=$(swap_component_mb existing)
    swapfile_mb=$(swap_component_mb swapfile)
    total_swap_mb=$(free -m | awk '/Swap:/ {value=$2} END {print value+0}')
    sysctl_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "unknown")
    bbr=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")

    if command -v docker >/dev/null 2>&1; then
        if systemctl is-active --quiet docker; then
            docker_state="installed and active ($(docker --version 2>/dev/null || true))"
        else
            docker_state="installed, but the service is inactive"
        fi
    else
        docker_state="not installed"
    fi

    if [[ -e /var/run/reboot-required ]]; then
        reboot_state="REQUIRED"
    else
        reboot_state="not required"
    fi

    echo
    echo "================ FINAL REPORT ================="
    echo "OS:                 ${PRETTY_NAME:-$OS_ID $OS_VERSION}"
    echo "SSH config valid:   $ssh_ok"
    echo "SSH port(s):        $(join_by , "${ports[@]}")"
    echo "UFW:                $ufw_state"
    echo "Fail2ban:           $fail2ban_state"
    echo "Existing swap devices: ${existing_swap_mb} MB"
    echo "/swapfile size:        ${swapfile_mb} MB"
    echo "Total active swap:     ${total_swap_mb} MB"
    echo "IPv4 forwarding:    $sysctl_forward"
    echo "TCP congestion:     $bbr"
    echo "Docker:             $docker_state"
    echo "Reboot required:    $reboot_state"
    echo "Log:                $LOG_FILE"
    echo "Backups:            $BACKUP_DIR"
    echo "tmux session:        $TMUX_SESSION"

    if ((${#CHANGES[@]})); then
        echo
        echo "Changes made:"
        printf '  - %s\n' "${CHANGES[@]}"
    else
        echo
        echo "No changes were made."
    fi

    if ((${#WARNINGS[@]})); then
        echo
        echo "Warnings:"
        printf '  - %s\n' "${WARNINGS[@]}"
    fi

    echo
    echo "Ports 80, 443, and VPN panel ports were intentionally left closed."
    echo "3x-ui, Telemt, and AmneziaVPN were not installed."
}

main() {
    require_root
    [[ -t 0 || -r /dev/tty ]] || die "An interactive terminal is required."
    check_os
    echo "Starting $SCRIPT_NAME version $SCRIPT_VERSION. Every main step can be skipped."
    echo "tmux session: $TMUX_SESSION (reattach with: tmux attach -t $TMUX_SESSION)"
    echo "Do not close the current SSH session until SSH verification is complete."

    configure_system_updates
    configure_unattended_upgrades
    configure_ssh
    configure_ufw
    configure_fail2ban
    configure_sysctl
    configure_journald
    configure_swap
    install_docker
    final_checks
}

main "$@"
}

vps_setup_entrypoint "$@"
