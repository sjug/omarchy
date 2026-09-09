#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
log_file="$test_tmp/dev-unlink.log"
conf_file="$test_tmp/omarchy.conf"
descriptor="$test_tmp/installation.conf"
mkdir -p "$stub_bin" "$test_tmp/home"

cat >"$stub_bin/pacman" <<'SH'
#!/bin/bash
if [[ ${OMARCHY_TEST_PRODUCT_INSTALLED:-1} == "1" && $1 == "-Qq" && $2 == "omarchy" ]]; then
  echo omarchy
else
  exit 1
fi
SH
chmod +x "$stub_bin/pacman"

cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash

printf 'sudo' >>"$OMARCHY_DEV_UNLINK_TEST_LOG"
for arg in "$@"; do
  printf '\t%s' "$arg" >>"$OMARCHY_DEV_UNLINK_TEST_LOG"
done
printf '\n' >>"$OMARCHY_DEV_UNLINK_TEST_LOG"

if [[ $1 == "tee" ]]; then
  cat >"$OMARCHY_DEV_UNLINK_TEST_CONF"
fi
SH
chmod +x "$stub_bin/sudo"

cat >"$stub_bin/gum" <<'SH'
#!/bin/bash

printf 'gum' >>"$OMARCHY_DEV_UNLINK_TEST_LOG"
for arg in "$@"; do
  printf '\t%s' "$arg" >>"$OMARCHY_DEV_UNLINK_TEST_LOG"
done
printf '\n' >>"$OMARCHY_DEV_UNLINK_TEST_LOG"
SH
chmod +x "$stub_bin/gum"

cat >"$stub_bin/omarchy-system-reboot" <<'SH'
#!/bin/bash

printf 'reboot\n' >>"$OMARCHY_DEV_UNLINK_TEST_LOG"
SH
chmod +x "$stub_bin/omarchy-system-reboot"

run_unlink() {
  HOME="$test_tmp/home" \
    OMARCHY_PATH="${OMARCHY_TEST_RUNTIME_PATH:-$ROOT}" \
    OMARCHY_INSTALLATION_CONF_PATH="$descriptor" \
    OMARCHY_RUNTIME_CONF_PATH="$conf_file" \
    OMARCHY_DEV_UNLINK_TEST_LOG="$log_file" \
    OMARCHY_DEV_UNLINK_TEST_CONF="$conf_file" \
    PATH="$stub_bin:$PATH" \
    "${OMARCHY_DEV_UNLINK_COMMAND:-$ROOT/bin/omarchy-dev-unlink}" "$@"
}

# Product packages split /usr/bin entry points from the source tree under
# /usr/share/omarchy, so helper resolution must follow OMARCHY_PATH.
packaged_bin="$test_tmp/usr/bin"
packaged_root="$test_tmp/usr/share/omarchy"
mkdir -p "$packaged_bin" "$packaged_root/install/helpers"
# Redirect the package data root even when OMARCHY_PATH is unset, so these
# commands never source the test host's installed helper.
sed "s|/usr/share/omarchy|$packaged_root|g" "$ROOT/bin/omarchy-dev-unlink" >"$packaged_bin/omarchy-dev-unlink"
chmod +x "$packaged_bin/omarchy-dev-unlink"
cp "$ROOT/install/helpers/runtime-link.sh" "$packaged_root/install/helpers/"
cat >"$packaged_bin/omarchy-installation-type" <<'SH'
#!/bin/bash
echo product
SH
chmod +x "$packaged_bin/omarchy-installation-type"

: >"$log_file"
OMARCHY_DEV_UNLINK_COMMAND="$packaged_bin/omarchy-dev-unlink" \
  OMARCHY_TEST_RUNTIME_PATH="$packaged_root" \
  run_unlink --no-reboot
[[ -s $conf_file ]] || fail "packaged dev unlink cannot load its shared runtime-link helper"
pass "packaged dev unlink resolves its helper through OMARCHY_PATH"

: >"$log_file"
run_unlink --no-reboot

