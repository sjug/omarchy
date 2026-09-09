#!/bin/bash

set -euo pipefail

# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

checkout="$test_tmp/checkout"
state_dir="$test_tmp/state"
migrations="$checkout/migrations/desktop-overlay"
run_log="$test_tmp/run.log"
stub_bin="$test_tmp/bin"
mkdir -p "$migrations" "$stub_bin" "$state_dir"
touch "$state_dir/.baseline-established"

cat >"$stub_bin/omarchy-installation-type" <<'SH'
#!/bin/bash
if [[ ${OMARCHY_TEST_CLASSIFY_FAILS:-0} == "1" ]]; then
  echo "stub classification failure" >&2
  exit 1
fi
printf '%s\n' "${OMARCHY_TEST_INSTALLATION_TYPE:-desktop_overlay}"
SH
cat >"$stub_bin/omarchy-overlay-stages" <<'SH'
#!/bin/bash
if [[ ${OMARCHY_TEST_STAGES_FAIL:-0} == "1" ]]; then
  echo "stub stage failure" >&2
  exit 1
fi
echo core
SH
chmod +x "$stub_bin"/*

cat >"$migrations/100-first.sh" <<'SH'
echo first >>"$TEST_RUN_LOG"
SH
cat >"$migrations/200-second.sh" <<'SH'
echo second >>"$TEST_RUN_LOG"
SH

run_migrator() {
  OMARCHY_PATH="$checkout" \
    OMARCHY_OVERLAY_MIGRATION_STATE="$state_dir" \
    OMARCHY_PACMAN_LOCK_PATH="$test_tmp/no-pacman-lock" \
    TEST_RUN_LOG="$run_log" \
    PATH="$stub_bin:$PATH" \
    "$ROOT/bin/omarchy-overlay-migrate" "$@"
}

help_output=$(env -i PATH=/usr/bin "$ROOT/bin/omarchy-overlay-migrate" --help)
grep -q '^Usage: omarchy-overlay-migrate ' <<<"$help_output" || fail "overlay migration help depends on a registered runtime"
pass "overlay migration help is available before installation detection"

pending=$(run_migrator --pending)
[[ $pending == $'100-first.sh\n200-second.sh' ]] || fail "pending mode lists every overlay migration in order" "$pending"
[[ $(find "$state_dir" -mindepth 1 -maxdepth 1 -printf '%f\n') == ".baseline-established" ]] ||
  fail "pending mode changes established migration state"
pass "desktop-overlay pending checks are read-only"

run_migrator >/dev/null
[[ $(<"$run_log") == $'first\nsecond' ]] || fail "overlay migrations execute in filename order" "$(<"$run_log")"
[[ -f $state_dir/100-first.sh && -f $state_dir/200-second.sh ]] || fail "successful overlay migrations get their own markers"
if run_migrator --pending >/dev/null; then
  fail "pending mode succeeds after every overlay migration has run"
fi
run_migrator >/dev/null
[[ $(wc -l <"$run_log") == 2 ]] || fail "completed overlay migrations run more than once" "$(<"$run_log")"
pass "desktop-overlay migrations have an independent one-time state stream"

rm -f "$state_dir/200-second.sh"
cat >"$migrations/200-second.sh" <<'SH'
echo failing >>"$TEST_RUN_LOG"
exit 1
SH
if run_migrator >"$test_tmp/out" 2>"$test_tmp/err"; then
  fail "a failing overlay migration passes"
fi
[[ ! -e $state_dir/200-second.sh ]] || fail "a failing overlay migration is marked complete"
pass "failed desktop-overlay migrations remain pending"

rm -rf "$state_dir"
: >"$run_log"
if run_migrator >"$test_tmp/no-baseline.out" 2>"$test_tmp/no-baseline.err"; then
  fail "overlay migrations run without an established baseline"
fi
grep -q "omarchy overlay register --repair" "$test_tmp/no-baseline.err" ||
  fail "a missing migration baseline does not name its repair" "$(<"$test_tmp/no-baseline.err")"
[[ ! -s $run_log ]] || fail "missing-baseline validation runs historical migrations" "$(<"$run_log")"
pass "a missing migration baseline fails before replaying historical migrations"

if env -u OMARCHY_PATH \
  OMARCHY_OVERLAY_MIGRATION_STATE="$state_dir" \
  OMARCHY_PACMAN_LOCK_PATH="$test_tmp/no-pacman-lock" \
  PATH="$stub_bin:$PATH" \
  "$ROOT/bin/omarchy-overlay-migrate" >"$test_tmp/unlinked.out" 2>"$test_tmp/unlinked.err"; then
  fail "overlay migration accepts an unset OMARCHY_PATH"
fi
grep -q 'OMARCHY_PATH is unset' "$test_tmp/unlinked.err" ||
  fail "overlay migration crashes instead of explaining its missing runtime path" "$(<"$test_tmp/unlinked.err")"
pass "overlay migration fails cleanly when the link stage is not active"

# A watcher reads these codes to decide whether a machine is healthy, so no
# failure may share the "none pending" code.
rm -rf "$state_dir"
mkdir -p "$state_dir"
touch "$state_dir/.baseline-established"

migrate_status() {
  local status=0

  run_migrator "$@" >"$test_tmp/status.out" 2>"$test_tmp/status.err" || status=$?
  printf '%s' "$status"
}

for flag in --pending --check; do
  status=$(migrate_status "$flag")
  [[ $status == 0 ]] || fail "$flag does not exit 0 while migrations are pending" "$status"
  [[ $(<"$test_tmp/status.out") == $'100-first.sh\n200-second.sh' ]] ||
    fail "$flag does not list the pending overlay migrations" "$(<"$test_tmp/status.out")"
done
pass "--check is an alias for --pending and both report pending work as exit 0"

touch "$state_dir/100-first.sh" "$state_dir/200-second.sh"
status=$(migrate_status --pending)
[[ $status == 1 ]] || fail "a fully-migrated overlay does not exit 1 from --pending" "$status"
[[ ! -s $test_tmp/status.out ]] ||
  fail "--pending prints migration names when none are pending" "$(<"$test_tmp/status.out")"
pass "--pending reserves exit 1 for a healthy overlay with nothing pending"

rm -f "$state_dir/.baseline-established"
status=$(migrate_status --pending)
[[ $status == 2 ]] ||
  fail "a missing migration baseline is indistinguishable from having nothing pending" "$status"
grep -q "omarchy overlay register --repair" "$test_tmp/status.err" ||
  fail "the --pending baseline failure does not name its repair" "$(<"$test_tmp/status.err")"
touch "$state_dir/.baseline-established"

status=$(OMARCHY_TEST_INSTALLATION_TYPE=product migrate_status --pending)
[[ $status == 2 ]] || fail "a non-overlay installation reports as nothing pending" "$status"

status=$(OMARCHY_TEST_CLASSIFY_FAILS=1 migrate_status --pending)
[[ $status == 2 ]] || fail "a failing installation classifier reports as nothing pending" "$status"

status=$(OMARCHY_TEST_STAGES_FAIL=1 migrate_status --pending)
[[ $status == 2 ]] || fail "a failing stage query reports as nothing pending" "$status"

status=$(migrate_status --bogus)
[[ $status == 2 ]] || fail "an unusable invocation reports as nothing pending" "$status"
pass "--pending reserves exit 2 for every state it cannot answer from"
