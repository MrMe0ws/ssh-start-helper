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

if grep -q 'INSTALL_VERSION="1.0.5"' "${ROOT}/install.sh"; then
    ok "install.sh version tag"
else
    bad "install.sh version tag"
fi

# run.sh sources common.sh
if grep -q 'source.*common.sh' "${ROOT}/run.sh"; then
    ok "run.sh sources libs"
else
    bad "run.sh sources libs"
fi

# Dry-run (needs root on Linux — skip on non-root)
if [[ "${EUID}" -eq 0 ]] && [[ -f /etc/os-release ]]; then
    if bash "${ROOT}/run.sh" --dry-run <<< $'n\nn\n' 2>/dev/null; then
        ok "run.sh --dry-run (root)"
    else
        bad "run.sh --dry-run (root)"
    fi
else
    echo "[SKIP] run.sh --dry-run (needs root + Linux)"
fi

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ "${FAIL}" -eq 0 ]]
