#!/bin/bash

set -euo pipefail

# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
descriptor="$test_tmp/installation.conf"
runtime_conf="$test_tmp/omarchy.conf"
mkdir -p "$stub_bin"

cat >"$stub_bin/pacman" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$stub_bin/pacman"

read_stages() {
  OMARCHY_INSTALLATION_CONF_PATH="$descriptor" \
    OMARCHY_RUNTIME_CONF_PATH="$runtime_conf" \
    OMARCHY_PATH="$test_tmp/checkout" \
    PATH="$stub_bin:$ROOT/bin:$PATH" \
    "$ROOT/bin/omarchy-overlay-stages"
}

printf 'export OMARCHY_PATH="%s"\n' "$test_tmp/checkout" >"$runtime_conf"

printf 'OMARCHY_INSTALLATION=desktop_overlay\nOMARCHY_DESKTOP_OWNER=%s\nOMARCHY_DESKTOP_STAGES=display-manager,core,config,link,session-entry\n' \
  "$(id -un)" >"$descriptor"
[[ $(read_stages) == $'core\nlink\nconfig\nsession-entry\ndisplay-manager' ]] || fail "recorded stages are not normalized into dependency order" "$(read_stages)"
pass "desktop-overlay stages are emitted in canonical dependency order"

printf 'OMARCHY_INSTALLATION=desktop_overlay\nOMARCHY_DESKTOP_OWNER=somebody-else\nOMARCHY_DESKTOP_STAGES=core\n' >"$descriptor"
if read_stages >"$test_tmp/out" 2>"$test_tmp/err"; then
  fail "a different user can consume another user's overlay ledger"
fi
grep -q "belongs to 'somebody-else'" "$test_tmp/err" || fail "owner mismatch identifies the recorded owner" "$(<"$test_tmp/err")"

printf 'OMARCHY_INSTALLATION=desktop_overlay\nOMARCHY_DESKTOP_OWNER=%s\nOMARCHY_DESKTOP_STAGES=core,core\n' \
  "$(id -un)" >"$descriptor"
if read_stages >"$test_tmp/out" 2>"$test_tmp/err"; then
  fail "duplicate stages are accepted"
fi
grep -q "stage 'core' more than once" "$test_tmp/err" || fail "duplicate stage error names the stage" "$(<"$test_tmp/err")"

printf 'OMARCHY_INSTALLATION=desktop_overlay\nOMARCHY_DESKTOP_OWNER=%s\nOMARCHY_DESKTOP_STAGES=core,unknown-stage\n' \
  "$(id -un)" >"$descriptor"
if read_stages >"$test_tmp/out" 2>"$test_tmp/err"; then
  fail "unknown stages are accepted"
fi
grep -q "unknown desktop-overlay stage 'unknown-stage'" "$test_tmp/err" || fail "unknown stage error names the stage" "$(<"$test_tmp/err")"

for invalid_stages in audio config core,display-manager; do
  printf 'OMARCHY_INSTALLATION=desktop_overlay\nOMARCHY_DESKTOP_OWNER=%s\nOMARCHY_DESKTOP_STAGES=%s\n' \
    "$(id -un)" "$invalid_stages" >"$descriptor"
  if read_stages >"$test_tmp/out" 2>"$test_tmp/err"; then
    fail "invalid dependency ledger '$invalid_stages' is accepted"
  fi
done
pass "desktop-overlay stage ledgers reject wrong owners, duplicates, unknown stages, and broken dependencies"
