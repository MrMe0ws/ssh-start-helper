#!/bin/bash
# SSH hardening and port migration.
#
# Как применяются настройки:
#  - OpenSSH >= 8.2: drop-in 00-ssh-start-helper.conf + Include в начале sshd_config
#    (sshd берёт ПЕРВОЕ значение директивы, поэтому наш файл должен читаться первым);
#  - OpenSSH < 8.2: управляемый блок в начале sshd_config.
#  - Port суммируется (каждая строка Port — ещё один порт), поэтому при смене порта
#    чужие строки Port комментируются.
#  - Перед перезапуском ставится «мёртвая рука»: если за SSH_ROLLBACK_TIMEOUT секунд
#    новое подключение не подтверждено (например, оборвалась сессия) — автооткат.

SSH_NEW_PORT=""
SSH_MIGRATE_PORT=false
SSH_CLOSE_PORT22=false
SSH_SERVICE=""
SSH_BACKUP_PATH=""
SSH_SOCKET_WAS_ACTIVE=false
SSH_SERVICE_WAS_ENABLED=false

readonly SSH_ROLLBACK_SCRIPT="${SSH_HELPER_DIR}/ssh-rollback.sh"
readonly SSH_ROLLBACK_CONFIRMED="${SSH_HELPER_DIR}/ssh-rollback.confirmed"
readonly SSH_ROLLBACK_DONE="${SSH_HELPER_DIR}/ssh-rollback.done"
readonly SSH_ROLLBACK_PID="${SSH_HELPER_DIR}/ssh-rollback.pid"
readonly SSH_ROLLBACK_TIMEOUT="${SSH_ROLLBACK_TIMEOUT:-600}"
readonly SSH_BLOCK_BEGIN="# BEGIN ssh-start-helper"
readonly SSH_BLOCK_END="# END ssh-start-helper"

_use_dropin() {
    local v
    v=$(openssh_version_num)
    (( v == 0 || v >= 802 ))
}

_login_user() {
    local u="${SUDO_USER:-}"
    [[ -z "${u}" ]] && u=$(logname 2>/dev/null || true)
    echo "${u:-root}"
}

_audit_sshd_dropins() {
    [[ -d /etc/ssh/sshd_config.d ]] || return 0
    local f
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "${f}" && "${f}" != "${SSH_HELPER_SSH_DROPIN}" ]] || continue
        if grep -qiE '^[[:space:]]*(Port|PermitRootLogin|PasswordAuthentication)[[:space:]]' "${f}" 2>/dev/null; then
            log_dim "  ${f}: $(grep -iE '^[[:space:]]*(Port|PermitRootLogin|PasswordAuthentication)[[:space:]]' "${f}" | tr '\n' ';')"
        fi
    done
}

# Include sshd_config.d должен стоять до первой директивы, иначе значения из
# основного конфига перекроют наш drop-in.
_ensure_include_first() {
    local cfg=/etc/ssh/sshd_config
    mkdir -p /etc/ssh/sshd_config.d

    local first_directive include_line
    first_directive=$(grep -nvE '^[[:space:]]*(#|$)' "${cfg}" | head -1 | cut -d: -f1)
    include_line=$(grep -niE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "${cfg}" | head -1 | cut -d: -f1)

    if [[ -n "${include_line}" && ( -z "${first_directive}" || "${include_line}" -le "${first_directive}" ) ]]; then
        return 0
    fi

    sed -i -E 's|^([[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf.*)$|# ssh-start-helper (moved to top): \1|I' "${cfg}"
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "${cfg}"
    log_ok "  Include sshd_config.d перенесён в начало sshd_config"
}

