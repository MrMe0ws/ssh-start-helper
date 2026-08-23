#!/bin/bash
# Security: fail2ban, unattended-upgrades.

step_fail2ban() {
    print_step "fail2ban"

    if command -v fail2ban-client >/dev/null 2>&1; then
        log_ok "  fail2ban уже установлен"
        return 0
    fi

    if ! confirm "  Установить fail2ban для защиты SSH?" "y"; then
        log_dim "  Пропущено"
        return 0
    fi

    run_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban

    local ssh_port
    ssh_port=$(load_state "SSH_PORT" "$(get_ssh_port)")

    local jail="/etc/fail2ban/jail.local"
    if [[ ! -f "${jail}" ]]; then
        cat > "${jail}" << EOF
[sshd]
enabled = true
port = ${ssh_port}
maxretry = 5
bantime = 3600
findtime = 600
EOF
        log_ok "  jail.local создан (port ${ssh_port})"
    fi

    run_cmd systemctl enable fail2ban
    run_cmd systemctl restart fail2ban
    log_ok "  fail2ban запущен"
    save_state "FAIL2BAN" "true"
}

step_unattended_upgrades() {
    print_step "unattended-upgrades"

    if ! confirm "  Настроить автоматические security-обновления?" "y"; then
        log_dim "  Пропущено"
        return 0
    fi

    run_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades apt-listchanges

    if [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]]; then
        log_ok "  auto-upgrades уже настроен"
    else
        cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
        log_ok "  20auto-upgrades создан"
    fi

    run_cmd dpkg-reconfigure -f noninteractive unattended-upgrades 2>/dev/null || true
    log_ok "  unattended-upgrades настроен"
    save_state "UNATTENDED_UPGRADES" "true"
}
