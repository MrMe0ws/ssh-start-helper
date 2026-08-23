#!/bin/bash
# Preflight checks: OS, network, existing VDS detection.

preflight_check_os() {
    print_step "Проверка системы"

    if [[ ! -f /etc/os-release ]]; then
        log_err "Не удалось определить ОС."
        exit 1
    fi

    # shellcheck source=/dev/null
    source /etc/os-release

    log_info "  ОС: ${PRETTY_NAME:-unknown}"

    if [[ "${ID}" != "ubuntu" && "${ID}" != "debian" ]]; then
        log_warn "  Скрипт рассчитан на Ubuntu/Debian. Продолжение на свой риск."
        confirm "Продолжить?" "n" || exit 0
    fi

    if [[ "${ID}" == "ubuntu" ]]; then
        local ver_major
        ver_major=$(echo "${VERSION_ID}" | cut -d. -f1)
        if (( ver_major < 24 )); then
            log_warn "  Рекомендуется Ubuntu 24.04+. Обнаружено: ${VERSION_ID}"
            confirm "Продолжить?" "n" || exit 0
        else
            log_ok "  Версия Ubuntu подходит (${VERSION_ID})"
        fi
    fi
}

preflight_check_network() {
    log_info "  Проверка сети..."
    if ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W3 8.8.8.8 >/dev/null 2>&1; then
        log_ok "  Сеть доступна"
    else
        log_warn "  Нет доступа в интернет. Некоторые этапы могут не сработать."
        confirm "Продолжить без интернета?" "n" || exit 0
    fi
}

preflight_detect_existing_vds() {
    local signals=0
    EXISTING_VDS=false

    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | head -1 | grep -qi "active"; then
            ((signals++)) || true
            log_info "  UFW уже активен"
        fi
    fi

    local ssh_port
    ssh_port=$(get_ssh_port)
    if [[ "${ssh_port}" != "22" ]]; then
        ((signals++)) || true
        log_info "  SSH уже на порту ${ssh_port}"
    fi

    local non_root_users
    non_root_users=$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd | wc -l)
    if (( non_root_users > 0 )); then
        ((signals++)) || true
        log_info "  Найдено пользователей: ${non_root_users}"
    fi

    if (( signals > 0 )); then
        EXISTING_VDS=true
        echo ""
        log_warn "Обнаружена уже настроенная система."
        log_warn "Скрипт работает в режиме аудита — destructive-действия только по явному подтверждению."
        log_warn "Существующие UFW-правила не будут изменены без вашего согласия."
        echo ""
        save_state "EXISTING_VDS" "true"
    else
        log_ok "  Похоже на свежий VDS"
        save_state "EXISTING_VDS" "false"
    fi
}

preflight_snapshot_ufw() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -1 | grep -qi "active"; then
        ensure_dirs
        if [[ "${DRY_RUN}" != true ]]; then
            ufw status numbered > "${SSH_HELPER_BACKUP}/ufw-snapshot-$(date +%Y%m%d-%H%M%S).txt" 2>/dev/null || true
            log_ok "  Snapshot UFW сохранён"
        fi
    fi
}

preflight_run() {
    require_root
    ensure_dirs
    preflight_check_os
    preflight_check_network
    preflight_detect_existing_vds
    preflight_snapshot_ufw
}
