#!/bin/bash
# Optional swap file.

step_swap() {
    print_step "Swap"

    if swapon --show 2>/dev/null | grep -q .; then
        log_ok "  Swap уже настроен:"
        swapon --show | sed 's/^/    /'
        return 0
    fi

    if in_container; then
        log_warn "  Контейнерная виртуализация ($(systemd-detect-virt -c 2>/dev/null)) — swap внутри нельзя создать"
        return 0
    fi

    local mem_mb
    mem_mb=$(free -m | awk '/^Mem:/ {print $2}')

    log_info "  RAM: ${mem_mb} MB"

    if (( mem_mb > 2048 )); then
        log_dim "  RAM > 2 GB — swap обычно не нужен"
        confirm "  Всё равно создать swap?" "n" || return 0
    fi

    if ! confirm "  Создать swapfile 1 GB?" "y"; then
        log_dim "  Пропущено"
        return 0
    fi

    local swapfile="/swapfile"

    if [[ -f "${swapfile}" ]]; then
        log_ok "  ${swapfile} уже существует — включаю"
        run_cmd swapon "${swapfile}" || true
        return 0
    fi

    local avail_mb
    avail_mb=$(df -Pm / | awk 'NR==2 {print $4}')
    if (( avail_mb < 1536 )); then
        log_err "  Мало места на диске (${avail_mb} MB свободно)"
        return 1
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        log_dim "  [dry-run] create ${swapfile} 1G"
        return 0
    fi

    # fallocate не подходит для swap на некоторых ФС (xfs старых ядер, btrfs) — тогда dd
    if ! { fallocate -l 1G "${swapfile}" 2>/dev/null && chmod 600 "${swapfile}" \
            && mkswap "${swapfile}" >/dev/null 2>&1 && swapon "${swapfile}" 2>/dev/null; }; then
        rm -f "${swapfile}"
        dd if=/dev/zero of="${swapfile}" bs=1M count=1024 status=none \
            && chmod 600 "${swapfile}" && mkswap "${swapfile}" >/dev/null \
            && swapon "${swapfile}" || { rm -f "${swapfile}"; log_err "  Не удалось создать swap"; return 1; }
    fi

    if ! grep -q "^${swapfile}[[:space:]]" /etc/fstab; then
        echo "${swapfile} none swap sw 0 0" >> /etc/fstab
    fi

    log_ok "  Swap 1 GB активирован"
    save_state "SWAP" "true"
}