# Комментирует строки Port во всех конфигах, кроме нашего
_neutralize_foreign_ports() {
    local f changed=()
    for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "${f}" && "${f}" != "${SSH_HELPER_SSH_DROPIN}" ]] || continue
        if grep -qiE '^[[:space:]]*Port[[:space:]]+[0-9]+' "${f}"; then
            sed -i -E 's/^([[:space:]]*Port[[:space:]]+[0-9]+.*)$/# ssh-start-helper: \1/I' "${f}"
            changed+=("${f}")
        fi
    done
    if (( ${#changed[@]} > 0 )); then
        log_ok "  Закомментированы старые Port в: ${changed[*]}"
    fi
    if grep -hiE '^[[:space:]]*ListenAddress[[:space:]]+.*:[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | grep -q .; then
        log_warn "  Найден ListenAddress с явным портом — он продолжит работать, проверьте вручную"
    fi
}

_ssh_settings_content() {
    local port="$1" harden="$2" permit_root="$3" password_auth="$4"
    echo "# Managed by ssh-start-helper — do not edit manually"
    [[ -n "${port}" ]] && echo "Port ${port}"
    if [[ "${harden}" == true ]]; then
        echo "PermitRootLogin ${permit_root}"
        echo "PasswordAuthentication ${password_auth}"
        echo "PermitEmptyPasswords no"
        echo "MaxAuthTries 5"
        echo "LoginGraceTime 30"
        echo "X11Forwarding no"
    fi
}

_write_ssh_settings() {
    local content
    content=$(_ssh_settings_content "$@")

    if _use_dropin; then
        _ensure_include_first
        rm -f "${SSH_HELPER_SSH_DROPIN_OLD}"
        printf '%s\n' "${content}" > "${SSH_HELPER_SSH_DROPIN}"
        chmod 644 "${SSH_HELPER_SSH_DROPIN}"
        log_ok "  Конфиг записан: ${SSH_HELPER_SSH_DROPIN}"
    else
        local cfg=/etc/ssh/sshd_config tmp
        tmp=$(mktemp)
        {
            echo "${SSH_BLOCK_BEGIN}"
            printf '%s\n' "${content}"
            echo "${SSH_BLOCK_END}"
            sed "/^${SSH_BLOCK_BEGIN}\$/,/^${SSH_BLOCK_END}\$/d" "${cfg}"
        } > "${tmp}"
        cat "${tmp}" > "${cfg}"
        rm -f "${tmp}"
        log_ok "  Блок настроек записан в начало ${cfg}"
    fi
}

_validate_sshd_config() {
    local err
    _ensure_sshd_rundir
    if err=$("$(sshd_bin)" -t 2>&1); then
        log_ok "  sshd -t: конфигурация валидна"
        return 0
    fi
    log_err "  sshd -t: ошибка конфигурации"
    echo "${err}" | sed 's/^/    /' >&2
    return 1
}

# Сверяем то, что реально применит sshd, с тем, что мы хотели
_check_effective() {
    local want_port="$1" harden="$2" permit_root="$3" password_auth="$4"
    local ok=true

    if [[ -n "${want_port}" ]]; then
        local ports
        ports=$(get_ssh_ports)
        if [[ "${ports}" != "${want_port}" ]]; then
            log_err "  sshd будет слушать: ${ports} (ожидалось ${want_port})"
            return 1
        fi
    fi

    if [[ "${harden}" == true ]]; then
        local eff_root eff_pass
        eff_root=$(sshd_effective_value permitrootlogin)
        eff_pass=$(sshd_effective_value passwordauthentication)
        [[ "${eff_root}" == "without-password" ]] && eff_root="prohibit-password"
        if [[ "${eff_root}" != "${permit_root}" ]]; then
            log_warn "  PermitRootLogin фактически: ${eff_root} (ожидалось ${permit_root})"
            ok=false
        fi
        if [[ "${eff_pass}" != "${password_auth}" ]]; then
            log_warn "  PasswordAuthentication фактически: ${eff_pass} (ожидалось ${password_auth})"
            ok=false
        fi
        if [[ "${ok}" != true ]]; then
            log_dim "  Возможно, значение переопределяет блок Match в sshd_config"
        fi
    fi
    return 0
}

_selinux_allow_port() {
    local port="$1"
    command -v getenforce >/dev/null 2>&1 || return 0
    [[ "$(getenforce 2>/dev/null)" != "Disabled" ]] || return 0

    if ! command -v semanage >/dev/null 2>&1; then
        log_info "  SELinux активен — установка semanage..."
        pkg_install policycoreutils-python-utils >/dev/null 2>&1 \
            || pkg_install policycoreutils-python >/dev/null 2>&1 \
            || { log_err "  Не удалось установить semanage — sshd не сможет слушать ${port}"; return 1; }
    fi

    if semanage port -l 2>/dev/null | awk '$1=="ssh_port_t"' | grep -qE "[ ,]${port}(,|$)"; then
        return 0
    fi
    semanage port -a -t ssh_port_t -p tcp "${port}" 2>/dev/null \
        || semanage port -m -t ssh_port_t -p tcp "${port}" 2>/dev/null \
        || { log_err "  SELinux: не удалось разрешить порт ${port}"; return 1; }
    log_ok "  SELinux: порт ${port} разрешён для sshd"
}

# Ubuntu 22.10+: ssh.socket слушает :22 сам и игнорирует Port в конфиге
_disable_ssh_socket() {
    systemctl is-enabled "${SSH_SERVICE}.service" >/dev/null 2>&1 && SSH_SERVICE_WAS_ENABLED=true
    if systemctl is-active ssh.socket >/dev/null 2>&1 || systemctl is-enabled ssh.socket >/dev/null 2>&1; then
        SSH_SOCKET_WAS_ACTIVE=true
        log_warn "  ssh.socket активен — переключаем на ssh.service (иначе порт не сменится)"
        systemctl disable --now ssh.socket >/dev/null 2>&1 || true
        systemctl enable "${SSH_SERVICE}.service" >/dev/null 2>&1 || true
    fi
}

_restart_ssh() {
    if ! systemctl restart "${SSH_SERVICE}"; then
        log_err "  systemctl restart ${SSH_SERVICE} завершился с ошибкой"
        return 1
    fi
    log_ok "  SSH перезапущен"
}

_reload_ssh() {
    if systemctl is-active "${SSH_SERVICE}" >/dev/null 2>&1; then
        systemctl reload "${SSH_SERVICE}" 2>/dev/null || systemctl restart "${SSH_SERVICE}"
    fi
    log_ok "  SSH перечитал конфиг"
}

_wait_ssh_port() {
    local port="$1"
    for _ in $(seq 1 15); do
        ssh_banner_ok "${port}" && return 0
        sleep 1
    done
    return 1
}

# Скрипт отката: восстанавливает /etc/ssh из бэкапа и прежний режим запуска sshd.
# Аргумент — задержка в секундах (0 — откатить сейчас).
_write_rollback_script() {
    cat > "${SSH_ROLLBACK_SCRIPT}" << EOF
#!/bin/bash
# Generated by ssh-start-helper
sleep "\${1:-0}"
[ -f "${SSH_ROLLBACK_CONFIRMED}" ] && exit 0
rm -f "${SSH_HELPER_SSH_DROPIN}"
cp -a "${SSH_BACKUP_PATH}/." /etc/ssh/
if [ "${SSH_SOCKET_WAS_ACTIVE}" = true ]; then
    systemctl stop ${SSH_SERVICE}.service
    [ "${SSH_SERVICE_WAS_ENABLED}" = true ] || systemctl disable ${SSH_SERVICE}.service
    systemctl enable --now ssh.socket
else
    systemctl restart ${SSH_SERVICE}
fi
$(_rollback_fw_cleanup)
touch "${SSH_ROLLBACK_DONE}"
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] [WARN] SSH rollback executed" >> "${SSH_HELPER_LOG}"
EOF
    chmod 700 "${SSH_ROLLBACK_SCRIPT}"
}

# Удаление временного правила firewall для нового порта (строка для скрипта отката)
_rollback_fw_cleanup() {
    [[ "${SSH_MIGRATE_PORT}" == true && -n "${SSH_NEW_PORT}" ]] || return 0
    case "$(fw_backend)" in
        ufw) echo "LC_ALL=C ufw --force delete allow ${SSH_NEW_PORT}/tcp >/dev/null 2>&1" ;;
        firewalld) echo "firewall-cmd --permanent --remove-port=${SSH_NEW_PORT}/tcp >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1" ;;
    esac
}

