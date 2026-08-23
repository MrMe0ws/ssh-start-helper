#!/bin/bash
# System setup: updates, hostname, timezone, base packages.

step_system_update() {
    print_step "Обновление системы"

    if [[ "${EXISTING_VDS}" == true ]]; then
        log_warn "  На prod-сервере apt upgrade может перезапустить сервисы."
        confirm "  Выполнить apt update && upgrade?" "n" || { log_dim "  Пропущено"; return 0; }
    fi

    log_info "  apt update..."
    run_cmd apt-get update -qq

    log_info "  apt upgrade..."
    run_cmd env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq

    log_ok "  Система обновлена"
    save_state "SYSTEM_UPDATED" "true"
}

step_hostname_timezone() {
    print_step "Hostname и timezone"

    local current_hostname current_tz
    current_hostname=$(hostnamectl hostname 2>/dev/null || hostname)
    current_tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo "UTC")

    log_info "  Текущий hostname: ${C_YELLOW}${current_hostname}${C_RESET}"
    log_info "  Текущий timezone: ${C_YELLOW}${current_tz}${C_RESET}"

    if confirm "  Изменить hostname?" "n"; then
        local new_hostname
        new_hostname=$(prompt_input "  Новый hostname" "${current_hostname}")
        if [[ -n "${new_hostname}" && "${new_hostname}" != "${current_hostname}" ]]; then
            run_cmd hostnamectl set-hostname "${new_hostname}"
            log_ok "  Hostname: ${new_hostname}"
        fi
    fi

    if confirm "  Изменить timezone?" "n"; then
        local new_tz
        new_tz=$(prompt_input "  Timezone (например Europe/Moscow)" "${current_tz}")
        if [[ -n "${new_tz}" ]]; then
            run_cmd timedatectl set-timezone "${new_tz}"
            log_ok "  Timezone: ${new_tz}"
        fi
    fi

    save_state "HOSTNAME_TZ_DONE" "true"
}

step_base_packages() {
    print_step "Базовые утилиты"

    local packages=(curl wget git nano htop ufw whiptail rsync)
    log_info "  Установка: ${packages[*]}"
    run_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}"
    log_ok "  Пакеты установлены"
    save_state "BASE_PACKAGES" "true"
}
