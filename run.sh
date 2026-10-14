#!/bin/bash
#
# ssh-start-helper — wizard (run after install)
# Usage: ssh-start-helper [--dry-run] [--text]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "${SCRIPT_DIR}/lib/common.sh" && -f /opt/ssh-start-helper/lib/common.sh ]]; then
    SCRIPT_DIR="/opt/ssh-start-helper"
fi

DRY_RUN=false
TEXT_MODE=false
for arg in "$@"; do
    case "${arg}" in
        --dry-run) DRY_RUN=true ;;
        --text) TEXT_MODE=true ;;
        -v|--version)
            grep -m1 '^readonly SSH_HELPER_VERSION=' "${SCRIPT_DIR}/lib/common.sh" | cut -d'"' -f2
            exit 0
            ;;
        -h|--help)
            echo "Usage: ssh-start-helper [--dry-run] [--text]"
            echo ""
            echo "Интерактивная настройка Linux VDS (SSH, firewall, fail2ban, обновления, MOTD)."
            echo "Поддерживаются Debian/Ubuntu и RHEL-семейство (Rocky, Alma, CentOS Stream, Fedora)."
            echo ""
            echo "  --dry-run   показать, что будет сделано, без изменений"
            echo "  --text      текстовые меню вместо whiptail (если whiptail криво рисуется)"
            exit 0
            ;;
        *)
            echo "Неизвестный аргумент: ${arg} (см. --help)" >&2
            exit 1
            ;;
    esac
done

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/preflight.sh
source "${SCRIPT_DIR}/lib/preflight.sh"
# shellcheck source=lib/system.sh
source "${SCRIPT_DIR}/lib/system.sh"
# shellcheck source=lib/user.sh
source "${SCRIPT_DIR}/lib/user.sh"
# shellcheck source=lib/ssh.sh
source "${SCRIPT_DIR}/lib/ssh.sh"
# shellcheck source=lib/firewall.sh
source "${SCRIPT_DIR}/lib/firewall.sh"
# shellcheck source=lib/security.sh
source "${SCRIPT_DIR}/lib/security.sh"
# shellcheck source=lib/swap.sh
source "${SCRIPT_DIR}/lib/swap.sh"
# shellcheck source=lib/motd.sh
source "${SCRIPT_DIR}/lib/motd.sh"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export TERM="${TERM:-xterm-256color}"

RUN_UPDATE=false
RUN_HOSTNAME=false
RUN_USER=false
RUN_SSH=false
RUN_FIREWALL=false
RUN_FAIL2BAN=false
RUN_UNATTENDED=false
RUN_SWAP=false
RUN_MOTD=false
RUN_PACKAGES=false
FAILED_STEPS=()

_show_dry_run_notice() {
    if [[ "${DRY_RUN}" == true ]]; then
        echo ""
        log_warn "Режим DRY-RUN — изменения не применяются"
        echo ""
    fi
}

_select_steps_whiptail() {
    local choices

    if ! choices=$(whiptail --title "ssh-start-helper" \
        --checklist "Выберите этапы (Space — выбор, Enter — OK):" \
        22 78 10 \
        "packages" "Базовые утилиты" ON \
        "update" "Обновление системы" ON \
        "hostname" "Hostname и timezone" OFF \
        "user" "Sudo-пользователь + SSH-ключ" OFF \
        "ssh" "SSH: смена порта + hardening" ON \
        "ufw" "Firewall (UFW / firewalld)" ON \
        "fail2ban" "fail2ban (защита от брутфорса)" ON \
        "unattended" "Автоматические security-обновления" ON \
        "swap" "Swap 1 GB" OFF \
        "motd" "MOTD distillium" OFF \
        3>&1 1>&2 2>&3 < "${_TTY}"); then
        restore_tty
        return 1
    fi

    restore_tty

    [[ "${choices}" == *'"update"'* ]] && RUN_UPDATE=true
    [[ "${choices}" == *'"hostname"'* ]] && RUN_HOSTNAME=true
    [[ "${choices}" == *'"user"'* ]] && RUN_USER=true
    [[ "${choices}" == *'"ssh"'* ]] && RUN_SSH=true
    [[ "${choices}" == *'"ufw"'* ]] && RUN_FIREWALL=true
    [[ "${choices}" == *'"fail2ban"'* ]] && RUN_FAIL2BAN=true
    [[ "${choices}" == *'"unattended"'* ]] && RUN_UNATTENDED=true
    [[ "${choices}" == *'"swap"'* ]] && RUN_SWAP=true
    [[ "${choices}" == *'"motd"'* ]] && RUN_MOTD=true
    [[ "${choices}" == *'"packages"'* ]] && RUN_PACKAGES=true
    return 0
}

