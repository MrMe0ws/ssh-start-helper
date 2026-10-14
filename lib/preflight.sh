#!/bin/bash
# shellcheck disable=SC2034
# Preflight checks: OS, network, existing VDS detection.

preflight_check_os() {
    print_step "Проверка системы"

    detect_os
    log_info "  ОС: ${OS_NAME:-unknown}"

    if [[ -z "${PKG_MGR}" ]]; then
        log_err "  Не найден apt/dnf/yum. Поддерживаются Debian/Ubuntu и RHEL-семейство (Rocky, Alma, CentOS Stream, Fedora)."
        exit 1
    fi
    log_ok "  Пакетный менеджер: ${PKG_MGR}"

    if ! has_systemd; then
        log_warn "  systemd не обнаружен — перезапуск сервисов может не сработать"
        confirm "Продолжить?" "n" || exit 0
    fi

    if in_container; then
        log_warn "  Похоже на контейнер ($(systemd-detect-virt -c 2>/dev/null)) — swap и firewall могут быть недоступны"
    fi

    if ! command -v sshd >/dev/null 2>&1 && [[ ! -x /usr/sbin/sshd ]]; then
        log_warn "  OpenSSH server (sshd) не найден"
    else
        local v
        v=$(openssh_version_num)
        log_ok "  OpenSSH: $(ssh -V 2>&1 | cut -d, -f1)"
        if (( v > 0 && v < 802 )); then
            log_warn "  OpenSSH < 8.2 — нет поддержки Include, настройки будут записаны в sshd_config"
        fi
    fi

    case "${OS_ID}" in
        ubuntu)
            local ver_major
            ver_major=$(echo "${OS_VERSION}" | cut -d. -f1)
            if [[ "${ver_major}" =~ ^[0-9]+$ ]] && (( ver_major < 20 )); then
                log_warn "  Ubuntu ${OS_VERSION} устарела (EOL). Скрипт попробует, но лучше переустановить на 22.04/24.04."
            fi
            ;;
        debian)
            local ver_major
            ver_major=$(echo "${OS_VERSION}" | cut -d. -f1)
            if [[ "${ver_major}" =~ ^[0-9]+$ ]] && (( ver_major < 11 )); then
                log_warn "  Debian ${OS_VERSION} устарел (EOL). Рекомендуется Debian 12+."
            fi
            ;;
    esac
}

preflight_check_network() {
    log_info "  Проверка сети..."
    if has_internet; then
        log_ok "  Сеть доступна"
        if ! has_dns; then
            log_warn "  Интернет есть, но DNS не резолвит имена — проверьте /etc/resolv.conf"
        fi
        return 0
    fi

    if has_dns; then
        log_warn "  DNS работает, но HTTPS/TCP наружу недоступен (возможно, исходящий firewall)."
    else
        log_warn "  Нет доступа в интернет."
    fi
    log_warn "  Установка пакетов (fail2ban, ufw, обновления) может не сработать."
    confirm "Продолжить без интернета?" "y" || exit 0
}

preflight_detect_existing_vds() {
    local signals=0
    EXISTING_VDS=false

    if ufw_is_active; then
        ((signals++)) || true
        log_info "  UFW уже активен"
    fi

    local ssh_ports
    ssh_ports=$(get_ssh_ports)
    if [[ "${ssh_ports}" != "22" ]]; then
        ((signals++)) || true
        log_info "  SSH уже на порту ${ssh_ports}"
    fi

    local non_root_users
    non_root_users=$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd | wc -l)
    if (( non_root_users > 0 )); then
        ((signals++)) || true
        log_info "  Найдено пользователей: ${non_root_users}"
    fi

    if command -v docker >/dev/null 2>&1 && [[ -n "$(docker ps -q 2>/dev/null)" ]]; then
        ((signals++)) || true
        log_info "  Работают Docker-контейнеры: $(docker ps --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')"
    fi

    if (( signals > 0 )); then
        EXISTING_VDS=true
        echo ""
        log_warn "Обнаружена уже настроенная система."
        log_warn "Скрипт работает в режиме аудита — destructive-действия только по явному подтверждению."
        log_warn "Существующие правила firewall не будут изменены без вашего согласия."
        echo ""
        save_state "EXISTING_VDS" "true"
    else
        log_ok "  Похоже на свежий VDS"
        save_state "EXISTING_VDS" "false"
    fi
}

preflight_snapshot_ufw() {
    if ufw_is_active; then
        ensure_dirs
        if [[ "${DRY_RUN}" != true ]]; then
            LC_ALL=C ufw status numbered > "${SSH_HELPER_BACKUP}/ufw-snapshot-$(date +%Y%m%d-%H%M%S).txt" 2>/dev/null || true
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
