#!/bin/bash
# shellcheck disable=SC2034
# Common utilities: colored UI, logging, prompts, backups, packages, sshd helpers.

readonly SSH_HELPER_VERSION="1.1.0"
readonly SSH_HELPER_DIR="/opt/ssh-start-helper"
readonly SSH_HELPER_STATE="${SSH_HELPER_DIR}/state.env"
readonly SSH_HELPER_BACKUP="${SSH_HELPER_DIR}/backup"
readonly SSH_HELPER_LOG="/var/log/ssh-start-helper.log"
# 00- — sshd берёт ПЕРВОЕ значение директивы, поэтому наш drop-in должен читаться раньше
# 50-cloud-init.conf и прочих (иначе PasswordAuthentication/PermitRootLogin молча игнорируются)
readonly SSH_HELPER_SSH_DROPIN="/etc/ssh/sshd_config.d/00-ssh-start-helper.conf"
readonly SSH_HELPER_SSH_DROPIN_OLD="/etc/ssh/sshd_config.d/99-ssh-start-helper.conf"
# zz- — jail.d/*.local читаются последними, наш файл переопределяет остальные
readonly SSH_HELPER_F2B_JAIL="/etc/fail2ban/jail.d/zz-ssh-start-helper.local"

# Global flags (set by run.sh)
: "${DRY_RUN:=false}"
: "${TEXT_MODE:=false}"
: "${EXISTING_VDS:=false}"

# Colors
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
    C_DIM='\033[2m'
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_CYAN='\033[0;36m'
    C_WHITE='\033[1;37m'
    C_GRAY='\033[0;90m'
else
    C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN=''
    C_YELLOW='' C_CYAN='' C_WHITE='' C_GRAY=''
fi

_strip_ansi() {
    sed 's/\x1b\[[0-9;]*m//g'
}

_log_plain() {
    local msg="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${msg}" | _strip_ansi >> "${SSH_HELPER_LOG}" 2>/dev/null || true
}

log_info() {
    echo -e "${C_CYAN}[+]${C_RESET} $*"
    _log_plain "[INFO] $*"
}

log_ok() {
    echo -e "${C_GREEN}[✓]${C_RESET} $*"
    _log_plain "[OK] $*"
}

log_warn() {
    echo -e "${C_YELLOW}[!]${C_RESET} $*"
    _log_plain "[WARN] $*"
}

log_err() {
    echo -e "${C_RED}[✗]${C_RESET} $*" >&2
    _log_plain "[ERR] $*"
}

log_dim() {
    echo -e "${C_GRAY}$*${C_RESET}"
    _log_plain "[DIM] $*"
}

log_value() {
    echo -e "${C_CYAN}$1${C_RESET}${C_YELLOW}$2${C_RESET}$3"
}

print_step() {
    echo ""
    echo -e "${C_BOLD}${C_WHITE}── $* ──${C_RESET}"
    echo ""
}

print_separator() {
    echo -e "${C_GRAY}────────────────────────────────────────────────${C_RESET}"
}

print_banner() {
    echo ""
    echo -e "${C_BOLD}${C_CYAN}  ╔══════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}  ║${C_RESET}  ${C_BOLD}ssh-start-helper${C_RESET} v${SSH_HELPER_VERSION}              ${C_BOLD}${C_CYAN}║${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}  ║${C_RESET}  Базовая настройка Linux VDS              ${C_BOLD}${C_CYAN}║${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}  ╚══════════════════════════════════════════╝${C_RESET}"
    echo ""
}

print_summary_box() {
    local title="$1"
    shift
    echo ""
    echo -e "${C_BOLD}  ┌─ ${title} ─────────────────────────${C_RESET}"
    for line in "$@"; do
        echo -e "${C_WHITE}  │${C_RESET} ${line}"
    done
    echo -e "${C_BOLD}  └────────────────────────────────────────────${C_RESET}"
    echo ""
}

# Interactive I/O — always /dev/tty (whiptail and piped stdout break stdin)
readonly _TTY="/dev/tty"