grep -Fx $'sudo\ttee\t/etc/omarchy.conf' "$log_file" >/dev/null ||
  fail "dev unlink writes the package path without rebooting" "$(cat "$log_file")"
[[ $(<"$conf_file") == 'export OMARCHY_PATH="/usr/share/omarchy"' ]] ||
  fail "dev unlink writes the package path guard" "$(<"$conf_file")"

# Left behind, it keeps sudo running a checkout nothing else points at.
grep -Fx $'sudo\trm\t-f\t/etc/sudoers.d/omarchy-dev-path' "$log_file" >/dev/null ||
  fail "dev unlink drops the sudo secure_path drop-in" "$(cat "$log_file")"
pass "dev unlink drops the sudo secure_path drop-in"

if grep -Eq '^(gum|reboot)' "$log_file"; then
  fail "dev unlink --no-reboot skips the reboot prompt" "$(cat "$log_file")"
fi
pass "dev unlink --no-reboot skips the reboot prompt"

: >"$log_file"
run_unlink

grep -Fx $'gum\tconfirm\tReboot now to activate?' "$log_file" >/dev/null ||
  fail "interactive dev unlink still prompts for reboot" "$(cat "$log_file")"
grep -Fx 'reboot' "$log_file" >/dev/null ||
  fail "interactive dev unlink still reboots after confirmation" "$(cat "$log_file")"
pass "interactive dev unlink keeps its reboot prompt"

if run_unlink --invalid >"$test_tmp/invalid.out" 2>"$test_tmp/invalid.err"; then
  fail "dev unlink rejects unknown arguments"
fi
grep -F 'Usage: omarchy dev unlink [--no-reboot]' "$test_tmp/invalid.err" >/dev/null ||
  fail "dev unlink explains valid arguments" "$(cat "$test_tmp/invalid.err")"
pass "dev unlink rejects unknown arguments"

printf 'OMARCHY_INSTALLATION=desktop_overlay\nOMARCHY_DESKTOP_STAGES=core,link\n' >"$descriptor"
: >"$log_file"
if OMARCHY_TEST_PRODUCT_INSTALLED=0 run_unlink --no-reboot >"$test_tmp/overlay.out" 2>"$test_tmp/overlay.err"; then
  fail "dev unlink accepts a registered desktop overlay"
fi
grep -q "omarchy overlay setup link" "$test_tmp/overlay.err" ||
  fail "dev unlink does not name the overlay-safe link repair" "$(<"$test_tmp/overlay.err")"
[[ ! -s $log_file ]] || fail "refused overlay dev unlink changes system state" "$(<"$log_file")"
pass "dev unlink cannot detach a registered desktop overlay"

printf 'not a valid installation descriptor\n' >"$descriptor"
: >"$log_file"
if OMARCHY_TEST_PRODUCT_INSTALLED=0 run_unlink --no-reboot >"$test_tmp/malformed.out" 2>"$test_tmp/malformed.err"; then
  fail "dev unlink accepts a malformed installation descriptor"
fi
grep -q 'must contain exactly one valid OMARCHY_INSTALLATION' "$test_tmp/malformed.err" ||
  fail "dev unlink hides the descriptor error that caused its refusal" "$(<"$test_tmp/malformed.err")"
[[ ! -s $log_file ]] || fail "malformed-descriptor dev unlink changes system state" "$(<"$log_file")"
pass "dev unlink fails closed when installation classification fails"

run_unlink_without_environment() {
  env -u OMARCHY_PATH \
    HOME="$test_tmp/home" \
    OMARCHY_INSTALLATION_CONF_PATH="$descriptor" \
    OMARCHY_RUNTIME_CONF_PATH="$conf_file" \
    OMARCHY_DEV_UNLINK_TEST_LOG="$log_file" \
    OMARCHY_DEV_UNLINK_TEST_CONF="$conf_file" \
    PATH="$stub_bin:$PATH" \
    "$packaged_bin/omarchy-dev-unlink" --no-reboot \
    >"$test_tmp/nopath.out" 2>"$test_tmp/nopath.err"
}

