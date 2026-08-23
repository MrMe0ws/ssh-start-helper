#!/bin/bash
# SSH hardening and port migration.

SSH_NEW_PORT=""
SSH_MIGRATE_PORT=false
SSH_CLOSE_PORT22=false
SSH_SOCKET_WAS_ACTIVE=false
SSH_DO_HARDEN=false

_audit_sshd_dropins() {
    if [[ ! -d /etc/ssh/sshd_config.d ]]; then
        return
    fi
    local f
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "${f}" ]] || continue
        if grep -qiE '^Port[[:space:]]+' "${f}" 2>/dev/null; then
            log_dim "  Найден Port в ${f}: $(grep -iE '^Port' "${f}" | head -1)"
        fi
    done
}

_write_ssh_dropin() {
    local port="$1"
    local with_hardening="$2"
    local permit_root="${3:-prohibit-password}"
    local password_auth="${4:-yes}"

    backup_dir /etc/ssh
    backup_file "${SSH_HELPER_SSH_DROPIN}"

    {
        echo "# Managed by ssh-start-helper — do not edit manually"
        if [[ -n "${port}" ]]; then
            echo "Port ${port}"
        fi
        if [[ "${with_hardening}" == true ]]; then
            echo "PermitRootLogin ${permit_root}"
            echo "PasswordAuthentication ${password_auth}"
            echo "MaxAuthTries 3"
            echo "LoginGraceTime 30"
            echo "X11Forwarding no"
        fi
    } > "${SSH_HELPER_SSH_DROPIN}"

    sed -i 's/\r$//' "${SSH_HELPER_SSH_DROPIN}" 2>/dev/null || true
    chmod 644 "${SSH_HELPER_SSH_DROPIN}"
    log_ok "  Конфиг записан: ${SSH_HELPER_SSH_DROPIN}"
    if [[ "${with_hardening}" != true ]]; then
        log_dim "  (только Port — hardening не менялся)"
    fi
}

_validate_sshd_config() {
    local err
    err=$(sshd -t -f /etc/ssh/sshd_config 2>&1) && {
        log_ok "  sshd -t: конфигурация валидна"
        return 0
    }
    log_err "  sshd -t: ошибка конфигурации"
    echo "${err}" | sed 's/^/    /' >&2
    log_dim "  Проверьте: grep -r . /etc/ssh/sshd_config.d/"
    return 1
}

# Ubuntu 22.04+/24.04: ssh.socket слушает :22 и блокирует смену порта
_disable_ubuntu_ssh_socket() {
    if systemctl list-unit-files ssh.socket &>/dev/null 2>&1; then
        if systemctl is-active ssh.socket &>/dev/null; then
            SSH_SOCKET_WAS_ACTIVE=true
            log_warn "  Ubuntu ssh.socket активен — отключаем (иначе порт 22 останется)"
            systemctl stop ssh.socket
            systemctl disable ssh.socket
            systemctl enable ssh.service
        fi
    fi
}

_restore_ubuntu_ssh_socket() {
    if [[ "${SSH_SOCKET_WAS_ACTIVE}" == true ]]; then
        log_info "  Восстановление ssh.socket..."
        systemctl disable ssh.service 2>/dev/null || true
        systemctl enable ssh.socket
        systemctl start ssh.socket
        SSH_SOCKET_WAS_ACTIVE=false
    fi
}

_restart_ssh() {
    if systemctl is-active ssh &>/dev/null 2>&1; then
        run_cmd systemctl restart ssh
    elif systemctl is-active sshd &>/dev/null 2>&1; then
        run_cmd systemctl restart sshd
    else
        run_cmd systemctl restart ssh 2>/dev/null || run_cmd systemctl restart sshd
    fi
    sleep 1
    log_ok "  SSH перезапущен (restart)"
}

_reload_ssh() {
    if systemctl is-active ssh &>/dev/null 2>&1; then
        run_cmd systemctl reload ssh
    elif systemctl is-active sshd &>/dev/null 2>&1; then
        run_cmd systemctl reload sshd
    else
        run_cmd systemctl restart ssh 2>/dev/null || run_cmd systemctl restart sshd
    fi
    log_ok "  SSH перезагружен"
}