_arm_rollback_timer() {
    rm -f "${SSH_ROLLBACK_CONFIRMED}" "${SSH_ROLLBACK_DONE}"
    _write_rollback_script
    # setsid: таймер переживёт обрыв SSH-сессии
    setsid nohup bash "${SSH_ROLLBACK_SCRIPT}" "${SSH_ROLLBACK_TIMEOUT}" >/dev/null 2>&1 < /dev/null &
    echo $! > "${SSH_ROLLBACK_PID}"
    local t="${SSH_ROLLBACK_TIMEOUT} сек"
    (( SSH_ROLLBACK_TIMEOUT >= 60 )) && t="$(( SSH_ROLLBACK_TIMEOUT / 60 )) мин"
    log_dim "  Страховка: если не подтвердить за ${t} — автооткат SSH"
}

_disarm_rollback_timer() {
    touch "${SSH_ROLLBACK_CONFIRMED}"
    if [[ -f "${SSH_ROLLBACK_PID}" ]]; then
        kill "$(cat "${SSH_ROLLBACK_PID}")" 2>/dev/null || true
        pkill -f "${SSH_ROLLBACK_SCRIPT}" 2>/dev/null || true
        rm -f "${SSH_ROLLBACK_PID}"
    fi
}

_rollback_now() {
    log_warn "  Откат изменений SSH..."
    _disarm_rollback_timer
    rm -f "${SSH_ROLLBACK_CONFIRMED}"
    bash "${SSH_ROLLBACK_SCRIPT}" 0
    rm -f "${SSH_ROLLBACK_DONE}"
    log_ok "  SSH возвращён к прежней конфигурации (порт(ы): $(get_ssh_ports))"
}

