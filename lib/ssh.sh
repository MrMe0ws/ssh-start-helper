#!/bin/bash
# SSH hardening and port migration.

SSH_NEW_PORT=""
SSH_MIGRATE_PORT=false
SSH_CLOSE_PORT22=false

_get_sshd_include_dir() {
    mkdir -p /etc/ssh/sshd_config.d
    echo "/etc/ssh/sshd_config.d"
}

_write_ssh_dropin() {
    local port="$1"
    local permit_root="$2"
    local password_auth="$3"

    backup_dir /etc/ssh
    backup_file "${SSH_HELPER_SSH_DROPIN}"

    cat > "${SSH_HELPER_SSH_DROPIN}" << EOF
# Managed by ssh-start-helper — do not edit manually
Port ${port}
PermitRootLogin ${permit_root}
PasswordAuthentication ${password_auth}
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
EOF

    chmod 644 "${SSH_HELPER_SSH_DROPIN}"
    log_ok "  Конфиг записан: ${SSH_HELPER_SSH_DROPIN}"
}

_validate_sshd_config() {
    if sshd -t 2>/dev/null; then
        log_ok "  sshd -t: конфигурация валидна"
        return 0
    fi
    log_err "  sshd -t: ошибка конфигурации"
    return 1
}

_reload_ssh() {
    if systemctl is-active ssh >/dev/null 2>&1; then
        run_cmd systemctl reload ssh
    elif systemctl is-active sshd >/dev/null 2>&1; then
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
    _reload_ssh 2>/dev/null || true
}

step_ssh_configure() {
    print_step "SSH hardening + смена порта"

    local current_port
    current_port=$(get_ssh_port)
    log_info "  Текущий SSH-порт: ${C_YELLOW}${current_port}${C_RESET}"

    # --- Port change ---
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

    # --- Hardening options ---
    local permit_root="prohibit-password"
    local password_auth="yes"

    if confirm "  Настроить параметры безопасности SSH?" "y"; then
        local root_choice
        root_choice=$(whiptail_menu "PermitRootLogin" "Root-доступ по SSH:" 14 65 3 \
            "prohibit-password" "Только ключ (рекомендуется)" \
            "no" "Запретить root полностью" \
            "yes" "Оставить как есть (небезопасно)") || root_choice="prohibit-password"
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

    # Open new port in UFW before changing sshd (if ufw exists)
    if command -v ufw >/dev/null 2>&1 && [[ "${SSH_MIGRATE_PORT}" == true ]]; then
        log_info "  Открываем порт ${SSH_NEW_PORT} в UFW (до смены sshd)..."
        if [[ "${DRY_RUN}" != true ]]; then
            ufw allow "${SSH_NEW_PORT}/tcp" comment 'ssh-start-helper' >/dev/null 2>&1 || true
        else
            log_dim "  [dry-run] ufw allow ${SSH_NEW_PORT}/tcp"
        fi
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        log_dim "  [dry-run] write ssh dropin port=${SSH_NEW_PORT}"
        save_state "SSH_PORT" "${SSH_NEW_PORT}"
        return 0
    fi

    _write_ssh_dropin "${SSH_NEW_PORT}" "${permit_root}" "${password_auth}"

    if ! _validate_sshd_config; then
        _rollback_ssh_dropin
        return 1
    fi

    _reload_ssh

    if [[ "${SSH_MIGRATE_PORT}" == true && "${SSH_NEW_PORT}" != "${current_port}" ]]; then
        echo ""
        log_warn "  Проверьте вход в НОВОЙ сессии:"
        log_value "  ssh -p " "${SSH_NEW_PORT}" " user@$(hostname -I 2>/dev/null | awk '{print $1}')"
        echo ""

        if confirm "  Новое подключение работает?" "n"; then
            SSH_CLOSE_PORT22=true
            log_ok "  Подключение подтверждено"
        else
            log_err "  Откат изменений SSH..."
            _rollback_ssh_dropin
            if command -v ufw >/dev/null 2>&1; then
                ufw delete allow "${SSH_NEW_PORT}/tcp" >/dev/null 2>&1 || true
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
