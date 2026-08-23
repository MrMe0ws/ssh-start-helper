#!/bin/bash
# shellcheck disable=SC2034
# Common utilities: colored UI, logging, prompts, backups.

readonly SSH_HELPER_VERSION="1.0.4"
readonly SSH_HELPER_DIR="/opt/ssh-start-helper"
readonly SSH_HELPER_STATE="${SSH_HELPER_DIR}/state.env"
readonly SSH_HELPER_BACKUP="${SSH_HELPER_DIR}/backup"
readonly SSH_HELPER_LOG="/var/log/ssh-start-helper.log"
readonly SSH_HELPER_SSH_DROPIN="/etc/ssh/sshd_config.d/99-ssh-start-helper.conf"

# Global flags (set by install.sh)
: "${DRY_RUN:=false}"
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
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${msg}" >> "${SSH_HELPER_LOG}" 2>/dev/null || true
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
    echo -e "${C_BOLD}${C_CYAN}  ║${C_RESET}  Базовая настройка Ubuntu VDS             ${C_BOLD}${C_CYAN}║${C_RESET}"
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

restore_tty() {
    [[ -r "${_TTY}" ]] && stty sane < "${_TTY}" 2>/dev/null || true
}

confirm() {
    local prompt="${1:-Продолжить?}"
    local default="${2:-n}"
    local suffix="[y/N]"

    if [[ "${default}" == "y" ]]; then
        suffix="[Y/n]"
    fi

    if [[ ! -r "${_TTY}" ]]; then
        log_err "Нет интерактивного терминала. Запустите: ssh-start-helper"
        return 1
    fi

    local answer
    echo -en "${C_BOLD}${C_CYAN}?${C_RESET} ${prompt} ${suffix}: " > "${_TTY}"
    read -r answer < "${_TTY}"

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

    if [[ ! -r "${_TTY}" ]]; then
        log_warn "Нет терминала, используется значение по умолчанию: ${default}"
        echo "${default}"
        return
    fi

    if [[ -n "${default}" ]]; then
        echo -en "${C_BOLD}${C_CYAN}?${C_RESET} ${prompt} [${C_YELLOW}${default}${C_RESET}]: " > "${_TTY}"
    else
        echo -en "${C_BOLD}${C_CYAN}?${C_RESET} ${prompt}: " > "${_TTY}"
    fi

    read -r answer < "${_TTY}"
    echo "${answer:-$default}"
}

run_cmd() {
    if [[ "${DRY_RUN}" == true ]]; then
        log_dim "  [dry-run] $*"
        return 0
    fi
    "$@"
}

ensure_dirs() {
    run_cmd mkdir -p "${SSH_HELPER_DIR}" "${SSH_HELPER_BACKUP}"
    run_cmd chmod 700 "${SSH_HELPER_DIR}"
    touch "${SSH_HELPER_LOG}" 2>/dev/null || true
}

save_state() {
    local key="$1"
    local value="$2"
    ensure_dirs
    if [[ "${DRY_RUN}" == true ]]; then
        log_dim "  [dry-run] state ${key}=${value}"
        return 0
    fi
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

backup_dir() {
    local src="$1"
    local name
    name=$(echo "${src}" | sed 's|/|_|g' | sed 's|^_||')
    if [[ "${DRY_RUN}" == true ]]; then
        log_dim "  [dry-run] backup ${src}"
        return 0
    fi
    ensure_dirs
    if [[ -d "${src}" ]]; then
        cp -a "${src}" "${SSH_HELPER_BACKUP}/${name}-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
        log_ok "  Бэкап: ${src}"
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

port_in_use() {
    local port="$1"
    ss -tlnp 2>/dev/null | grep -q ":${port} " && return 0
    return 1
}

get_ssh_port() {
    local port="22"
    if [[ -f "${SSH_HELPER_SSH_DROPIN}" ]]; then
        local p
        p=$(grep -iE '^Port[[:space:]]+' "${SSH_HELPER_SSH_DROPIN}" 2>/dev/null | awk '{print $2}')
        [[ -n "${p}" ]] && port="${p}"
    fi
    if [[ "${port}" == "22" ]] && [[ -f /etc/ssh/sshd_config ]]; then
        local p
        p=$(grep -iE '^Port[[:space:]]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -1)
        [[ -n "${p}" ]] && port="${p}"
    fi
    echo "${port}"
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_err "Скрипт нужно запускать от root (sudo)."
        exit 1
    fi
}

require_whiptail() {
    if ! command -v whiptail >/dev/null 2>&1; then
        log_warn "whiptail не найден, будет использован текстовый режим."
        return 1
    fi
    return 0
}

whiptail_menu() {
    local title="$1"
    local prompt="$2"
    local height="$3"
    local width="$4"
    local menu_height="$5"
    shift 5
    whiptail --title "${title}" --menu "${prompt}" "${height}" "${width}" "${menu_height}" "$@" 3>&1 1>&2 2>&3
    local rc=$?
    restore_tty
    return "${rc}"
}

whiptail_checklist() {
    local title="$1"
    local prompt="$2"
    local height="$3"
    local width="$4"
    local list_height="$5"
    shift 5
    whiptail --title "${title}" --checklist "${prompt}" "${height}" "${width}" "${list_height}" "$@" 3>&1 1>&2 2>&3
    local rc=$?
    restore_tty
    return "${rc}"
}
