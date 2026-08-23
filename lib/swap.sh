#!/bin/bash
# Optional swap file.

step_swap() {
    print_step "Swap"

    if swapon --show 2>/dev/null | grep -q .; then
        log_ok "  Swap уже настроен:"
        swapon --show | sed 's/^/    /'
        return 0
    fi

    local mem_mb
    mem_mb=$(free -m | awk '/Mem:/ {print $2}')

    log_info "  RAM: ${mem_mb} MB"

    if (( mem_mb > 2048 )); then
        log_dim "  RAM > 2 GB — swap обычно не нужен"
        confirm "  Всё равно создать swap?" "n" || return 0
    fi

    if ! confirm "  Создать swapfile 1 GB?" "n"; then
        log_dim "  Пропущено"
        return 0
    fi

    local swapfile="/swapfile"
    local size_gb=1

    if [[ -f "${swapfile}" ]]; then
        log_ok "  ${swapfile} уже существует"
        return 0
    fi

    run_cmd fallocate -l "${size_gb}G" "${swapfile}" 2>/dev/null || run_cmd dd if=/dev/zero of="${swapfile}" bs=1M count=1024 status=progress
    run_cmd chmod 600 "${swapfile}"
    run_cmd mkswap "${swapfile}"
    run_cmd swapon "${swapfile}"

    if ! grep -q "${swapfile}" /etc/fstab; then
        echo "${swapfile} none swap sw 0 0" >> /etc/fstab
    fi

    log_ok "  Swap ${size_gb} GB активирован"
    save_state "SWAP" "true"
}