has_tty() {
    # -r недостаточно: /dev/tty существует и без управляющего терминала
    [[ -r "${_TTY}" ]] && { : < "${_TTY}"; } 2>/dev/null
}

restore_tty() {
    has_tty || return 0
    stty sane < "${_TTY}" 2>/dev/null || true
    # Backspace: PuTTY/Windows часто шлёт ^H, Linux ожидает ^? (или наоборот)
    stty erase ^H < "${_TTY}" 2>/dev/null || stty erase ^? < "${_TTY}" 2>/dev/null || true
}

use_whiptail() {
    [[ "${TEXT_MODE}" != true ]] || return 1
    [[ "${TERM:-dumb}" != "dumb" ]] || return 1
    command -v whiptail >/dev/null 2>&1 || return 1
    has_tty
}

confirm() {
    local prompt="${1:-Продолжить?}"
    local default="${2:-n}"
    local suffix="[y/N]"

    if [[ "${default}" == "y" ]]; then
        suffix="[Y/n]"
    fi

    if ! has_tty; then
        log_err "Нет интерактивного терминала. Запустите: ssh-start-helper"
        return 1
    fi

    local answer
    echo -en "${C_BOLD}${C_CYAN}?${C_RESET} ${prompt} ${suffix}: " > "${_TTY}"
    read -r answer < "${_TTY}" || answer=""

    answer="${answer:-$default}"
    case "${answer,,}" in
        y|yes|да|д) return 0 ;;
        *) return 1 ;;
    esac
}

prompt_input() {
    local prompt="$1"
    local default="${2:-}"
    local answer

    if ! has_tty; then
        log_warn "Нет терминала, используется значение по умолчанию: ${default}" >&2
        echo "${default}"
        return
    fi

    if [[ -n "${default}" ]]; then
        echo -en "${C_BOLD}${C_CYAN}?${C_RESET} ${prompt} [${C_YELLOW}${default}${C_RESET}]: " > "${_TTY}"
    else
        echo -en "${C_BOLD}${C_CYAN}?${C_RESET} ${prompt}: " > "${_TTY}"
    fi

    read -r answer < "${_TTY}" || answer=""
    echo "${answer:-$default}"
}