_rollback_ssh_dropin() {
    if [[ -f "${SSH_HELPER_SSH_DROPIN}" ]]; then
        rm -f "${SSH_HELPER_SSH_DROPIN}"
        log_warn "  Drop-in конфиг удалён (откат)"
    fi
    _restore_ubuntu_ssh_socket
    _restart_ssh 2>/dev/null || _reload_ssh 2>/dev/null || true
}

_verify_sshd_port() {
    local port="$1"
    if sshd_listens_on_port "${port}"; then
        log_ok "  sshd слушает порт ${port}"
        return 0
    fi
    log_err "  sshd НЕ слушает порт ${port} (проверка: ss -tlnp | grep ssh)"
    ss -tlnp 2>/dev/null | grep -E 'sshd|:22|:2228' | sed 's/^/    /' || true
    return 1
}

_show_ssh_test_hint() {
    local port="$1"
    local ip user
    ip=$(get_server_ip)
    user="${SUDO_USER:-${USER:-root}}"
    [[ "${user}" == "root" && -n "${SSH_CONNECTION:-}" ]] && user="root"

    echo ""
    log_warn "  Откройте НОВОЕ окно терминала и проверьте вход:"
    echo ""
    echo -e "    ${C_YELLOW}ssh -p ${port} ${user}@${ip}${C_RESET}"
    echo ""
    log_warn "  Если не подключается:"
    log_dim "    1. Откройте порт ${port}/tcp в панели VDS (cloud firewall)"
    log_dim "    2. UFW: ufw status | grep ${port}"
    log_dim "    3. На сервере: ss -tlnp | grep ${port}"
    echo ""
}

