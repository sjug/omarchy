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
cp "$ROOT/bin/omarchy-dev-unlink" "$packaged_bin/"
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