assert_unlink_written() {
  [[ $(<"$conf_file") == "export OMARCHY_PATH=\"$packaged_root\"" ]] ||
    fail "dev unlink without OMARCHY_PATH did not restore the packaged runtime"
  grep -q $'^sudo\ttee\t' "$log_file" || fail "dev unlink skipped the runtime writer"
  grep -Fx $'sudo\trm\t-f\t/etc/sudoers.d/omarchy-dev-path' "$log_file" >/dev/null ||
    fail "dev unlink without OMARCHY_PATH did not remove the sudoers policy"
}

rm -f "$descriptor" "$conf_file"
: >"$log_file"
run_unlink_without_environment || fail "packaged dev unlink failed with OMARCHY_PATH unset" "$(<"$test_tmp/nopath.err")"
assert_unlink_written
pass "dev unlink uses the packaged helper and writes configuration without a session environment"

runtime_checkout="$test_tmp/runtime checkout"
mkdir -p "$runtime_checkout/install/helpers"
cp "$ROOT/install/helpers/runtime-link.sh" "$runtime_checkout/install/helpers/"
mv "$packaged_root/install/helpers/runtime-link.sh" "$packaged_root/install/helpers/runtime-link.saved"
printf 'export OMARCHY_PATH="%s"\n' "$runtime_checkout" >"$conf_file"
: >"$log_file"
run_unlink_without_environment || fail "dev unlink ignored the configured checkout without OMARCHY_PATH" "$(<"$test_tmp/nopath.err")"
assert_unlink_written
pass "dev unlink uses the configured checkout without a session environment or packaged helper"

printf 'export OMARCHY_PATH="/opt/omarchy\n' >"$conf_file"
: >"$log_file"
parse_status=0
run_unlink_without_environment || parse_status=$?
(( parse_status == 2 )) || fail "dev unlink does not preserve the configuration syntax-error status" "$parse_status"
[[ ! -s $log_file ]] || fail "dev unlink writes system files with an unbalanced quote in the runtime configuration"
grep -F "Error: could not load runtime configuration: $conf_file" "$test_tmp/nopath.err" >/dev/null ||
  fail "dev unlink does not explain its configuration parse failure" "$(<"$test_tmp/nopath.err")"
grep -Fx 'Repair or remove it, then retry.' "$test_tmp/nopath.err" >/dev/null ||
  fail "dev unlink does not explain how to recover from a configuration parse failure"
pass "dev unlink explains configuration syntax errors before privileged writes"

printf 'return 42\n' >"$conf_file"
: >"$log_file"
runtime_status=0
run_unlink_without_environment || runtime_status=$?
(( runtime_status == 42 )) || fail "dev unlink does not preserve a failing configuration's exit status" "$runtime_status"
[[ ! -s $log_file ]] || fail "dev unlink writes system files after failing to load its runtime configuration"
grep -F "Error: could not load runtime configuration: $conf_file" "$test_tmp/nopath.err" >/dev/null ||
  fail "dev unlink does not explain its runtime configuration load failure" "$(<"$test_tmp/nopath.err")"
grep -Fx 'Repair or remove it, then retry.' "$test_tmp/nopath.err" >/dev/null ||
  fail "dev unlink does not explain how to recover from a configuration load failure"
pass "dev unlink refuses a broken runtime configuration before privileged writes"

printf 'false\nexport OMARCHY_PATH="%s"\n' "$runtime_checkout" >"$conf_file"
: >"$log_file"
if run_unlink_without_environment; then
  fail "dev unlink suppresses errexit while loading its runtime configuration"
fi
[[ ! -s $log_file ]] || fail "dev unlink writes system files after a failed configuration command"
pass "dev unlink preserves errexit while loading its runtime configuration"

OMARCHY_DEV_UNLINK_COMMAND="$packaged_bin/omarchy-dev-unlink" \
  OMARCHY_TEST_RUNTIME_PATH="$runtime_checkout" \
  run_unlink --no-reboot >/dev/null