_restore_backup_quiet() {
    rm -f "${SSH_HELPER_SSH_DROPIN}"
    [[ -n "${SSH_BACKUP_PATH}" ]] && cp -a "${SSH_BACKUP_PATH}/." /etc/ssh/
}

_show_ssh_test_hint() {
    local port="$1"
    local ip user
    ip=$(get_server_ip)
    user=$(_login_user)

    echo ""
    log_warn "  НЕ закрывая это окно, откройте НОВОЕ и проверьте вход:"
    echo ""
    echo -e "    ${C_YELLOW}ssh -p ${port} ${user}@${ip}${C_RESET}"
    echo ""
    log_dim "  Если не подключается:"
    log_dim "    1. Откройте порт ${port}/tcp в панели хостера (cloud firewall), если он там есть"
    log_dim "    2. Firewall на сервере: ufw status | grep ${port}  /  firewall-cmd --list-ports"
    log_dim "    3. На сервере: ss -tlnp | grep ${port}"
    echo ""
}

_ask_hardening() {
    local login_user root_has_keys=false user_has_keys=false
    login_user=$(_login_user)
    user_has_ssh_keys root && root_has_keys=true
    user_has_ssh_keys "${login_user}" && user_has_keys=true

    local cur_root default_root
    cur_root=$(sshd_effective_value permitrootlogin)
    [[ "${cur_root}" == "without-password" ]] && cur_root="prohibit-password"
    if [[ "${root_has_keys}" == true ]]; then
        default_root="prohibit-password"
    else
        default_root="yes"
    fi
    log_info "  Сейчас: PermitRootLogin=${cur_root:-?}, PasswordAuthentication=$(sshd_effective_value passwordauthentication)"
    log_info "  SSH-ключи у root: $([[ ${root_has_keys} == true ]] && echo есть || echo нет)"

    HARDEN_PERMIT_ROOT=$(choose "PermitRootLogin" "Вход root по SSH:" "${default_root}" \
        "yes" "Разрешить root (пароль и ключ)" \
        "prohibit-password" "root только по ключу" \
        "no" "Запретить вход root полностью")

    if [[ "${HARDEN_PERMIT_ROOT}" != "yes" && "${login_user}" == "root" && "${root_has_keys}" != true ]]; then
        log_warn "  У root нет SSH-ключей — с '${HARDEN_PERMIT_ROOT}' вы потеряете доступ под root!"
        if ! confirm "  Всё равно применить?" "n"; then
            HARDEN_PERMIT_ROOT="yes"
            log_dim "  PermitRootLogin оставлен: yes"
        fi
    fi

    HARDEN_PASSWORD_AUTH="yes"
    if confirm "  Отключить вход по паролю (только ключи)?" "n"; then
        if [[ "${user_has_keys}" != true ]]; then
            log_warn "  У пользователя ${login_user} нет SSH-ключей — без пароля вы не войдёте!"
            if confirm "  Всё равно отключить пароли?" "n"; then
                HARDEN_PASSWORD_AUTH="no"
            fi
        else
            HARDEN_PASSWORD_AUTH="no"
        fi
    fi
    if [[ "${HARDEN_PASSWORD_AUTH}" == "yes" ]]; then
        log_dim "  Вход по паролю оставлен — используйте длинный случайный пароль (16+ символов) и fail2ban"
    fi
}

