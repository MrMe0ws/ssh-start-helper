#!/bin/bash
# Firewall: UFW (Debian/Ubuntu) or firewalld (RHEL family). Audit existing rules, safe setup.

UFW_RULES=()
UFW_RULES_COUNT=0

# ufw локализован — без LC_ALL=C на русской локали будет "Состояние: активен"
_ufw() {
    LC_ALL=C ufw "$@"
}

ufw_is_active() {
    command -v ufw >/dev/null 2>&1 && _ufw status 2>/dev/null | head -1 | grep -qE '^Status: active'
}

firewalld_is_active() {
    command -v firewall-cmd >/dev/null 2>&1 && [[ "$(firewall-cmd --state 2>/dev/null)" == "running" ]]
}

# Какой firewall управляет хостом: ufw | firewalld | none
fw_backend() {
    if firewalld_is_active; then
        echo "firewalld"
    elif command -v ufw >/dev/null 2>&1; then
        echo "ufw"
    else
        echo "none"
    fi
}

ufw_port_allowed() {
    local port="$1" proto="${2:-tcp}"
    if ufw_is_active; then
        _ufw status 2>/dev/null | awk -v p="${port}" -v pr="${proto}" '
            /ALLOW/ && ($1 == p || $1 == p"/"pr) { found=1 }
            /ALLOW/ && p == "22" && $1 == "OpenSSH" { found=1 }
            END { exit !found }'
    else
        # неактивный ufw не показывает правила в status — смотрим добавленные
        _ufw show added 2>/dev/null | awk -v p="${port}" -v pr="${proto}" '
            $1 == "ufw" && $2 == "allow" && ($3 == p || $3 == p"/"pr) { found=1 }
            $1 == "ufw" && $2 == "allow" && p == "22" && $3 == "OpenSSH" { found=1 }
            END { exit !found }'
    fi
}

fw_port_allowed() {
    local port="$1" proto="${2:-tcp}"
    case "$(fw_backend)" in
        ufw) ufw_port_allowed "${port}" "${proto}" ;;
        firewalld)
            firewall-cmd --query-port="${port}/${proto}" >/dev/null 2>&1 && return 0
            [[ "${port}" == "22" ]] && firewall-cmd --query-service=ssh >/dev/null 2>&1
            ;;
        *) return 1 ;;
    esac
}

# Открыть порт (ufw добавляет правило даже если неактивен — пригодится при включении)
fw_allow_port() {
    local port="$1" proto="${2:-tcp}" comment="${3:-ssh-start-helper}"
    case "$(fw_backend)" in
        ufw)
            if ufw_port_allowed "${port}" "${proto}"; then
                return 0
            fi
            run_cmd _ufw allow "${port}/${proto}" comment "${comment}" >/dev/null \
                || run_cmd _ufw allow "${port}/${proto}" >/dev/null
            ;;
        firewalld)
            run_cmd firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null \
                && run_cmd firewall-cmd --reload >/dev/null
            ;;
        *) return 0 ;;
    esac
}

fw_remove_port() {
    local port="$1" proto="${2:-tcp}"
    case "$(fw_backend)" in
        ufw)
            run_cmd _ufw --force delete allow "${port}/${proto}" >/dev/null 2>&1 || true
            run_cmd _ufw --force delete allow "${port}" >/dev/null 2>&1 || true
            if [[ "${port}" == "22" ]]; then
                run_cmd _ufw --force delete allow OpenSSH >/dev/null 2>&1 || true
            fi
            ;;
        firewalld)
            run_cmd firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1 || true
            if [[ "${port}" == "22" ]]; then
                run_cmd firewall-cmd --permanent --remove-service=ssh >/dev/null 2>&1 || true
            fi
            run_cmd firewall-cmd --reload >/dev/null 2>&1 || true
            ;;
    esac
}