assert_unlink_written
pass "dev unlink keeps the active environment ahead of the configured runtime"

mv "$packaged_root/install/helpers/runtime-link.saved" "$packaged_root/install/helpers/runtime-link.sh"
for scenario in deleted old unreadable directory; do
  stale_checkout="$test_tmp/stale-$scenario"
  if [[ $scenario != "deleted" ]]; then
    mkdir -p "$stale_checkout/install/helpers"
  fi
  case "$scenario" in
    unreadable)
      cp "$ROOT/install/helpers/runtime-link.sh" "$stale_checkout/install/helpers/"
      chmod 000 "$stale_checkout/install/helpers/runtime-link.sh"
      ;;
    directory) mkdir "$stale_checkout/install/helpers/runtime-link.sh" ;;
  esac
  for origin in config environment; do
    printf 'export OMARCHY_PATH="%s"\n' "$stale_checkout" >"$conf_file"
    : >"$log_file"
    if [[ $origin == "config" ]]; then
      run_unlink_without_environment || fail "dev unlink cannot recover a $scenario checkout from config" "$(<"$test_tmp/nopath.err")"
    else
      OMARCHY_DEV_UNLINK_COMMAND="$packaged_bin/omarchy-dev-unlink" \
        OMARCHY_TEST_RUNTIME_PATH="$stale_checkout" \
        run_unlink --no-reboot >"$test_tmp/nopath.out" 2>"$test_tmp/nopath.err" ||
        fail "dev unlink cannot recover a $scenario checkout from the environment" "$(<"$test_tmp/nopath.err")"
    fi
    assert_unlink_written
    pass "dev unlink recovers a $scenario checkout from $origin through the packaged helper"
  done
done

mv "$packaged_root/install/helpers/runtime-link.sh" "$packaged_root/install/helpers/runtime-link.saved"
printf 'export OMARCHY_PATH="%s"\n' "$stale_checkout" >"$conf_file"
cp "$conf_file" "$test_tmp/conf-before-refusal"
: >"$log_file"
if run_unlink_without_environment; then
  fail "dev unlink accepts two unusable runtime helpers"
fi
for candidate in "$stale_checkout" "$packaged_root"; do
  grep -F "$candidate/install/helpers/runtime-link.sh" "$test_tmp/nopath.err" >/dev/null ||
    fail "dev unlink does not name both unusable helpers" "$(<"$test_tmp/nopath.err")"
done
[[ ! -s $log_file ]] || fail "dev unlink writes system files without a usable runtime helper"
cmp -s "$conf_file" "$test_tmp/conf-before-refusal" || fail "dev unlink changes the configuration when helper resolution fails"
pass "dev unlink names both unusable helpers and refuses before writing"

mv "$packaged_root/install/helpers/runtime-link.saved" "$packaged_root/install/helpers/runtime-link.sh"
for scenario in directory unreadable dangling-symlink; do
  bad_conf="$test_tmp/config-$scenario"
  case "$scenario" in
    directory) mkdir "$bad_conf" ;;
    unreadable) touch "$bad_conf"; chmod 000 "$bad_conf" ;;
    dangling-symlink) ln -s "$test_tmp/missing-config-target" "$bad_conf" ;;
  esac
  : >"$log_file"
  if conf_file="$bad_conf" run_unlink_without_environment; then
    fail "dev unlink ignores a $scenario runtime configuration"
  fi
  grep -F "Error: runtime configuration is not a readable regular file: $bad_conf" "$test_tmp/nopath.err" >/dev/null ||
    fail "dev unlink does not explain the $scenario configuration refusal" "$(<"$test_tmp/nopath.err")"
  grep -Fx 'Repair or remove it, then retry.' "$test_tmp/nopath.err" >/dev/null ||
    fail "dev unlink does not explain how to recover from a $scenario configuration"
  [[ ! -s $log_file ]] || fail "dev unlink writes system files with a $scenario runtime configuration"
  pass "dev unlink explains and refuses a $scenario configuration before writing"
done
