#!/bin/bash
# Smoke tests — run on Ubuntu: bash tests/smoke-test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok()   { echo "[PASS] $*"; ((PASS++)) || true; }
bad()  { echo "[FAIL] $*"; ((FAIL++)) || true; }

echo "=== ssh-start-helper smoke tests ==="
echo "Root: ${ROOT}"
echo ""

# Syntax check all bash files
while IFS= read -r -d '' f; do
    if bash -n "${f}" 2>/dev/null; then
        ok "syntax: ${f#${ROOT}/}"
    else
        bad "syntax: ${f#${ROOT}/}"
    fi
done < <(find "${ROOT}" -name '*.sh' -print0)

# Required files
for f in install.sh run.sh lib/common.sh lib/firewall.sh lib/ssh.sh; do
    [[ -f "${ROOT}/${f}" ]] && ok "exists: ${f}" || bad "missing: ${f}"
done

# install.sh must reference MrMe0ws repo
if grep -q 'MrMe0ws/ssh-start-helper' "${ROOT}/install.sh"; then
    ok "install.sh repo URL"
else
    bad "install.sh repo URL"
fi

# Версии в install.sh и lib/common.sh должны совпадать
lib_ver=$(grep -m1 '^readonly SSH_HELPER_VERSION=' "${ROOT}/lib/common.sh" | cut -d'"' -f2)
inst_ver=$(grep -m1 '^readonly INSTALL_VERSION=' "${ROOT}/install.sh" | cut -d'"' -f2)
if [[ -n "${lib_ver}" && "${lib_ver}" == "${inst_ver}" ]]; then
    ok "version match: ${lib_ver}"
else
    bad "version mismatch: common.sh=${lib_ver} install.sh=${inst_ver}"
fi

# Все lib/*.sh должны быть в списке загрузки install.sh
for f in "${ROOT}"/lib/*.sh; do
    name=$(basename "${f}")
    if grep -q "${name}" "${ROOT}/install.sh"; then
        ok "install.sh downloads lib/${name}"
    else
        bad "install.sh missing lib/${name}"
    fi
done

# Не должно быть ping-зависимостей и голого whiptail без фолбэка
if grep -rnE '^[^#]*ping' "${ROOT}/lib" "${ROOT}/run.sh" | grep -v 'iputils' | grep -q .; then
    bad "ping used (нет на минимальных образах)"
else
    ok "no ping dependency"
fi
if grep -rn 'whiptail --' "${ROOT}/lib" | grep -v 'lib/common.sh' | grep -q .; then
    bad "whiptail called directly outside choose()"
else
    ok "whiptail only via choose()"
fi

# run.sh sources common.sh
if grep -q 'source.*common.sh' "${ROOT}/run.sh"; then
    ok "run.sh sources libs"
else
    bad "run.sh sources libs"
fi

# Справка и версия
if bash "${ROOT}/run.sh" --help >/dev/null 2>&1; then ok "run.sh --help"; else bad "run.sh --help"; fi
if [[ "$(bash "${ROOT}/run.sh" --version 2>/dev/null)" == "${lib_ver}" ]]; then ok "run.sh --version"; else bad "run.sh --version"; fi

# Без терминала wizard должен выйти с понятной ошибкой, ничего не меняя
if command -v setsid >/dev/null 2>&1; then
    out=$(setsid bash "${ROOT}/run.sh" --dry-run --text </dev/null 2>&1) && rc=0 || rc=$?
    if [[ "${rc}" -ne 0 && "${out}" == *"Нет интерактивного терминала"* ]]; then
        ok "run.sh without tty exits cleanly"
    else
        bad "run.sh without tty (rc=${rc})"
    fi
fi

# Модули загружаются и ключевые функции определены
# shellcheck disable=SC1090,SC2034
if (
    DRY_RUN=true
    for f in "${ROOT}"/lib/*.sh; do source "${f}"; done
    for fn in choose confirm has_internet get_ssh_ports pkg_install fw_allow_port \
        fail2ban_apply_config step_ssh_configure step_firewall_configure step_fail2ban; do
        declare -F "${fn}" >/dev/null || { echo "missing ${fn}"; exit 1; }
    done
) >/dev/null 2>&1; then
    ok "libs load, functions defined"
else
    bad "libs load"
fi

# Разбор слушающих портов: 443/tcp и 443/udp не склеиваются, эфемерные UDP xray скрыты
# shellcheck disable=SC1090,SC2317
ports_out=$(
    for f in "${ROOT}"/lib/*.sh; do source "${f}"; done
    ss() {
        cat << 'SS'
Netid State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
udp   UNCONN 0      0            0.0.0.0:54289      0.0.0.0:*    users:(("rw-core",pid=1479,fd=368))
udp   UNCONN 0      0                  *:443              *:*    users:(("rw-core",pid=1479,fd=9))
tcp   LISTEN 0      4096               *:443              *:*    users:(("rw-core",pid=1479,fd=7))
tcp   LISTEN 0      4096               *:2222             *:*    users:(("rw-node",pid=1283,fd=21))
tcp   LISTEN 0      4096               *:80               *:*    users:(("caddy",pid=1136,fd=7))
tcp   LISTEN 0      128          0.0.0.0:2228       0.0.0.0:*    users:(("sshd",pid=827,fd=3))
tcp   LISTEN 0      4096       127.0.0.1:9443       0.0.0.0:*    users:(("caddy",pid=1136,fd=8))
SS
    }
    list_public_listening_ports
    echo "skipped=$(_count_ephemeral_udp)"
)
expected=$'80/tcp caddy
443/tcp rw-core
443/udp rw-core
2222/tcp rw-node
skipped=1'
if [[ "${ports_out}" == "${expected}" ]]; then
    ok "list_public_listening_ports (443 tcp+udp, ephemeral UDP skipped)"
else
    bad "list_public_listening_ports: ${ports_out//$'
'/ | }"
fi

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ "${FAIL}" -eq 0 ]]
