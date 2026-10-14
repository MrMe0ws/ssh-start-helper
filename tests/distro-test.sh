#!/bin/bash
# Проверка модулей на разных дистрибутивах в одноразовом контейнере (меняет систему!):
#   for img in debian:12 debian:11 ubuntu:22.04 ubuntu:24.04 rockylinux:9; do
#       docker run --rm -v "$PWD":/src:ro "$img" bash /src/tests/distro-test.sh
#   done
# shellcheck disable=SC1090,SC2034

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
ok()  { echo "[PASS] $*"; ((PASS++)) || true; }
bad() { echo "[FAIL] $*"; ((FAIL++)) || true; }

if [[ ! -f /.dockerenv && "${FORCE_DISTRO_TEST:-}" != "1" ]]; then
    echo "Запускайте только в одноразовом контейнере (или FORCE_DISTRO_TEST=1)" >&2
    exit 1
fi

DRY_RUN=false
TEXT_MODE=true
for f in "${ROOT}"/lib/*.sh; do source "${f}"; done
export DEBIAN_FRONTEND=noninteractive

detect_os
echo "=== ${OS_NAME} (pkg: ${PKG_MGR}) ==="
[[ -n "${PKG_MGR}" ]] && ok "package manager: ${PKG_MGR}" || bad "package manager not detected"

has_internet && ok "has_internet (без ping)" || bad "has_internet"
has_dns && ok "has_dns" || bad "has_dns"

# Без терминала меню возвращает значение по умолчанию
[[ "$(choose "T" "P" "b" a "A" b "B" < /dev/null)" == "b" ]] && ok "choose() default without tty" || bad "choose() default"

if is_debian_like; then
    pkg_install openssh-server iproute2 >/dev/null && ok "pkg_install openssh-server" || bad "pkg_install openssh-server"
else
    pkg_install openssh-server iproute procps-ng >/dev/null && ok "pkg_install openssh-server" || bad "pkg_install openssh-server"
fi
ssh-keygen -A >/dev/null 2>&1

# ── SSH: приоритет drop-in, нейтрализация чужих Port ──
mkdir -p /etc/ssh/sshd_config.d
echo "Port 22" >> /etc/ssh/sshd_config
printf 'PasswordAuthentication no\nPort 2200\n' > /etc/ssh/sshd_config.d/50-cloud-init.conf
SSH_MIGRATE_PORT=true
SSH_NEW_PORT=2228

_write_ssh_settings 2228 true yes yes >/dev/null
_neutralize_foreign_ports >/dev/null
_validate_sshd_config >/dev/null 2>&1 && ok "sshd -t (drop-in, OpenSSH $(openssh_version_num))" || bad "sshd -t (drop-in)"
[[ "$(get_ssh_ports)" == "2228" ]] && ok "effective port = 2228" || bad "effective ports: $(get_ssh_ports)"
[[ "$(sshd_effective_value passwordauthentication)" == "yes" ]] \
    && ok "drop-in 00- wins over 50-cloud-init" || bad "PasswordAuthentication=$(sshd_effective_value passwordauthentication)"
[[ "$(sshd_effective_value permitrootlogin)" == "yes" ]] && ok "PermitRootLogin=yes" || bad "PermitRootLogin"

# Include не в начале файла → переносится наверх
cfg=/etc/ssh/sshd_config
sed -i -E '/^[[:space:]]*Include[[:space:]]+\/etc\/ssh\/sshd_config\.d/d' "${cfg}"
sed -i '1i PermitRootLogin no' "${cfg}"
echo 'Include /etc/ssh/sshd_config.d/*.conf' >> "${cfg}"
_write_ssh_settings 2228 true yes yes >/dev/null
[[ "$(sshd_effective_value permitrootlogin)" == "yes" ]] \
    && ok "Include moved to top, drop-in wins" || bad "Include order: PermitRootLogin=$(sshd_effective_value permitrootlogin)"
sed -i '/^PermitRootLogin no$/d' "${cfg}"

# Старый OpenSSH (< 8.2): блок в начале sshd_config
rm -f "${SSH_HELPER_SSH_DROPIN}"
_use_dropin() { return 1; }
_write_ssh_settings 2229 true prohibit-password yes >/dev/null
_write_ssh_settings 2229 true prohibit-password yes >/dev/null
[[ "$(grep -c "^${SSH_BLOCK_BEGIN}\$" "${cfg}")" == "1" ]] && ok "managed block written once" || bad "managed block duplicated"
[[ "$(get_ssh_ports)" == "2229" ]] && ok "block mode: port 2229" || bad "block mode ports: $(get_ssh_ports)"
pr=$(sshd_effective_value permitrootlogin)
[[ "${pr}" == "prohibit-password" || "${pr}" == "without-password" ]] && ok "block mode: PermitRootLogin" || bad "block mode PermitRootLogin=${pr}"
unset -f _use_dropin
source "${ROOT}/lib/ssh.sh" 2>/dev/null

# ── fail2ban ──
ensure_epel >/dev/null 2>&1
if pkg_install fail2ban >/dev/null; then
    ok "pkg_install fail2ban"
    if fail2ban_apply_config >/dev/null 2>&1; then
        ok "fail2ban config valid (fail2ban-client -t), backend $(_f2b_backend)"
    else
        bad "fail2ban config: $(fail2ban-client -t 2>&1 | tail -2)"
    fi
    grep -q "^port     = 2229" "${SSH_HELPER_F2B_JAIL}" && ok "fail2ban jail uses sshd port" || bad "fail2ban jail port"
else
    bad "pkg_install fail2ban"
fi

# ── прочее ──
list_public_listening_ports >/dev/null 2>&1 && ok "list_public_listening_ports" || bad "list_public_listening_ports"
[[ -n "$(ssh_service_name)" ]] && ok "ssh_service_name: $(ssh_service_name)" || bad "ssh_service_name"

echo "=== ${OS_NAME}: ${PASS} passed, ${FAIL} failed ==="
[[ "${FAIL}" -eq 0 ]]