# Все внешние сокеты (не localhost), кроме sshd. Строки: "port proto process"
_public_sockets() {
    ss -tulnp 2>/dev/null | tail -n +2 | awk '
        {
            proto = $1; la = $5; proc = $0
            sub(/.*users:\(\("/, "", proc); sub(/".*/, "", proc)
            if (proc == $0) proc = "?"
            n = split(la, a, ":"); port = a[n]
            addr = substr(la, 1, length(la) - length(port) - 1)
            if (addr ~ /^127\./ || addr == "[::1]" || addr ~ /%lo$/) next
            if (proc ~ /^sshd/) next
            if (port !~ /^[0-9]+$/) next
            print port, proto, proc
        }' | sort -u | sort -k1,1n -k2,2
}

# UDP-сокеты на эфемерных портах — это исходящие соединения (xray, DNS-клиенты),
# а не сервисы: открывать их не нужно, и порты меняются при каждом запуске.
_is_ephemeral_udp() {
    local port="$1" proto="$2" lo hi
    [[ "${proto}" == "udp" ]] || return 1
    read -r lo hi < /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null || { lo=32768; hi=60999; }
    (( port >= lo && port <= hi ))
}

# Порты, которые реально слушают сервисы снаружи. Формат строк: "port/proto process"
list_public_listening_ports() {
    local port proto proc
    while read -r port proto proc; do
        [[ -n "${port}" ]] || continue
        _is_ephemeral_udp "${port}" "${proto}" && continue
        echo "${port}/${proto} ${proc}"
    done < <(_public_sockets)
}

_count_ephemeral_udp() {
    local port proto proc n=0
    while read -r port proto proc; do
        [[ -n "${port}" ]] || continue
        _is_ephemeral_udp "${port}" "${proto}" && ((n++)) || true
    done < <(_public_sockets)
    echo "${n}"
}

_parse_ufw_rules() {
    UFW_RULES=()
    UFW_RULES_COUNT=0

    if ! ufw_is_active; then
        return 0
    fi

    local line
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        UFW_RULES+=("${line}")
        ((UFW_RULES_COUNT++)) || true
    done < <(_ufw status numbered 2>/dev/null | grep -E '^\[')
}

_show_ufw_rules_table() {
    if (( UFW_RULES_COUNT == 0 )); then
        log_dim "  Нет пронумерованных правил"
        return
    fi

    print_summary_box "Текущие правила UFW (active)" \
        "$(printf '%s\n' "${UFW_RULES[@]}" | head -30 | sed 's/^/  /')"
}

fw_ensure_ssh_ports() {
    local port
    for port in "$@"; do
        if fw_port_allowed "${port}" tcp; then
            log_ok "  Порт ${port}/tcp уже открыт"
        else
            fw_allow_port "${port}" tcp "ssh-start-helper" \
                && log_ok "  Порт ${port}/tcp открыт" \
                || log_err "  Не удалось открыть ${port}/tcp"
        fi
    done
}

_ufw_audit_existing() {
    local -a ssh_ports=("$@")
    local mode

    _parse_ufw_rules
    _show_ufw_rules_table

    echo ""
    log_info "  Обнаружено правил: ${UFW_RULES_COUNT}"

    mode=$(choose "UFW — существующие правила" \
        "UFW уже активен. Что делать с существующими правилами?" "ssh_only" \
        "ssh_only" "Только добавить SSH-порт, остальное не трогать (рекомендуется)" \
        "review" "Просмотреть и подтвердить каждое правило" \
        "keep" "Не менять правила, только показать сводку")

    case "${mode}" in
        keep)
            log_ok "  Правила UFW не изменены"
            ;;
        review)
            _ufw_review_each_rule "${ssh_ports[@]}"
            ;;
        *)
            fw_ensure_ssh_ports "${ssh_ports[@]}"
            ;;
    esac
}

