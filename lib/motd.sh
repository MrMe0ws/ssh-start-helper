#!/bin/bash
# MOTD integration via distillium/motd.

readonly MOTD_INSTALL_URL="https://raw.githubusercontent.com/distillium/motd/main/install-motd.sh"

step_motd() {
    print_step "MOTD (distillium/motd)"

    if command -v motd-set >/dev/null 2>&1; then
        log_ok "  MOTD уже установлен (motd-set найден)"
        confirm "  Переустановить?" "n" || return 0
    fi

    if ! confirm "  Установить кастомный MOTD?" "n"; then
        log_dim "  Пропущено"
        return 0
    fi

    log_warn "  Установщик motd может изменить /etc/ssh (создаёт бэкап)."
    log_info "  Рекомендуется выполнять этот этап после SSH и UFW."

    if [[ "${DRY_RUN}" == true ]]; then
        log_dim "  [dry-run] curl ${MOTD_INSTALL_URL} | bash"
        return 0
    fi

    log_info "  Загрузка и запуск install-motd.sh..."
    if curl -fsSL "${MOTD_INSTALL_URL}" | bash; then
        log_ok "  MOTD установлен"
        echo ""
        log_dim "  Команды: motd — показать, motd-set — настройки"
        save_state "MOTD_INSTALLED" "true"
    else
        log_err "  Ошибка установки MOTD"
        return 1
    fi
}