step_ssh_configure() {
    print_step "SSH hardening + смена порта"

    local current_port
    current_port=$(get_ssh_port)
    log_info "  Текущий SSH-порт: ${C_YELLOW}${current_port}${C_RESET}"

    if confirm "  Сменить SSH-порт?" "n"; then
        SSH_MIGRATE_PORT=true
        local new_port
        new_port=$(prompt_input "  Новый SSH-порт" "2228")

        while ! is_valid_port "${new_port}"; do
            log_err "  Порт должен быть 1024–65535"
            new_port=$(prompt_input "  Новый SSH-порт" "2228")
        done

        if port_in_use "${new_port}" && [[ "${new_port}" != "${current_port}" ]]; then
            log_warn "  Порт ${new_port} уже занят процессом"
            confirm "  Всё равно использовать?" "n" || return 1
        fi

        SSH_NEW_PORT="${new_port}"
    else
        SSH_NEW_PORT="${current_port}"
        log_dim "  Порт останется: ${current_port}"
    fi

    local permit_root="prohibit-password"
    local password_auth="yes"

    if confirm "  Настроить параметры безопасности SSH?" "y"; then
        SSH_DO_HARDEN=true
        local root_choice
        root_choice=$(whiptail --title "PermitRootLogin" --menu "Root-доступ по SSH:" 14 65 3 \
            "prohibit-password" "Только ключ (рекомендуется)" \
            "no" "Запретить root полностью" \
            "yes" "Оставить как есть (небезопасно)" \
            3>&1 1>&2 2>&3) || root_choice="prohibit-password"
        restore_tty
        permit_root="${root_choice}"

        if confirm "  Отключить вход по паролю (только ключи)?" "n"; then
            password_auth="no"
        else
            password_auth="yes"
        fi
    fi

    if [[ "${SSH_MIGRATE_PORT}" != true && "${current_port}" == "${SSH_NEW_PORT}" ]]; then
        if [[ -f "${SSH_HELPER_SSH_DROPIN}" ]]; then
            log_ok "  SSH уже настроен скриптом, пропуск"
            return 0
        fi
        if ! confirm "  Применить hardening без смены порта?" "y"; then
            return 0
        fi
    fi

    echo ""
    log_warn "  НЕ ЗАКРЫВАЙТЕ текущую SSH-сессию до проверки нового подключения!"
    echo ""

    backup_dir /etc/ssh

    if command -v ufw >/dev/null 2>&1 && [[ "${SSH_MIGRATE_PORT}" == true ]]; then
        log_info "  Открываем порт ${SSH_NEW_PORT} в UFW..."
        if [[ "${DRY_RUN}" != true ]]; then
            ufw allow "${SSH_NEW_PORT}/tcp" comment 'ssh-start-helper' >/dev/null 2>&1 || true
            log_ok "  UFW: allow ${SSH_NEW_PORT}/tcp"
        else
            log_dim "  [dry-run] ufw allow ${SSH_NEW_PORT}/tcp"
        fi
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        log_dim "  [dry-run] write ssh dropin port=${SSH_NEW_PORT}"
        save_state "SSH_PORT" "${SSH_NEW_PORT}"
        return 0
    fi

    _audit_sshd_dropins
    _write_ssh_dropin "${SSH_NEW_PORT}" "${SSH_DO_HARDEN}" "${permit_root}" "${password_auth}"

    if ! _validate_sshd_config; then
        rm -f "${SSH_HELPER_SSH_DROPIN}"
        log_warn "  Drop-in удалён (откат конфига)"
        return 1
    fi

    if [[ "${SSH_MIGRATE_PORT}" == true && "${SSH_NEW_PORT}" != "${current_port}" ]]; then
        _disable_ubuntu_ssh_socket
    fi

    if [[ "${SSH_MIGRATE_PORT}" == true && "${SSH_NEW_PORT}" != "${current_port}" ]]; then
        _restart_ssh
    else
        _reload_ssh
    fi

    if [[ "${SSH_MIGRATE_PORT}" == true && "${SSH_NEW_PORT}" != "${current_port}" ]]; then
        if ! _verify_sshd_port "${SSH_NEW_PORT}"; then
            log_err "  Смена порта не применилась — откат"
            _rollback_ssh_dropin
            return 1
        fi

        _show_ssh_test_hint "${SSH_NEW_PORT}"

        if confirm "  Новое подключение работает?" "n"; then
            SSH_CLOSE_PORT22=true
            log_ok "  Подключение подтверждено"
        else
            log_err "  Откат изменений SSH..."
            _rollback_ssh_dropin
            if command -v ufw >/dev/null 2>&1; then
                local rule_num
                rule_num=$(ufw status numbered 2>/dev/null | grep -E "${SSH_NEW_PORT}/tcp.*ALLOW" | head -1 | sed -n 's/^\[\([0-9]*\)\].*/\1/p')
                [[ -n "${rule_num}" ]] && ufw --force delete "${rule_num}" >/dev/null 2>&1 || true
            fi
            return 1
        fi
    fi

    save_state "SSH_PORT" "${SSH_NEW_PORT}"
    save_state "SSH_CONFIGURED" "true"
    log_ok "  SSH настроен (порт ${SSH_NEW_PORT})"
}

step_ssh_close_port22() {
    if [[ "${SSH_CLOSE_PORT22}" != true ]]; then
        return 0
    fi

    if ! command -v ufw >/dev/null 2>&1; then
        return 0
    fi

    print_step "Закрытие порта 22"

    if ufw status numbered 2>/dev/null | grep -qE '22/tcp.*ALLOW'; then
        if confirm "  Удалить правило ALLOW для порта 22?" "y"; then
            local rule_num
            rule_num=$(ufw status numbered 2>/dev/null | grep -E '22/tcp.*ALLOW' | head -1 | sed -n 's/^\[\([0-9]*\)\].*/\1/p')
            if [[ -n "${rule_num}" ]]; then
                run_cmd ufw --force delete "${rule_num}"
                log_ok "  Правило [${rule_num}] 22/tcp удалено"
            fi
        fi
    else
        log_dim "  Правило для 22/tcp не найдено"
    fi
}
