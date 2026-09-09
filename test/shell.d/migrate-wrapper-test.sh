#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

test_root="$test_tmp/omarchy"
test_home="$test_tmp/home"
stub_bin="$test_tmp/bin"
mkdir -p "$test_root/migrations" "$test_home" "$stub_bin"

cat >"$stub_bin/omarchy-notification-dismiss" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >>"$TEST_DISMISSALS"
SH
cat >"$stub_bin/omarchy-installation-type" <<'SH'
#!/bin/bash
if [[ ${TEST_REQUIRE_CLASSIFY_ONLY:-0} == "1" && ${1:-} != "--classify-only" ]]; then
  exit 72
fi
echo "${TEST_INSTALLATION_TYPE:-product}"
SH
chmod +x "$stub_bin/omarchy-notification-dismiss"
chmod +x "$stub_bin/omarchy-installation-type"

cat >"$test_root/migrations/100-migration.sh" <<'SH'
echo migration >>"$TEST_CALLS"
SH

run_migrate() {
  HOME="$test_home" \
  OMARCHY_PATH="$test_root" \
  PATH="$stub_bin:$ROOT/bin:$PATH" \
  TEST_CALLS="$test_tmp/calls" \
  TEST_DISMISSALS="$test_tmp/dismissals" \
    "$ROOT/bin/omarchy-migrate" "$@"
}

: >"$test_tmp/calls"
run_migrate >"$test_tmp/migrate.out"
[[ $(sed -n '1p' "$test_tmp/calls") == "migration" ]] || fail "omarchy-migrate runs pending migrations"
pass "omarchy-migrate runs migrations without force"

grep -Fx 'Omarchy Migrations' "$test_tmp/dismissals" >/dev/null || fail "omarchy-migrate dismisses migration notifications"
pass "omarchy-migrate clears completed migration notifications"

rm -rf "$test_home/.local/state/omarchy/migrations"
run_migrate --pending >"$test_tmp/pending.out"
grep -q '^100-migration\.sh$' "$test_tmp/pending.out" || fail "omarchy-migrate --pending lists pending migrations"
pass "omarchy-migrate --pending lists pending migrations"

run_migrate >"$test_tmp/migrate-second.out"
if run_migrate --pending >"$test_tmp/not-pending.out"; then
  fail "omarchy-migrate --pending exits non-zero without pending migrations"
fi
[[ ! -s $test_tmp/not-pending.out ]] || fail "omarchy-migrate --pending stays quiet without pending migrations"
pass "omarchy-migrate --pending reports no pending migrations"

if run_migrate --force >"$test_tmp/force.out" 2>&1; then
  fail "omarchy-migrate rejects obsolete --force option"
fi
grep -q 'Unknown option: --force' "$test_tmp/force.out" || fail "omarchy-migrate reports obsolete --force option"
pass "omarchy-migrate no longer needs --force"

rm -rf "$test_home/.local/state/omarchy/migrations"
if TEST_INSTALLATION_TYPE=desktop_overlay TEST_REQUIRE_CLASSIFY_ONLY=1 run_migrate >"$test_tmp/overlay.out" 2>"$test_tmp/overlay.err"; then
  fail "the product migration runner accepts a desktop overlay"
fi
grep -q "run 'omarchy overlay migrate' instead" "$test_tmp/overlay.err" ||
  fail "the product migration refusal does not name the overlay-safe runner" "$(<"$test_tmp/overlay.err")"
[[ ! -e $test_home/.local/state/omarchy/migrations ]] || fail "a refused overlay run creates product migration state"
pass "desktop overlays cannot enter the product migration stream"