# Меню выбора: whiptail, если доступен, иначе нумерованный список.
# Usage: choose "Title" "Prompt" "default_tag" tag1 "desc1" tag2 "desc2" ...
# Печатает выбранный tag. При отмене/без терминала — default_tag.
choose() {
    local title="$1" prompt="$2" default="$3"
    shift 3
    local -a tags=() descs=()
    while (( $# >= 2 )); do
        tags+=("$1")
        descs+=("$2")
        shift 2
    done

    if use_whiptail; then
        local -a items=()
        local i
        for i in "${!tags[@]}"; do
            items+=("${tags[$i]}" "${descs[$i]}")
        done
        local result
        if result=$(whiptail --title "${title}" --default-item "${default}" \
            --menu "${prompt}" $(( ${#tags[@]} + 10 )) 76 "${#tags[@]}" \
            "${items[@]}" 3>&1 1>&2 2>&3 < "${_TTY}"); then
            restore_tty
            echo "${result}"
            return 0
        fi
        restore_tty
        echo "${default}"
        return 0
    fi

    if ! has_tty; then
        echo "${default}"
        return 0
    fi

    local i def_num=1
    {
        echo ""
        echo -e "${C_BOLD}${title}${C_RESET} — ${prompt}"
        for i in "${!tags[@]}"; do
            [[ "${tags[$i]}" == "${default}" ]] && def_num=$(( i + 1 ))
            echo "    $(( i + 1 ))) ${descs[$i]}"
        done
    } > "${_TTY}"

    local answer
    while true; do
        echo -en "${C_BOLD}${C_CYAN}?${C_RESET} Номер [${C_YELLOW}${def_num}${C_RESET}]: " > "${_TTY}"
        read -r answer < "${_TTY}" || answer=""
        answer="${answer:-$def_num}"
        if [[ "${answer}" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#tags[@]} )); then
            echo "${tags[$(( answer - 1 ))]}"
            return 0
        fi
        echo "    Введите число от 1 до ${#tags[@]}" > "${_TTY}"
    done
}

run_cmd() {
    if [[ "${DRY_RUN}" == true ]]; then
        log_dim "  [dry-run] $*"
        return 0
    fi
    "$@"
}

# Запись файла из stdin с учётом dry-run: write_file /path <<'EOF' ... EOF
write_file() {
    local path="$1"
    if [[ "${DRY_RUN}" == true ]]; then
        log_dim "  [dry-run] write ${path}:"
        sed 's/^/      /'
        return 0
    fi
    cat > "${path}"
}

ensure_dirs() {
    if [[ "${DRY_RUN}" == true ]]; then
        return 0
    fi
    mkdir -p "${SSH_HELPER_DIR}" "${SSH_HELPER_BACKUP}"
    chmod 700 "${SSH_HELPER_DIR}"
    touch "${SSH_HELPER_LOG}" 2>/dev/null || true
}

save_state() {
    local key="$1"
    local value="$2"
    if [[ "${DRY_RUN}" == true ]]; then
        log_dim "  [dry-run] state ${key}=${value}"
        return 0
    fi
    ensure_dirs
    if [[ -f "${SSH_HELPER_STATE}" ]] && grep -q "^${key}=" "${SSH_HELPER_STATE}" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "${SSH_HELPER_STATE}"
    else
        echo "${key}=${value}" >> "${SSH_HELPER_STATE}"
    fi
}

load_state() {
    local key="$1"
    local default="${2:-}"
    if [[ -f "${SSH_HELPER_STATE}" ]]; then
        local val
        val=$(grep "^${key}=" "${SSH_HELPER_STATE}" 2>/dev/null | cut -d= -f2-)
        echo "${val:-$default}"
    else
        echo "${default}"
    fi
}

# Печатает путь к бэкапу (stdout), лог — в stderr
backup_dir() {
    local src="$1"
    local name dest
    name=$(echo "${src}" | sed 's|/|_|g' | sed 's|^_||')
    if [[ "${DRY_RUN}" == true ]]; then
        log_dim "  [dry-run] backup ${src}" >&2
        return 0
    fi
    ensure_dirs
    if [[ -d "${src}" ]]; then
        dest="${SSH_HELPER_BACKUP}/${name}-$(date +%Y%m%d-%H%M%S)"
        cp -a "${src}" "${dest}" 2>/dev/null || true
        log_ok "  Бэкап: ${src} → ${dest}" >&2
        echo "${dest}"
    fi
}

backup_file() {
    local src="$1"
    if [[ "${DRY_RUN}" == true ]]; then
        log_dim "  [dry-run] backup ${src}"
        return 0
    fi
    ensure_dirs
    if [[ -f "${src}" ]]; then
        cp -a "${src}" "${SSH_HELPER_BACKUP}/$(basename "${src}")-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
        log_ok "  Бэкап: ${src}"
    fi
}

is_valid_port() {
    local port="$1"
    [[ "${port}" =~ ^[0-9]+$ ]] && (( port >= 1024 && port <= 65535 ))
}

# Кто слушает TCP-порт (имя процесса или пусто)
port_owner() {
    local port="$1"
    ss -tlnp "sport = :${port}" 2>/dev/null | tail -n +2 | grep -o 'users:(("[^"]*"' | head -1 | cut -d'"' -f2
}

port_in_use() {
    local port="$1"
    [[ -n "$(ss -tln "sport = :${port}" 2>/dev/null | tail -n +2)" ]]
}

sshd_listens_on_port() {
    port_in_use "$1"
}

# Проверка, что на порту отвечает именно SSH (баннер SSH-2.0)
ssh_banner_ok() {
    local port="$1" host="${2:-127.0.0.1}"
    local banner
    banner=$(timeout 5 bash -c "exec 3<>/dev/tcp/${host}/${port}; head -c 8 <&3" 2>/dev/null) || return 1
    [[ "${banner}" == SSH-* ]]
}

# ── Пакеты ──────────────────────────────────────────────────────────

PKG_MGR=""
_PKG_UPDATED=false

detect_pkg_mgr() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"
    else
        PKG_MGR=""
    fi
}

# apt ждёт lock до 5 минут (на свежем VDS его держит unattended-upgrades/cloud-init)
_apt() {
    apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold "$@"
}

# Вывод пакетного менеджера — в лог; на экран только хвост при ошибке
_pkg_run() {
    if [[ "${DRY_RUN}" == true ]]; then
        log_dim "  [dry-run] $*"
        return 0
    fi
    local out
    if out=$("$@" 2>&1); then
        printf '%s
' "${out}" >> "${SSH_HELPER_LOG}" 2>/dev/null || true
        return 0
    fi
    printf '%s
' "${out}" >> "${SSH_HELPER_LOG}" 2>/dev/null || true
    log_err "  Команда завершилась с ошибкой: $*"
    printf '%s
' "${out}" | tail -15 | sed 's/^/    /' >&2
    return 1
}

pkg_update() {
    [[ "${_PKG_UPDATED}" == true ]] && return 0
    case "${PKG_MGR}" in
        apt) _pkg_run _apt update || return 1 ;;
        dnf) _pkg_run dnf -y makecache || return 1 ;;
        yum) _pkg_run yum -y makecache || return 1 ;;
        *) log_err "  Пакетный менеджер не найден (нужен apt, dnf или yum)"; return 1 ;;
    esac
    _PKG_UPDATED=true
}

pkg_install() {
    (( $# > 0 )) || return 0
    pkg_update || return 1
    case "${PKG_MGR}" in
        apt) _pkg_run _apt install -y "$@" ;;
        dnf) _pkg_run dnf install -y "$@" ;;
        yum) _pkg_run yum install -y "$@" ;;
        *) return 1 ;;
    esac
}

