#!/bin/bash
# Security: fail2ban, automatic security updates.

# Где sshd пишет логи: файл (auth.log/secure) или только journald
_f2b_backend() {
    if [[ -s /var/log/auth.log || -s /var/log/secure ]]; then
        echo "auto"
    else
        echo "systemd"
    fi
}

# Чем банить: firewalld / iptables / nftables
_f2b_banaction() {
    if firewalld_is_active; then
        echo "firewallcmd-rich-rules"
    elif command -v iptables >/dev/null 2>&1; then
        echo "iptables-multiport"
    elif command -v nft >/dev/null 2>&1; then
        echo "nftables-multiport"
    else
        echo ""
    fi
}

_f2b_version_num() {
    local v
    v=$(fail2ban-client --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
    [[ -n "${v}" ]] || { echo 0; return; }
    echo $(( ${v%%.*} * 100 + ${v#*.} ))
}

_f2b_ensure_journal_support() {
    python3 -c 'import systemd.journal' >/dev/null 2>&1 && return 0
    log_info "  Установка python3-systemd для чтения journald..."
    pkg_install python3-systemd >/dev/null 2>&1 \
        || pkg_install fail2ban-systemd >/dev/null 2>&1 \
        || log_warn "  python3-systemd не установлен — fail2ban может не видеть логи sshd"
}

# Пишет jail для sshd с актуальными портами. Можно вызывать повторно (после смены порта).
fail2ban_apply_config() {
    local ports backend banaction ignoreip
    ports=$(get_ssh_ports | tr ' ' ',')
    backend=$(_f2b_backend)
    banaction=$(_f2b_banaction)
    ignoreip="127.0.0.1/8 ::1"
    local wl
    wl=$(load_state "F2B_WHITELIST" "")
    [[ -n "${wl}" ]] && ignoreip="${ignoreip} ${wl}"

    [[ "${backend}" == "systemd" ]] && _f2b_ensure_journal_support

    [[ "${DRY_RUN}" == true ]] || mkdir -p /etc/fail2ban/jail.d
    {
        echo "# Managed by ssh-start-helper — перезаписывается при запуске"
        echo "[sshd]"
        echo "enabled  = true"
        echo "port     = ${ports}"
        echo "maxretry = 5"
        echo "findtime = 10m"
        echo "bantime  = 1h"
        if (( $(_f2b_version_num) >= 11 )); then
            # повторные нарушители получают всё более долгий бан (до недели)
            echo "bantime.increment = true"
            echo "bantime.maxtime   = 1w"
        fi
        echo "ignoreip = ${ignoreip}"
        if [[ "${backend}" == "systemd" ]]; then
            echo "backend  = systemd"
            # ssh.service (Debian/Ubuntu) и sshd.service (RHEL); OpenSSH 9.8+ пишет как sshd-session
            echo "journalmatch = _SYSTEMD_UNIT=ssh.service + _SYSTEMD_UNIT=sshd.service + _COMM=sshd + _COMM=sshd-session"
        fi
        [[ -n "${banaction}" ]] && echo "banaction = ${banaction}"
    } | write_file "${SSH_HELPER_F2B_JAIL}"

    if [[ "${DRY_RUN}" == true ]]; then
        return 0
    fi

    local err
    if ! err=$(fail2ban-client -t 2>&1); then
        log_err "  fail2ban: ошибка в конфигурации"
        echo "${err}" | tail -5 | sed 's/^/    /' >&2
        return 1
    fi
    log_ok "  fail2ban jail: порт ${ports}, backend ${backend}${banaction:+, ${banaction}}"
}

fail2ban_reload() {
    [[ "${DRY_RUN}" == true ]] && return 0
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban || return 1

    for _ in $(seq 1 15); do
        fail2ban-client status sshd >/dev/null 2>&1 && return 0
        sleep 1
    done
    log_err "  fail2ban не поднял jail sshd: journalctl -u fail2ban -n 30"
    return 1
}

step_fail2ban() {
    print_step "fail2ban"

    if command -v fail2ban-client >/dev/null 2>&1; then
        log_ok "  fail2ban уже установлен — обновляю конфигурацию"
    else
        if ! confirm "  Установить fail2ban для защиты SSH?" "y"; then
            log_dim "  Пропущено"
            return 0
        fi
        ensure_epel
        if ! pkg_install fail2ban; then
            log_err "  Не удалось установить fail2ban"
            return 1
        fi
    fi

    if [[ -z "$(_f2b_banaction)" ]]; then
        log_info "  Нет iptables/nftables — устанавливаю nftables..."
        pkg_install nftables >/dev/null 2>&1 || log_warn "  Не удалось установить nftables — баны могут не работать"
    fi

    local client_ip
    client_ip=$(get_client_ip)
    if [[ -n "${client_ip}" && -z "$(load_state "F2B_WHITELIST" "")" ]]; then
        log_dim "  Ваш текущий IP: ${client_ip}"
        if confirm "  Добавить его в whitelist (никогда не банить)? Только если IP статический" "n"; then
            save_state "F2B_WHITELIST" "${client_ip}"
        fi
    fi

    fail2ban_apply_config || return 1
    if fail2ban_reload; then
        log_ok "  fail2ban запущен"
        if [[ "${DRY_RUN}" != true ]]; then
            fail2ban-client status sshd 2>/dev/null | grep -E 'Currently banned|Total banned' | sed 's/^[ |`-]*/    /'
        fi
    else
        return 1
    fi
    save_state "FAIL2BAN" "true"
}

_unattended_apt() {
    pkg_install unattended-upgrades apt-listchanges || return 1

    if [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]] \
        && grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades; then
        log_ok "  auto-upgrades уже настроен"
    else
        write_file /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
        log_ok "  20auto-upgrades создан"
    fi
    run_cmd systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
}

_unattended_dnf() {
    pkg_install dnf-automatic || return 1
    local conf=/etc/dnf/automatic.conf
    if [[ -f "${conf}" && "${DRY_RUN}" != true ]]; then
        sed -i -E 's/^upgrade_type[[:space:]]*=.*/upgrade_type = security/; s/^apply_updates[[:space:]]*=.*/apply_updates = yes/' "${conf}"
    fi
    run_cmd systemctl enable --now dnf-automatic.timer >/dev/null 2>&1 \
        || run_cmd systemctl enable --now dnf-automatic-install.timer >/dev/null 2>&1
    log_ok "  dnf-automatic: security-обновления включены"
}

step_unattended_upgrades() {
    print_step "Автоматические security-обновления"

    if ! confirm "  Настроить автоматические security-обновления?" "y"; then
        log_dim "  Пропущено"
        return 0
    fi

    case "${PKG_MGR}" in
        apt) _unattended_apt || { log_err "  Не удалось настроить unattended-upgrades"; return 1; } ;;
        dnf) _unattended_dnf || { log_err "  Не удалось настроить dnf-automatic"; return 1; } ;;
        *) log_warn "  Для ${PKG_MGR} автообновления не поддерживаются — пропуск"; return 0 ;;
    esac

    log_ok "  Автообновления настроены"
    save_state "UNATTENDED_UPGRADES" "true"
}