step_ssh_configure() {
    print_step "SSH hardening + смена порта"

    SSH_SERVICE=$(ssh_service_name)
    local current_ports current_port
    current_ports=$(get_ssh_ports)
    current_port="${current_ports%% *}"
    log_info "  Текущий SSH-порт: ${C_YELLOW}${current_ports}${C_RESET} (сервис ${SSH_SERVICE})"
    _audit_sshd_dropins

    SSH_MIGRATE_PORT=false
    SSH_NEW_PORT=""
    if confirm "  Сменить SSH-порт?" "y"; then
        local new_port
        new_port=$(prompt_input "  Новый SSH-порт" "2228")
        while ! is_valid_port "${new_port}"; do
            log_err "  Порт должен быть числом 1024–65535"
            new_port=$(prompt_input "  Новый SSH-порт" "2228")
        done

        if [[ "${current_ports}" == "${new_port}" ]]; then
            log_ok "  SSH уже на порту ${new_port}"
        else
            local owner
            owner=$(port_owner "${new_port}")
            if [[ -n "${owner}" && "${owner}" != sshd* ]]; then
                log_err "  Порт ${new_port} занят процессом ${owner}"
                return 1
            fi
            SSH_MIGRATE_PORT=true
            SSH_NEW_PORT="${new_port}"
        fi
    fi

    local harden=false
    HARDEN_PERMIT_ROOT="yes"
    HARDEN_PASSWORD_AUTH="yes"
    if confirm "  Настроить параметры безопасности SSH?" "y"; then
        harden=true
        _ask_hardening
    fi

    if [[ "${SSH_MIGRATE_PORT}" != true && "${harden}" != true ]]; then
        log_dim "  Нечего менять"
        return 0
    fi

    local check_port="${SSH_NEW_PORT:-${current_port}}"

    if [[ "${DRY_RUN}" == true ]]; then
        log_dim "  [dry-run] настройки sshd:"
        _ssh_settings_content "${SSH_NEW_PORT}" "${harden}" "${HARDEN_PERMIT_ROOT}" "${HARDEN_PASSWORD_AUTH}" | sed 's/^/      /'
        [[ "${SSH_MIGRATE_PORT}" == true ]] && log_dim "  [dry-run] firewall allow ${SSH_NEW_PORT}/tcp, restart ${SSH_SERVICE}"
        return 0
    fi

    echo ""
    log_warn "  НЕ ЗАКРЫВАЙТЕ текущую SSH-сессию до проверки нового подключения!"
    echo ""

    SSH_BACKUP_PATH=$(backup_dir /etc/ssh)
    if [[ -z "${SSH_BACKUP_PATH}" || ! -d "${SSH_BACKUP_PATH}" ]]; then
        log_err "  Не удалось сделать бэкап /etc/ssh — прерываю"
        return 1
    fi

    # Повторный запуск только hardening: сохраняем порт, ранее заданный скриптом
    # (в т.ч. из старого 99-ssh-start-helper.conf, который будет заменён)
    if [[ "${SSH_MIGRATE_PORT}" != true ]]; then
        local prev_port
        prev_port=$(grep -hiE '^Port[[:space:]]+' "${SSH_HELPER_SSH_DROPIN}" "${SSH_HELPER_SSH_DROPIN_OLD}" 2>/dev/null             | awk '{print $2}' | head -1)
        [[ -n "${prev_port}" ]] && SSH_NEW_PORT="${prev_port}"
    fi

    if [[ "${SSH_MIGRATE_PORT}" == true ]]; then
        fw_allow_port "${SSH_NEW_PORT}" tcp "ssh-start-helper" && log_ok "  Firewall: allow ${SSH_NEW_PORT}/tcp"
        _selinux_allow_port "${SSH_NEW_PORT}" || return 1
    fi

    _write_ssh_settings "${SSH_NEW_PORT}" "${harden}" "${HARDEN_PERMIT_ROOT}" "${HARDEN_PASSWORD_AUTH}"
    [[ "${SSH_MIGRATE_PORT}" == true ]] && _neutralize_foreign_ports

    if ! _validate_sshd_config || ! _check_effective \
        "$([[ ${SSH_MIGRATE_PORT} == true ]] && echo "${SSH_NEW_PORT}")" \
        "${harden}" "${HARDEN_PERMIT_ROOT}" "${HARDEN_PASSWORD_AUTH}"; then
        _restore_backup_quiet
        log_warn "  Конфиг восстановлен из бэкапа, sshd не перезапускался"
        return 1
    fi

    [[ "${SSH_MIGRATE_PORT}" == true ]] && _disable_ssh_socket
    _arm_rollback_timer

    if [[ "${SSH_MIGRATE_PORT}" == true ]]; then
        _restart_ssh || { _rollback_now; return 1; }
    else
        _reload_ssh
    fi

    if ! _wait_ssh_port "${check_port}"; then
        log_err "  sshd не отвечает на порту ${check_port}"
        ss -tlnp 2>/dev/null | grep -i ssh | sed 's/^/    /' || true
        _rollback_now
        return 1
    fi
    log_ok "  sshd отвечает на порту ${check_port}"

    _show_ssh_test_hint "${check_port}"

    if confirm "  Новое подключение работает?" "n"; then
        if [[ -f "${SSH_ROLLBACK_DONE}" ]]; then
            log_err "  Автооткат уже сработал по таймеру — запустите этап заново"
            return 1
        fi
        _disarm_rollback_timer
        log_ok "  Подключение подтверждено"
    else
        _rollback_now
        return 1
    fi

    if [[ "${SSH_MIGRATE_PORT}" == true ]]; then
        [[ " $(get_ssh_ports) " != *" 22 "* ]] && SSH_CLOSE_PORT22=true
        # fail2ban должен банить на новом порту
        if command -v fail2ban-client >/dev/null 2>&1; then
            fail2ban_apply_config && fail2ban_reload
        fi
    fi

    save_state "SSH_PORT" "$(get_ssh_port)"
    save_state "SSH_CONFIGURED" "true"
    log_ok "  SSH настроен (порт $(get_ssh_ports))"
}

step_ssh_close_port22() {
    [[ "${SSH_CLOSE_PORT22}" == true ]] || return 0

    print_step "Закрытие порта 22"

    if [[ " $(get_ssh_ports) " == *" 22 "* ]]; then
        log_dim "  sshd всё ещё слушает 22 — порт не закрываем"
        return 0
    fi

    if [[ "$(fw_backend)" == "none" ]]; then
        log_dim "  Firewall не установлен — sshd на 22 уже не слушает, этого достаточно"
        return 0
    fi

    if fw_port_allowed 22 tcp; then
        if confirm "  Удалить разрешающее правило для порта 22?" "y"; then
            fw_remove_port 22 tcp
            log_ok "  Порт 22 закрыт в firewall"
        fi
    else
        log_dim "  Правило для 22/tcp не найдено"
    fi
    log_dim "  Если у хостера есть cloud firewall — закройте 22 и там"
}
