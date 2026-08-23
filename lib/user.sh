#!/bin/bash
# User management: sudo user + SSH keys.

step_create_user() {
    print_step "Sudo-пользователь"

    if ! confirm "  Создать нового sudo-пользователя?" "n"; then
        log_dim "  Пропущено"
        return 0
    fi

    local username
    username=$(prompt_input "  Имя пользователя" "deploy")

    if id "${username}" &>/dev/null; then
        log_ok "  Пользователь ${username} уже существует"
    else
        if confirm "  Задать пароль для ${username}?" "n"; then
            run_cmd adduser --gecos "" "${username}"
        else
            run_cmd adduser --disabled-password --gecos "" "${username}"
            log_dim "  Пользователь создан без пароля"
        fi
        run_cmd usermod -aG sudo "${username}"
        log_ok "  Пользователь ${username} создан и добавлен в sudo"
    fi

    if confirm "  Добавить SSH-ключ для ${username}?" "y"; then
        local key_source
        key_source=$(whiptail_menu "SSH-ключ" "Откуда взять ключ?" 12 60 2 \
            "paste" "Вставить ключ вручную" \
            "file" "Путь к файлу на сервере" \
            3>&1 1>&2 2>&3) || key_source="paste"
        restore_tty

        local pubkey=""
        case "${key_source}" in
            file)
                local keyfile
                keyfile=$(prompt_input "  Путь к публичному ключу" "/root/.ssh/id_rsa.pub")
                if [[ -f "${keyfile}" ]]; then
                    pubkey=$(cat "${keyfile}")
                else
                    log_err "  Файл не найден: ${keyfile}"
                    return 1
                fi
                ;;
            *)
                echo ""
                echo -en "${C_BOLD}${C_CYAN}?${C_RESET}   Вставьте публичный ключ (одной строкой) и нажмите Enter: " > "${_TTY:-/dev/tty}"
                read -r pubkey < "${_TTY:-/dev/tty}"
                ;;
        esac

        if [[ -n "${pubkey}" ]]; then
            local user_home
            user_home=$(getent passwd "${username}" | cut -d: -f6)
            run_cmd mkdir -p "${user_home}/.ssh"
            echo "${pubkey}" >> "${user_home}/.ssh/authorized_keys"
            run_cmd chmod 700 "${user_home}/.ssh"
            run_cmd chmod 600 "${user_home}/.ssh/authorized_keys"
            run_cmd chown -R "${username}:${username}" "${user_home}/.ssh"
            log_ok "  SSH-ключ добавлен для ${username}"
        fi
    fi

    save_state "USER_CREATED" "${username}"
}