_select_steps_text() {
    echo ""
    log_info "Выберите этапы (y/n):"
    echo ""

    confirm "  1. Базовые утилиты?" "y" && RUN_PACKAGES=true
    confirm "  2. Обновление системы?" "y" && RUN_UPDATE=true
    confirm "  3. Hostname и timezone?" "n" && RUN_HOSTNAME=true
    confirm "  4. Sudo-пользователь?" "n" && RUN_USER=true
    confirm "  5. SSH: смена порта + hardening?" "y" && RUN_SSH=true
    confirm "  6. Firewall (UFW / firewalld)?" "y" && RUN_FIREWALL=true
    confirm "  7. fail2ban?" "y" && RUN_FAIL2BAN=true
    confirm "  8. Автоматические security-обновления?" "y" && RUN_UNATTENDED=true
    confirm "  9. Swap?" "n" && RUN_SWAP=true
    confirm "  10. MOTD distillium?" "n" && RUN_MOTD=true
    return 0
}

_select_steps() {
    if use_whiptail; then
        if ! _select_steps_whiptail; then
            log_warn "Меню whiptail недоступно — переключаюсь на текстовый режим"
            echo ""
            _select_steps_text
        fi
    else
        _select_steps_text
    fi
}

# Ошибка одного этапа не обрывает остальные
_run_step() {
    local enabled="$1" fn="$2" title="$3"
    [[ "${enabled}" == true ]] || return 0
    if ! "${fn}"; then
        log_err "Этап «${title}» завершился с ошибкой"
        FAILED_STEPS+=("${title}")
    fi
    print_separator
}

_run_steps() {
    _run_step "${RUN_PACKAGES}"   step_base_packages       "Базовые утилиты"
    _run_step "${RUN_UPDATE}"     step_system_update       "Обновление системы"
    _run_step "${RUN_HOSTNAME}"   step_hostname_timezone   "Hostname и timezone"
    _run_step "${RUN_USER}"       step_create_user         "Sudo-пользователь"
    _run_step "${RUN_SSH}"        step_ssh_configure       "SSH"
    _run_step "${RUN_FIREWALL}"   step_firewall_configure  "Firewall"
    _run_step "${RUN_SSH}"        step_ssh_close_port22    "Закрытие порта 22"
    _run_step "${RUN_FAIL2BAN}"   step_fail2ban            "fail2ban"
    _run_step "${RUN_UNATTENDED}" step_unattended_upgrades "Автообновления"
    _run_step "${RUN_SWAP}"       step_swap                "Swap"
    _run_step "${RUN_MOTD}"       step_motd                "MOTD"
}

_print_final_summary() {
    print_step "Готово"

    local ssh_ports fw f2b
    ssh_ports=$(get_ssh_ports)
    case "$(fw_backend)" in
        ufw) fw="UFW $(ufw_is_active && echo активен || echo выключен)" ;;
        firewalld) fw="firewalld активен" ;;
        *) fw="нет" ;;
    esac
    if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client status sshd >/dev/null 2>&1; then
        f2b="активен ($(fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned/ {gsub(/[[:space:]]/,"",$2); print $2}') в бане)"
    else
        f2b="не активен"
    fi

    print_summary_box "Итог" \
        "SSH-порт:     ${ssh_ports}" \
        "Firewall:     ${fw}" \
        "fail2ban:     ${f2b}" \
        "Состояние:    ${SSH_HELPER_STATE}" \
        "Лог:          ${SSH_HELPER_LOG}"

    if [[ "${ssh_ports}" != "22" ]]; then
        log_warn "Подключение: ssh -p ${ssh_ports%% *} $(_login_user)@$(get_server_ip)"
    fi

    if (( ${#FAILED_STEPS[@]} > 0 )); then
        log_err "Этапы с ошибками: ${FAILED_STEPS[*]} — подробности в ${SSH_HELPER_LOG}"
        return 1
    fi
    log_ok "Настройка завершена"
}

main() {
    print_banner
    _show_dry_run_notice

    log_warn "Держите текущую SSH-сессию открытой до проверки нового подключения!"
    echo ""

    if ! has_tty; then
        log_err "Нет интерактивного терминала. Запустите в SSH-сессии: ssh-start-helper"
        exit 1
    fi

    preflight_run
    print_separator

    _select_steps
    echo ""
    print_separator

    if ! confirm "Начать выбранные этапы?" "y"; then
        log_info "Отменено"
        exit 0
    fi

    _run_steps
    _print_final_summary
}

main "$@"
