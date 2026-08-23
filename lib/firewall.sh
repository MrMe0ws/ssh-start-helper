#!/bin/bash
# UFW firewall: audit existing rules, safe setup.

UFW_RULES=()
UFW_RULES_COUNT=0

ufw_is_active() {
    command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -1 | grep -qi "active"
}

ufw_port_allowed() {
    local port="$1"
    ufw status 2>/dev/null | grep -qE "${port}/tcp.*ALLOW|${port}.*ALLOW"
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
        [[ "${line}" =~ ^Status: ]] && continue
        [[ "${line}" =~ ^To[[:space:]] ]] && continue
        [[ "${line}" =~ ^-- ]] && continue
        UFW_RULES+=("${line}")
        ((UFW_RULES_COUNT++)) || true
    done < <(ufw status numbered 2>/dev/null | grep -E '^\[')
}

_show_ufw_rules_table() {
    if (( UFW_RULES_COUNT == 0 )); then
        log_dim "  Нет пронумерованных правил"
        return
    fi

    print_summary_box "Текущие правила UFW (active)" \
        "$(printf '%s\n' "${UFW_RULES[@]}" | head -20 | sed 's/^/  /')"
}

ufw_ensure_ssh_port() {
    local ssh_port="${1:-$(get_ssh_port)}"

    if ufw_port_allowed "${ssh_port}"; then
        log_ok "  Порт ${ssh_port}/tcp уже открыт в UFW"
        return 0
    fi

    log_info "  Добавляем allow ${ssh_port}/tcp..."
    run_cmd ufw allow "${ssh_port}/tcp" comment 'ssh-start-helper'
    log_ok "  Порт ${ssh_port}/tcp открыт"
}

_ufw_audit_existing() {
    local ssh_port="${1:-$(get_ssh_port)}"
    local mode

    _parse_ufw_rules
    _show_ufw_rules_table

    echo ""
    log_info "  Обнаружено правил: ${UFW_RULES_COUNT}"

    mode=$(whiptail --title "UFW — существующие правила" \
        --menu "UFW уже активен. Что делать с существующими правилами?" \
        16 72 3 \
        "ssh_only" "Только добавить SSH-порт, остальное не трогать (рекомендуется)" \
        "review" "Просмотреть и подтвердить каждое правило" \
        "keep" "Не менять правила, только показать сводку" \
        3>&1 1>&2 2>&3) || mode="ssh_only"
    restore_tty

    case "${mode}" in
        ssh_only)
            ufw_ensure_ssh_port "${ssh_port}"
            ;;
        keep)
            log_ok "  Правила UFW не изменены"
            ;;
        review)
            _ufw_review_each_rule "${ssh_port}"
            ;;
        *)
            ufw_ensure_ssh_port "${ssh_port}"
            ;;
    esac
}

_ufw_review_each_rule() {
    local ssh_port="$1"
    local to_delete=()

    local rule
    for rule in "${UFW_RULES[@]}"; do
        local num port action
        num=$(echo "${rule}" | sed -n 's/^\[\([0-9]*\)\].*/\1/p')
        port=$(echo "${rule}" | awk '{print $2}' | cut -d/ -f1)

        # Skip if not ALLOW or is SSH port
        echo "${rule}" | grep -q "ALLOW" || continue
        [[ "${port}" == "${ssh_port}" ]] && continue

        echo ""
        log_value "  Правило [${num}]: " "${rule}"
        if ! confirm "    Оставить это правило?" "y"; then
            to_delete+=("${num}")
        elif confirm "    Добавить комментарий к правилу?" "n"; then
            local comment
            comment=$(prompt_input "    Комментарий" "project")
            log_dim "    (комментарий ufw для существующих правил требует пересоздания — пропуск)"
        fi
    done

    if ((${#to_delete[@]} > 0)); then
        log_warn "  Будут удалены правила: ${to_delete[*]}"
        if confirm "  Подтвердить удаление?" "n"; then
            local n
            # Delete in reverse order to preserve numbering
            for n in $(printf '%s\n' "${to_delete[@]}" | sort -rn); do
                run_cmd ufw --force delete "${n}"
                log_ok "  Удалено правило [${n}]"
            done
        fi
    fi

    ufw_ensure_ssh_port "${ssh_port}"
}

_ufw_fresh_setup() {
    local ssh_port="${1:-$(get_ssh_port)}"

    log_info "  UFW не активен — первичная настройка"

    run_cmd ufw default deny incoming
    run_cmd ufw default allow outgoing

    run_cmd ufw allow "${ssh_port}/tcp" comment 'ssh-start-helper'
    log_ok "  allow ${ssh_port}/tcp"

    if [[ "${ssh_port}" != "22" ]]; then
        run_cmd ufw allow 22/tcp comment 'ssh-migration-temp'
        log_dim "  allow 22/tcp (временно, до подтверждения миграции)"
    fi

    if confirm "  Открыть порты 80 и 443 (HTTP/HTTPS)?" "n"; then
        run_cmd ufw allow 80/tcp comment 'http'
        run_cmd ufw allow 443/tcp comment 'https'
        log_ok "  allow 80/tcp, 443/tcp"
    fi

    if confirm "  Включить UFW?" "y"; then
        run_cmd ufw --force enable
        log_ok "  UFW включён"
        save_state "UFW_ENABLED" "true"
    fi
}

step_ufw_configure() {
    print_step "UFW firewall"

    if ! command -v ufw >/dev/null 2>&1; then
        log_info "  Установка ufw..."
        run_cmd apt-get install -y -qq ufw
    fi

    local ssh_port
    ssh_port=$(load_state "SSH_PORT" "")
    [[ -z "${ssh_port}" ]] && ssh_port=$(get_ssh_port)

    log_info "  SSH-порт для правил: ${C_YELLOW}${ssh_port}${C_RESET}"

    if ufw_is_active; then
        log_ok "  UFW уже активен"
        _ufw_audit_existing "${ssh_port}"
    else
        _ufw_fresh_setup "${ssh_port}"
    fi

    echo ""
    log_info "  Текущий статус UFW:"
    ufw status verbose 2>/dev/null | head -20 | sed 's/^/    /' || true

    save_state "UFW_CONFIGURED" "true"
    log_ok "  Этап UFW завершён"
}