_ufw_review_each_rule() {
    local -a ssh_ports=("$@")
    local to_delete=()

    local rule
    for rule in "${UFW_RULES[@]}"; do
        local num port
        num=$(echo "${rule}" | sed -n 's/^\[ *\([0-9]*\)\].*/\1/p')
        port=$(echo "${rule}" | sed 's/^\[ *[0-9]*\] *//' | awk '{print $1}' | cut -d/ -f1)

        echo "${rule}" | grep -q "ALLOW" || continue
        [[ " ${ssh_ports[*]} " == *" ${port} "* ]] && continue

        echo ""
        log_value "  Правило [${num}]: " "${rule}"
        if ! confirm "    Оставить это правило?" "y"; then
            to_delete+=("${num}")
        fi
    done

    if ((${#to_delete[@]} > 0)); then
        log_warn "  Будут удалены правила: ${to_delete[*]}"
        if confirm "  Подтвердить удаление?" "n"; then
            local n
            # Удаляем с конца, чтобы не сбивалась нумерация
            for n in $(printf '%s\n' "${to_delete[@]}" | sort -rn); do
                run_cmd _ufw --force delete "${n}" >/dev/null
                log_ok "  Удалено правило [${n}]"
            done
        fi
    fi

    fw_ensure_ssh_ports "${ssh_ports[@]}"
}

_is_valid_ip_or_cidr() {
    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ || "$1" =~ ^[0-9a-fA-F:]+(/[0-9]{1,3})?$ ]]
}

# Открыть один порт сервиса. API ноды Remnawave (rw-node) нужен только панели —
# предлагаем открыть его для IP панели, а не для всего интернета.
_ufw_allow_service() {
    local port_proto="$1" proc="$2"
    local port="${port_proto%/*}" proto="${port_proto#*/}"

    if [[ "${proc}" == "rw-node" ]]; then
        local panel_ip
        while true; do
            panel_ip=$(prompt_input "    ${port_proto} — API ноды Remnawave. IP панели (пусто — открыть для всех)" "")
            if [[ -z "${panel_ip}" ]] || _is_valid_ip_or_cidr "${panel_ip}"; then
                break
            fi
            log_err "    Это не IP-адрес: ${panel_ip}"
        done
        if [[ -n "${panel_ip}" ]]; then
            run_cmd _ufw allow from "${panel_ip}" to any port "${port}" proto "${proto}" comment "remnanode api" >/dev/null \
                || run_cmd _ufw allow from "${panel_ip}" to any port "${port}" proto "${proto}" >/dev/null
            log_ok "  allow ${port_proto} только с ${panel_ip} (${proc})"
            return 0
        fi
    fi

    run_cmd _ufw allow "${port_proto}" comment "auto: ${proc}" >/dev/null \
        || run_cmd _ufw allow "${port_proto}" >/dev/null
    log_ok "  allow ${port_proto} (${proc})"
}

_ufw_allow_running_services() {
    local services skipped
    services=$(list_public_listening_ports)
    skipped=$(_count_ephemeral_udp)
    [[ -n "${services}" ]] || return 0

    echo ""
    log_info "  Сервисы, которые сейчас принимают подключения снаружи:"
    echo "${services}" | sed 's/^/      /'
    if (( skipped > 0 )); then
        log_dim "  (ещё ${skipped} UDP-сокетов на эфемерных портах — это исходящие соединения, их открывать не нужно)"
    fi
    log_dim "  (если их не открыть, после включения UFW они станут недоступны)"

    local port_proto proc
    if confirm "  Открыть все эти порты в UFW?" "y"; then
        while read -r port_proto proc; do
            _ufw_allow_service "${port_proto}" "${proc}"
        done <<< "${services}"
    else
        while read -r port_proto proc; do
            if confirm "    Открыть ${port_proto} (${proc})?" "y"; then
                _ufw_allow_service "${port_proto}" "${proc}"
            fi
        done <<< "${services}"
    fi
}

_ufw_fresh_setup() {
    local -a ssh_ports=("$@")

    log_info "  UFW не активен — первичная настройка"

    run_cmd _ufw default deny incoming >/dev/null
    run_cmd _ufw default allow outgoing >/dev/null

    local p
    for p in "${ssh_ports[@]}"; do
        run_cmd _ufw allow "${p}/tcp" comment 'ssh-start-helper' >/dev/null
        log_ok "  allow ${p}/tcp (SSH)"
    done

    _ufw_allow_running_services

    if ! ufw_port_allowed 443 tcp; then
        if confirm "  Открыть порты 80 и 443 (HTTP/HTTPS)?" "n"; then
            run_cmd _ufw allow 80/tcp comment 'http' >/dev/null
            run_cmd _ufw allow 443/tcp comment 'https' >/dev/null
            log_ok "  allow 80/tcp, 443/tcp"
        fi
    fi

    if command -v docker >/dev/null 2>&1; then
        log_dim "  Примечание: порты, опубликованные Docker (-p), обходят UFW — Docker пишет свои правила iptables."
    fi

    if confirm "  Включить UFW?" "y"; then
        if run_cmd _ufw --force enable >/dev/null; then
            log_ok "  UFW включён"
            save_state "UFW_ENABLED" "true"
        else
            log_err "  Не удалось включить UFW (в контейнере/OpenVZ это нормально)"
            return 1
        fi
    fi
}

_firewalld_setup() {
    local -a ssh_ports=("$@")
    log_ok "  firewalld активен (зона: $(firewall-cmd --get-default-zone 2>/dev/null))"
    fw_ensure_ssh_ports "${ssh_ports[@]}"
    log_info "  Открытые порты/сервисы:"
    {
        firewall-cmd --list-services 2>/dev/null
        firewall-cmd --list-ports 2>/dev/null
    } | sed 's/^/    /'
}

step_firewall_configure() {
    print_step "Firewall"

    local -a ssh_ports
    read -r -a ssh_ports <<< "$(get_ssh_ports)"
    log_info "  SSH-порт(ы) для правил: ${C_YELLOW}${ssh_ports[*]}${C_RESET}"

    if firewalld_is_active; then
        _firewalld_setup "${ssh_ports[@]}"
        save_state "FIREWALL_CONFIGURED" "firewalld"
        return 0
    fi

    if ! is_debian_like; then
        if command -v firewall-cmd >/dev/null 2>&1; then
            if confirm "  firewalld установлен, но не запущен. Включить?" "y"; then
                run_cmd systemctl enable --now firewalld || { log_err "  Не удалось запустить firewalld"; return 1; }
                _firewalld_setup "${ssh_ports[@]}"
            fi
        else
            log_warn "  Нет firewalld — пропуск. Установите: dnf install firewalld"
        fi
        return 0
    fi

    if ! command -v ufw >/dev/null 2>&1; then
        log_info "  Установка ufw..."
        pkg_install ufw || { log_err "  Не удалось установить ufw"; return 1; }
    fi

    if ufw_is_active; then
        log_ok "  UFW уже активен"
        _ufw_audit_existing "${ssh_ports[@]}"
    else
        _ufw_fresh_setup "${ssh_ports[@]}" || return 1
    fi

    echo ""
    log_info "  Текущий статус UFW:"
    _ufw status verbose 2>/dev/null | head -30 | sed 's/^/    /' || true

    save_state "FIREWALL_CONFIGURED" "ufw"
    log_ok "  Этап firewall завершён"
}

# Совместимость со старым именем
step_ufw_configure() {
    step_firewall_configure "$@"
}
