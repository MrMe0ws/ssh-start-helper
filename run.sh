#!/bin/bash
#
# ssh-start-helper — wizard (run after install)
# Usage: ssh-start-helper [--dry-run]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "${SCRIPT_DIR}/lib/common.sh" && -f /opt/ssh-start-helper/lib/common.sh ]]; then
    SCRIPT_DIR="/opt/ssh-start-helper"
fi

DRY_RUN=false
for arg in "$@"; do
    case "${arg}" in
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            echo "Usage: ssh-start-helper [--dry-run]"
            echo ""
            echo "Интерактивная настройка Ubuntu VDS (SSH, UFW, fail2ban, MOTD)."
            exit 0
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
export TERM="${TERM:-xterm-256color}"

RUN_UPDATE=false
RUN_HOSTNAME=false
RUN_USER=false
RUN_SSH=false
RUN_UFW=false
RUN_FAIL2BAN=false
RUN_UNATTENDED=false
RUN_SWAP=false
RUN_MOTD=false
RUN_PACKAGES=false

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
        "update" "Обновление системы (apt)" ON \
        "hostname" "Hostname и timezone" ON \
        "user" "Sudo-пользователь + SSH-ключ" OFF \
        "ssh" "SSH hardening + смена порта" ON \
        "ufw" "UFW firewall (с аудитом правил)" ON \
        "fail2ban" "fail2ban" ON \
        "unattended" "unattended-upgrades" ON \
        "swap" "Swap 1 GB" OFF \
        "motd" "MOTD distillium" OFF \
        "packages" "Базовые утилиты" ON \
        3>&1 1>&2 2>&3); then
        restore_tty
        return 1
    fi

    restore_tty

    [[ "${choices}" == *update* ]] && RUN_UPDATE=true
    [[ "${choices}" == *hostname* ]] && RUN_HOSTNAME=true
    [[ "${choices}" == *user* ]] && RUN_USER=true
    [[ "${choices}" == *ssh* ]] && RUN_SSH=true
    [[ "${choices}" == *ufw* ]] && RUN_UFW=true
    [[ "${choices}" == *fail2ban* ]] && RUN_FAIL2BAN=true
    [[ "${choices}" == *unattended* ]] && RUN_UNATTENDED=true
    [[ "${choices}" == *swap* ]] && RUN_SWAP=true
    [[ "${choices}" == *motd* ]] && RUN_MOTD=true
    [[ "${choices}" == *packages* ]] && RUN_PACKAGES=true
    return 0
}

_select_steps_text() {
    echo ""
    log_info "Выберите этапы (y/n):"
    echo ""

    confirm "  1. Обновление системы?" "y" && RUN_UPDATE=true
    confirm "  2. Hostname и timezone?" "y" && RUN_HOSTNAME=true
    confirm "  3. Sudo-пользователь?" "n" && RUN_USER=true
    confirm "  4. SSH hardening + смена порта?" "y" && RUN_SSH=true
    confirm "  5. UFW firewall?" "y" && RUN_UFW=true
    confirm "  6. fail2ban?" "y" && RUN_FAIL2BAN=true
    confirm "  7. unattended-upgrades?" "y" && RUN_UNATTENDED=true
    confirm "  8. Swap?" "n" && RUN_SWAP=true
    confirm "  9. MOTD distillium?" "n" && RUN_MOTD=true
    confirm "  10. Базовые утилиты?" "y" && RUN_PACKAGES=true
}

_select_steps() {
    if require_whiptail && [[ -r /dev/tty ]]; then
        if ! _select_steps_whiptail; then
            log_warn "Меню whiptail недоступно — переключаюсь на текстовый режим"
            echo ""
            _select_steps_text
        fi
    else
        _select_steps_text
    fi
}

_run_steps() {
    if [[ "${RUN_PACKAGES}" == true ]]; then
        step_base_packages
        print_separator
    fi

    if [[ "${RUN_UPDATE}" == true ]]; then
        step_system_update
        print_separator
    fi

    if [[ "${RUN_HOSTNAME}" == true ]]; then
        step_hostname_timezone
        print_separator
    fi

    if [[ "${RUN_USER}" == true ]]; then
        step_create_user
        print_separator
    fi

    if [[ "${RUN_SSH}" == true ]]; then
        step_ssh_configure
        print_separator
    fi

    if [[ "${RUN_UFW}" == true ]]; then
        step_ufw_configure
        print_separator
    fi

    if [[ "${RUN_SSH}" == true ]]; then
        step_ssh_close_port22
        print_separator
    fi

    if [[ "${RUN_FAIL2BAN}" == true ]]; then
        step_fail2ban
        print_separator
    fi

    if [[ "${RUN_UNATTENDED}" == true ]]; then
        step_unattended_upgrades
        print_separator
    fi

    if [[ "${RUN_SWAP}" == true ]]; then
        step_swap
        print_separator
    fi

    if [[ "${RUN_MOTD}" == true ]]; then
        step_motd
        print_separator
    fi
}

_print_final_summary() {
    print_step "Готово"

    local ssh_port
    ssh_port=$(load_state "SSH_PORT" "$(get_ssh_port)")

    print_summary_box "Итог" \
        "SSH-порт:     ${ssh_port}" \
        "UFW:          $(ufw status 2>/dev/null | head -1 || echo 'n/a')" \
        "Состояние:    ${SSH_HELPER_STATE}" \
        "Лог:          ${SSH_HELPER_LOG}"

    if [[ "${ssh_port}" != "22" ]]; then
        log_warn "Подключение: ssh -p ${ssh_port} user@your-server"
    fi

    log_ok "Настройка завершена"
}

main() {
    print_banner
    _show_dry_run_notice

    log_warn "Держите текущую SSH-сессию открытой до проверки нового подключения!"
    echo ""

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
