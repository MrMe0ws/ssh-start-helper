#!/bin/bash
# User management: sudo user + SSH keys.

_admin_group() {
    if getent group sudo >/dev/null 2>&1; then
        echo "sudo"
    else
        echo "wheel"
    fi
}

_valid_pubkey() {
    local key="$1" tmp rc
    tmp=$(mktemp)
    echo "${key}" > "${tmp}"
    ssh-keygen -l -f "${tmp}" >/dev/null 2>&1
    rc=$?
    rm -f "${tmp}"
    return "${rc}"
}

step_create_user() {
    print_step "Sudo-пользователь"

    if ! confirm "  Создать нового sudo-пользователя?" "n"; then
        log_dim "  Пропущено"
        return 0
    fi

    local username
    username=$(prompt_input "  Имя пользователя" "deploy")
    if [[ ! "${username}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        log_err "  Недопустимое имя: ${username} (латиница в нижнем регистре, цифры, _ и -)"
        return 1
    fi

    local group
    group=$(_admin_group)

    if id "${username}" &>/dev/null; then
        log_ok "  Пользователь ${username} уже существует"
    else
        run_cmd useradd -m -s /bin/bash "${username}" || { log_err "  Не удалось создать пользователя"; return 1; }
        if confirm "  Задать пароль для ${username}?" "y"; then
            run_cmd passwd "${username}" < "${_TTY}" > "${_TTY}" 2>&1 || log_warn "  Пароль не задан"
        else
            log_dim "  Пользователь создан без пароля (вход только по ключу)"
        fi
        log_ok "  Пользователь ${username} создан"
    fi
    run_cmd usermod -aG "${group}" "${username}"
    log_ok "  ${username} добавлен в группу ${group}"

    if confirm "  Добавить SSH-ключ для ${username}?" "y"; then
        local key_source
        local -a menu=("paste" "Вставить ключ вручную" "file" "Путь к файлу на сервере")
        if user_has_ssh_keys root; then
            menu+=("root" "Скопировать ключи root")
        fi
        key_source=$(choose "SSH-ключ" "Откуда взять ключ?" "paste" "${menu[@]}")

        local pubkey=""
        case "${key_source}" in
            file)
                local keyfile
                keyfile=$(prompt_input "  Путь к публичному ключу" "/root/.ssh/id_ed25519.pub")
                if [[ -f "${keyfile}" ]]; then
                    pubkey=$(cat "${keyfile}")
                else
                    log_err "  Файл не найден: ${keyfile}"
                    return 1
                fi
                ;;
            root)
                pubkey=$(grep -E '^[^#]' /root/.ssh/authorized_keys)
                ;;
            *)
                echo -en "${C_BOLD}${C_CYAN}?${C_RESET}   Вставьте публичный ключ (одной строкой) и нажмите Enter: " > "${_TTY}"
                read -r pubkey < "${_TTY}" || pubkey=""
                ;;
        esac

        if [[ -z "${pubkey}" ]]; then
            log_warn "  Ключ пустой — пропуск"
        elif [[ "${key_source}" != "root" ]] && ! _valid_pubkey "${pubkey}"; then
            log_err "  Это не похоже на публичный SSH-ключ (ожидается ssh-ed25519 AAAA... или ssh-rsa AAAA...)"
            return 1
        elif [[ "${DRY_RUN}" == true ]]; then
            log_dim "  [dry-run] добавить ключ для ${username}"
        else
            local user_home auth
            user_home=$(getent passwd "${username}" | cut -d: -f6)
            auth="${user_home}/.ssh/authorized_keys"
            mkdir -p "${user_home}/.ssh"
            touch "${auth}"
            local line
            while IFS= read -r line; do
                [[ -n "${line}" ]] || continue
                grep -qxF "${line}" "${auth}" || echo "${line}" >> "${auth}"
            done <<< "${pubkey}"
            chmod 700 "${user_home}/.ssh"
            chmod 600 "${auth}"
            chown -R "${username}:" "${user_home}/.ssh"
            command -v restorecon >/dev/null 2>&1 && restorecon -R "${user_home}/.ssh" 2>/dev/null || true
            log_ok "  SSH-ключ добавлен для ${username}"
        fi
    fi

    save_state "USER_CREATED" "${username}"
}
