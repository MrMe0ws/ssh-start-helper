#!/bin/bash
# System setup: updates, hostname, timezone, base packages.

step_system_update() {
    print_step "Обновление системы"

    if [[ "${EXISTING_VDS}" == true ]]; then
        log_warn "  На prod-сервере обновление может перезапустить сервисы."
        confirm "  Выполнить обновление пакетов?" "n" || { log_dim "  Пропущено"; return 0; }
    fi

    log_info "  Обновление списков и пакетов (${PKG_MGR})..."
    if ! pkg_upgrade; then
        log_err "  Обновление завершилось с ошибкой"
        return 1
    fi

    log_ok "  Система обновлена"
    if [[ -f /var/run/reboot-required ]]; then
        log_warn "  Требуется перезагрузка (обновлено ядро/библиотеки) — сделайте reboot после настройки"
    fi
    save_state "SYSTEM_UPDATED" "true"
}

step_hostname_timezone() {
    print_step "Hostname и timezone"

    local current_hostname current_tz
    current_hostname=$(hostnamectl --static 2>/dev/null || hostname)
    current_tz=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "UTC")

    log_info "  Текущий hostname: ${C_YELLOW}${current_hostname}${C_RESET}"
    log_info "  Текущий timezone: ${C_YELLOW}${current_tz}${C_RESET}"

    if confirm "  Изменить hostname?" "n"; then
        local new_hostname
        new_hostname=$(prompt_input "  Новый hostname" "${current_hostname}")
        if [[ ! "${new_hostname}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,61}[a-zA-Z0-9])?$ ]]; then
            log_err "  Недопустимый hostname: ${new_hostname}"
        elif [[ "${new_hostname}" != "${current_hostname}" ]]; then
            run_cmd hostnamectl set-hostname "${new_hostname}" || run_cmd hostname "${new_hostname}"
            # иначе sudo пишет "unable to resolve host"
            if [[ "${DRY_RUN}" != true ]]; then
                if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
                    sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1 ${new_hostname}/" /etc/hosts
                else
                    echo "127.0.1.1 ${new_hostname}" >> /etc/hosts
                fi
            fi
            log_ok "  Hostname: ${new_hostname}"
        fi
    fi

    if confirm "  Изменить timezone?" "n"; then
        local new_tz
        new_tz=$(prompt_input "  Timezone (например Europe/Moscow)" "${current_tz}")
        if [[ -n "${new_tz}" ]]; then
            if [[ ! -f "/usr/share/zoneinfo/${new_tz}" ]]; then
                log_err "  Неизвестная timezone: ${new_tz}"
            else
                run_cmd timedatectl set-timezone "${new_tz}" \
                    || run_cmd ln -sf "/usr/share/zoneinfo/${new_tz}" /etc/localtime
                log_ok "  Timezone: ${new_tz}"
            fi
        fi
    fi

    save_state "HOSTNAME_TZ_DONE" "true"
}

step_base_packages() {
    print_step "Базовые утилиты"

    local packages
    case "${PKG_MGR}" in
        apt)
            packages=(curl wget git nano htop ufw whiptail rsync ca-certificates iputils-ping iproute2 lsof)
            ;;
        *)
            ensure_epel
            packages=(curl wget git nano htop rsync ca-certificates iputils iproute lsof newt)
            ;;
    esac
    log_info "  Установка: ${packages[*]}"
    pkg_install_available "${packages[@]}" || { log_err "  Не удалось обновить списки пакетов"; return 1; }
    log_ok "  Пакеты установлены"
    save_state "BASE_PACKAGES" "true"
}