# Ставит пакеты по одному, пропуская недоступные (имена отличаются между версиями ОС)
pkg_install_available() {
    local p failed=()
    pkg_update || return 1
    pkg_install "$@" >/dev/null 2>&1 && return 0
    for p in "$@"; do
        pkg_install "${p}" >/dev/null 2>&1 || failed+=("${p}")
    done
    if (( ${#failed[@]} > 0 )); then
        log_warn "  Не удалось установить: ${failed[*]}"
    fi
    return 0
}

pkg_upgrade() {
    pkg_update || return 1
    case "${PKG_MGR}" in
        apt) _pkg_run _apt upgrade -y ;;
        dnf) _pkg_run dnf upgrade -y ;;
        yum) _pkg_run yum update -y ;;
    esac
}

# EPEL нужен на RHEL-клонах для fail2ban/htop (на Fedora не нужен)
ensure_epel() {
    [[ "${PKG_MGR}" == "dnf" || "${PKG_MGR}" == "yum" ]] || return 0
    [[ "${OS_ID:-}" == "fedora" ]] && return 0
    if rpm -q epel-release >/dev/null 2>&1; then
        return 0
    fi
    log_info "  Подключение EPEL..."
    pkg_install epel-release || log_warn "  EPEL не подключён — часть пакетов может быть недоступна"
    _PKG_UPDATED=false
}

# ── Система ─────────────────────────────────────────────────────────

OS_ID=""
OS_LIKE=""
OS_VERSION=""
OS_NAME=""

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        OS_ID=$(. /etc/os-release && echo "${ID:-}")
        OS_LIKE=$(. /etc/os-release && echo "${ID_LIKE:-}")
        OS_VERSION=$(. /etc/os-release && echo "${VERSION_ID:-}")
        OS_NAME=$(. /etc/os-release && echo "${PRETTY_NAME:-${ID:-unknown}}")
    fi
    detect_pkg_mgr
}

is_debian_like() {
    [[ "${PKG_MGR}" == "apt" ]]
}

is_rhel_like() {
    [[ "${PKG_MGR}" == "dnf" || "${PKG_MGR}" == "yum" ]]
}

