#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
shell_calls="$test_tmp/shell-calls"
mkdir -p "$stub_bin"

cat >"$stub_bin/omarchy-update-available" <<'SH'
#!/bin/bash

exit "${UPDATE_AVAILABLE_STATUS:-0}"
SH

cat >"$stub_bin/omarchy-shell" <<'SH'
#!/bin/bash

printf '%s\n' "$*" >>"$SHELL_CALLS"
SH

chmod +x "$stub_bin/omarchy-update-available" "$stub_bin/omarchy-shell"

PATH="$stub_bin:$PATH" SHELL_CALLS="$shell_calls" UPDATE_AVAILABLE_STATUS=0 \
  "$ROOT/bin/omarchy-update-status"
grep -Fx -- "-q omarchy.system-update refresh" "$shell_calls" >/dev/null ||
  fail "update status refreshes the shell indicator when updates remain"
pass "update status refreshes the shell indicator when updates remain"

: >"$shell_calls"
PATH="$stub_bin:$PATH" SHELL_CALLS="$shell_calls" UPDATE_AVAILABLE_STATUS=1 \
  "$ROOT/bin/omarchy-update-status"
grep -Fx -- "-q omarchy.system-update clear" "$shell_calls" >/dev/null ||
  fail "update status clears the shell indicator when no updates remain"
pass "update status clears the shell indicator when no updates remain"

: >"$shell_calls"
if PATH="$stub_bin:$PATH" SHELL_CALLS="$shell_calls" UPDATE_AVAILABLE_STATUS=2 \
  "$ROOT/bin/omarchy-update-status" >"$test_tmp/error.out" 2>"$test_tmp/error.err"; then
  fail "an update-detection error is treated as no updates"
fi
[[ ! -s $shell_calls ]] || fail "an update-detection error changes the shell indicator" "$(<"$shell_calls")"
grep -q "leaving the indicator unchanged" "$test_tmp/error.err" ||
  fail "an update-detection error explains indicator preservation" "$(<"$test_tmp/error.err")"
pass "update status preserves the indicator when detection fails"
