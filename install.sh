#!/bin/bash
#
# Installer: curl -fsSL .../install.sh | bash
# Installs files to /opt/ssh-start-helper and creates `ssh-start-helper` command.
#

set -euo pipefail

readonly INSTALL_DIR="/opt/ssh-start-helper"
readonly BIN_LINK="/usr/local/bin/ssh-start-helper"
readonly REPO_RAW="${SSH_HELPER_REPO:-https://raw.githubusercontent.com/MrMe0ws/ssh-start-helper/main}"

_log() { echo "[+] $*" >&2; }
_err() { echo "[✗] $*" >&2; exit 1; }

require_root() {
    [[ "${EUID}" -eq 0 ]] || _err "Запустите от root: curl ... | bash"
}

_install_from_local() {
    local src_dir="$1"
    _log "Установка из локальной копии..."
    mkdir -p "${INSTALL_DIR}/lib"
    cp -a "${src_dir}/run.sh" "${INSTALL_DIR}/"
    cp -a "${src_dir}/lib/." "${INSTALL_DIR}/lib/"
    chmod +x "${INSTALL_DIR}/run.sh"
    chmod -R a+rX "${INSTALL_DIR}/lib"
}

_install_from_remote() {
    _log "Загрузка из ${REPO_RAW}..."
    mkdir -p "${INSTALL_DIR}/lib"

    curl -fsSL "${REPO_RAW}/run.sh" -o "${INSTALL_DIR}/run.sh" || _err "Не удалось загрузить run.sh"

    local files=(
        common.sh preflight.sh system.sh user.sh
        ssh.sh firewall.sh security.sh swap.sh motd.sh
    )
    local f
    for f in "${files[@]}"; do
        curl -fsSL "${REPO_RAW}/lib/${f}" -o "${INSTALL_DIR}/lib/${f}" || _err "Не удалось загрузить lib/${f}"
    done

    chmod +x "${INSTALL_DIR}/run.sh"
    chmod -R a+rX "${INSTALL_DIR}/lib"
}

_create_command() {
    cat > "${BIN_LINK}" << 'EOF'
#!/bin/bash
exec /opt/ssh-start-helper/run.sh "$@"
EOF
    chmod +x "${BIN_LINK}"
}

_print_done() {
    echo ""
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║  ssh-start-helper установлен                 ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo ""
    echo "  Повторный запуск: ssh-start-helper"
    echo ""
}

main() {
    require_root

    local src_dir=""
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi

    if [[ -n "${src_dir}" && -f "${src_dir}/run.sh" ]]; then
        _install_from_local "${src_dir}"
    else
        _install_from_remote
    fi

    _create_command
    echo "1.0.0" > "${INSTALL_DIR}/VERSION"

    _print_done

    # Только установка без запуска: SSH_HELPER_NO_RUN=1 curl ... | bash
    if [[ "${SSH_HELPER_NO_RUN:-}" == "1" ]]; then
        exit 0
    fi

    # curl | bash и локальный install.sh — сразу запускаем wizard
    exec "${BIN_LINK}" "$@"
}

main "$@"