has_systemd() {
    [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1
}

in_container() {
    command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -cq 2>/dev/null
}

# ── Сеть ────────────────────────────────────────────────────────────

_tcp_ok() {
    timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null
}

_http_ok() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -sS -o /dev/null -m 8 -I "${url}" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q --spider -T 8 "${url}" 2>/dev/null
    else
        return 1
    fi
}

# Не используем ping: его нет на минимальных образах, а ICMP часто режут
has_internet() {
    local url
    for url in https://deb.debian.org https://github.com https://1.1.1.1; do
        _http_ok "${url}" && return 0
    done
    _tcp_ok 1.1.1.1 443 || _tcp_ok 8.8.8.8 53 || _tcp_ok 9.9.9.9 443
}

has_dns() {
    getent hosts github.com >/dev/null 2>&1 || getent hosts deb.debian.org >/dev/null 2>&1
}

# IP для подсказки ssh: из текущей сессии, иначе публичный
get_server_ip() {
    local ip=""
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        ip=$(echo "${SSH_CONNECTION}" | awk '{print $3}')
        [[ -n "${ip}" ]] && { echo "${ip}"; return; }
    fi
    if command -v curl >/dev/null 2>&1; then
        ip=$(curl -fsSL --max-time 4 https://api.ipify.org 2>/dev/null || true)
        [[ -n "${ip}" ]] && { echo "${ip}"; return; }
    fi
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
    echo "${ip:-YOUR_SERVER_IP}"
}

# IP клиента текущей SSH-сессии
get_client_ip() {
    echo "${SSH_CONNECTION:-${SSH_CLIENT:-}}" | awk '{print $1}'
}

# ── sshd ────────────────────────────────────────────────────────────

sshd_bin() {
    command -v sshd 2>/dev/null || echo /usr/sbin/sshd
}

# sshd -t/-T падают без /run/sshd (бывает при socket-activation на Ubuntu)
_ensure_sshd_rundir() {
    [[ -d /run/sshd ]] || mkdir -p /run/sshd 2>/dev/null || true
}

# Эффективная конфигурация sshd (учитывает Include, drop-in и порядок)
sshd_effective() {
    _ensure_sshd_rundir
    "$(sshd_bin)" -T 2>/dev/null
}

sshd_effective_value() {
    local key="${1,,}"
    sshd_effective | awk -v k="${key}" '$1==k {print $2; exit}'
}

# Все порты sshd через пробел
get_ssh_ports() {
    local ports
    ports=$(sshd_effective | awk '$1=="port" {print $2}' | sort -un | tr '\n' ' ')
    if [[ -z "${ports// /}" ]]; then
        ports=$(grep -hiE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null \
            | awk '{print $2}' | sort -un | tr '\n' ' ')
    fi
    ports="${ports% }"
    echo "${ports:-22}"
}

get_ssh_port() {
    local ports
    ports=$(get_ssh_ports)
    echo "${ports%% *}"
}

ssh_service_name() {
    local s
    for s in ssh sshd; do
        if systemctl cat "${s}.service" >/dev/null 2>&1; then
            # на Debian sshd.service — алиас ssh.service
            echo "${s}"
            return
        fi
    done
    echo "sshd"
}

# Версия OpenSSH как число: 8.9 → 809
openssh_version_num() {
    local v
    v=$(ssh -V 2>&1 | sed -n 's/^OpenSSH_\([0-9]*\)\.\([0-9]*\).*/\1 \2/p')
    [[ -n "${v}" ]] || { echo 0; return; }
    # shellcheck disable=SC2086
    set -- ${v}
    echo $(( $1 * 100 + $2 ))
}

# Есть ли у пользователя хотя бы один валидный ключ в authorized_keys
user_has_ssh_keys() {
    local home
    home=$(getent passwd "$1" | cut -d: -f6)
    [[ -n "${home}" && -s "${home}/.ssh/authorized_keys" ]] || return 1
    grep -qE '^[^#]*(ssh-(rsa|ed25519|dss)|ecdsa-sha2-|sk-(ssh|ecdsa)-)' "${home}/.ssh/authorized_keys"
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_err "Скрипт нужно запускать от root (sudo)."
        exit 1
    fi
}
