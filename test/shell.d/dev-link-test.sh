#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
log_file="$test_tmp/dev-link.log"
conf_file="$test_tmp/omarchy.conf"
sudoers_file="$test_tmp/omarchy-dev-path"
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

printf 'sudo' >>"$OMARCHY_DEV_LINK_TEST_LOG"
for arg in "$@"; do
  printf '\t%s' "$arg" >>"$OMARCHY_DEV_LINK_TEST_LOG"
done
printf '\n' >>"$OMARCHY_DEV_LINK_TEST_LOG"

case "$1" in
  tee)
    cat >"$OMARCHY_DEV_LINK_TEST_CONF"
    ;;
  install)
    # The staged file is the second-to-last argument.
    cp "${@: -2:1}" "$OMARCHY_DEV_LINK_TEST_SUDOERS"
    ;;
  rm)
    rm -f "$OMARCHY_DEV_LINK_TEST_SUDOERS"
    ;;
esac
SH
chmod +x "$stub_bin/sudo"

cat >"$stub_bin/gum" <<'SH'
#!/bin/bash

printf 'gum' >>"$OMARCHY_DEV_LINK_TEST_LOG"
for arg in "$@"; do
  printf '\t%s' "$arg" >>"$OMARCHY_DEV_LINK_TEST_LOG"
done
printf '\n' >>"$OMARCHY_DEV_LINK_TEST_LOG"
SH
chmod +x "$stub_bin/gum"

cat >"$stub_bin/omarchy-system-reboot" <<'SH'
#!/bin/bash

printf 'reboot\n' >>"$OMARCHY_DEV_LINK_TEST_LOG"
SH
chmod +x "$stub_bin/omarchy-system-reboot"

run_link() {
  HOME="$test_tmp/home" \
    OMARCHY_PATH="${OMARCHY_TEST_RUNTIME_PATH:-$ROOT}" \
    OMARCHY_INSTALLATION_CONF_PATH="$descriptor" \
    OMARCHY_RUNTIME_CONF_PATH="$conf_file" \
    OMARCHY_DEV_LINK_TEST_LOG="$log_file" \
    OMARCHY_DEV_LINK_TEST_CONF="$conf_file" \
    OMARCHY_DEV_LINK_TEST_SUDOERS="$sudoers_file" \
    PATH="$stub_bin:$PATH" \
    "${OMARCHY_DEV_LINK_COMMAND:-$ROOT/bin/omarchy-dev-link}" "$@"
}

make_checkout() {
  local checkout="$test_tmp/$1"

  mkdir -p "$checkout/bin" "$checkout/default" "$checkout/shell"
  printf '%s' "$checkout"
}

checkout=$(make_checkout checkout)

# Product packages install commands in /usr/bin while their shared source tree
# lives under /usr/share/omarchy. The command must resolve its helper through
# OMARCHY_PATH rather than relative to the executable.
packaged_bin="$test_tmp/usr/bin"
packaged_root="$test_tmp/usr/share/omarchy"
mkdir -p "$packaged_bin" "$packaged_root/install/helpers"
# Relocate the package data root in the fixture command, including its fallback.
# Unset-environment tests must never source an installed copy on the test host.
sed "s|/usr/share/omarchy|$packaged_root|g" "$ROOT/bin/omarchy-dev-link" >"$packaged_bin/omarchy-dev-link"
chmod +x "$packaged_bin/omarchy-dev-link"
cp "$ROOT/install/helpers/runtime-link.sh" "$packaged_root/install/helpers/"
cat >"$packaged_bin/omarchy-installation-type" <<'SH'
#!/bin/bash
echo product
SH
chmod +x "$packaged_bin/omarchy-installation-type"

: >"$log_file"
: >"$sudoers_file"
OMARCHY_DEV_LINK_COMMAND="$packaged_bin/omarchy-dev-link" \
  OMARCHY_TEST_RUNTIME_PATH="$packaged_root" \
  run_link "$checkout" --no-reboot >/dev/null
[[ -s $conf_file ]] || fail "packaged dev link cannot load its shared runtime-link helper"
pass "packaged dev link resolves its helper through OMARCHY_PATH"

: >"$log_file"
: >"$sudoers_file"
run_link "$checkout" --no-reboot >"$test_tmp/link.out"

[[ $(<"$conf_file") == "export OMARCHY_PATH=\"$checkout\"" ]] ||
  fail "dev link points OMARCHY_PATH at the checkout" "$(<"$conf_file")"
pass "dev link points OMARCHY_PATH at the checkout"

# sudo reads secure_path, not the caller's PATH, so the checkout has to come
# first there too or `sudo omarchy-*` runs the packaged copy.
[[ $(<"$sudoers_file") == "Defaults secure_path=\"$checkout/bin:/usr/local/sbin:/usr/local/bin:/usr/bin\"" ]] ||
  fail "dev link prepends the checkout to sudo's secure_path" "$(<"$sudoers_file")"
pass "dev link prepends the checkout to sudo's secure_path"

grep -Eq $'^sudo\tinstall\t-Dm440\t-o\troot\t-g\troot\t[^\t]+\t/etc/sudoers\\.d/omarchy-dev-path$' "$log_file" ||
  fail "dev link installs the drop-in root-owned and read-only" "$(cat "$log_file")"
pass "dev link installs the drop-in root-owned and read-only"

visudo -cf "$sudoers_file" >/dev/null ||
  fail "dev link writes a sudoers drop-in sudo can parse" "$(<"$sudoers_file")"
pass "dev link writes a sudoers drop-in sudo can parse"

grep -F "sudo now resolves omarchy-* from $checkout/bin" "$test_tmp/link.out" >/dev/null ||
  fail "dev link reports the sudo change" "$(cat "$test_tmp/link.out")"
pass "dev link reports the sudo change"

if grep -Eq '^(gum|reboot)' "$log_file"; then
  fail "dev link --no-reboot skips the reboot prompt" "$(cat "$log_file")"
fi
pass "dev link --no-reboot skips the reboot prompt"

# A path sudoers would have to escape, not one the shell alone handles.
quoted_checkout=$(make_checkout 'check "out"')

: >"$log_file"
: >"$sudoers_file"
run_link "$quoted_checkout" --no-reboot >/dev/null

visudo -cf "$sudoers_file" >/dev/null ||
  fail "dev link escapes a checkout path for sudoers" "$(<"$sudoers_file")"
pass "dev link escapes a checkout path for sudoers"

# --no-sudo-path is the production posture: link the checkout without putting
# its user-writable bin/ on root's secure_path.
: >"$log_file"
echo 'stale development sudoers policy' >"$sudoers_file"
rm -f "$conf_file"
run_link "$checkout" --no-reboot --no-sudo-path >"$test_tmp/link-nosudo.out"

[[ $(<"$conf_file") == "export OMARCHY_PATH=\"$checkout\"" ]] ||
  fail "dev link --no-sudo-path still writes omarchy.conf" "$(<"$conf_file")"
[[ ! -e $sudoers_file ]] ||
  fail "dev link --no-sudo-path removes a stale sudoers drop-in" "$(<"$sudoers_file")"
if grep -q $'\tinstall\t' "$log_file"; then
  fail "dev link --no-sudo-path sudo-installs nothing" "$(cat "$log_file")"
fi
grep -Eq $'^sudo\trm\t-f\t/etc/sudoers\\.d/omarchy-dev-path$' "$log_file" ||
  fail "dev link --no-sudo-path removes the owned sudoers drop-in" "$(<"$log_file")"
if grep -F "sudo now resolves" "$test_tmp/link-nosudo.out" >/dev/null; then
  fail "dev link --no-sudo-path does not claim a sudo change" "$(cat "$test_tmp/link-nosudo.out")"
fi
grep -F "sudo secure_path does not include the checkout" "$test_tmp/link-nosudo.out" >/dev/null ||
  fail "dev link --no-sudo-path reports the production posture" "$(<"$test_tmp/link-nosudo.out")"
pass "dev link --no-sudo-path links without or removes the sudo secure_path policy"

: >"$log_file"
if run_link "$checkout" --bogus-flag >/dev/null 2>&1; then
  fail "dev link rejects an unknown flag"
fi
pass "dev link rejects an unknown flag"

: >"$log_file"
if run_link "$test_tmp/missing" --no-reboot >/dev/null 2>"$test_tmp/missing.err"; then
  fail "dev link rejects a path that does not exist"
fi
grep -F "Error: path does not exist: $test_tmp/missing" "$test_tmp/missing.err" >/dev/null ||
  fail "dev link explains a path that does not exist" "$(cat "$test_tmp/missing.err")"
if grep -q 'sudo' "$log_file"; then
  fail "dev link touches nothing when the path does not exist" "$(cat "$log_file")"
fi
pass "dev link rejects a path that does not exist"

printf 'OMARCHY_INSTALLATION=desktop_overlay\nOMARCHY_DESKTOP_STAGES=core,link\n' >"$descriptor"
: >"$log_file"
if OMARCHY_TEST_PRODUCT_INSTALLED=0 run_link "$checkout" --no-reboot >"$test_tmp/overlay.out" 2>"$test_tmp/overlay.err"; then
  fail "dev link accepts a registered desktop overlay"
fi
grep -q "omarchy overlay setup link" "$test_tmp/overlay.err" ||
  fail "dev link does not name the overlay-safe link repair" "$(<"$test_tmp/overlay.err")"
[[ ! -s $log_file ]] || fail "refused overlay dev link changes system state" "$(<"$log_file")"
pass "dev link refuses registered overlays without blocking product dev links"

printf 'not a valid installation descriptor\n' >"$descriptor"
: >"$log_file"
if OMARCHY_TEST_PRODUCT_INSTALLED=0 run_link "$checkout" --no-reboot >"$test_tmp/malformed.out" 2>"$test_tmp/malformed.err"; then
  fail "dev link accepts a malformed installation descriptor"
fi
grep -q 'must contain exactly one valid OMARCHY_INSTALLATION' "$test_tmp/malformed.err" ||
  fail "dev link hides the descriptor error that caused its refusal" "$(<"$test_tmp/malformed.err")"
[[ ! -s $log_file ]] || fail "malformed-descriptor dev link changes system state" "$(<"$log_file")"
pass "dev link fails closed when installation classification fails"

# SSH need not inherit the graphical session environment. Exercise successful
# writes, both with the packaged default and with only a configured checkout.
run_link_without_environment() {
  env -u OMARCHY_PATH \
    HOME="$test_tmp/home" \
    OMARCHY_INSTALLATION_CONF_PATH="$descriptor" \
    OMARCHY_RUNTIME_CONF_PATH="$conf_file" \
    OMARCHY_DEV_LINK_TEST_LOG="$log_file" \
    OMARCHY_DEV_LINK_TEST_CONF="$conf_file" \
    OMARCHY_DEV_LINK_TEST_SUDOERS="$sudoers_file" \
    PATH="$stub_bin:$PATH" \
    "$packaged_bin/omarchy-dev-link" "$checkout" --no-reboot \
    >"$test_tmp/nopath.out" 2>"$test_tmp/nopath.err"
}

assert_link_written() {
  [[ $(<"$conf_file") == "export OMARCHY_PATH=\"$checkout\"" ]] ||
    fail "dev link without OMARCHY_PATH did not update the runtime configuration"
  [[ -s $sudoers_file ]] || fail "dev link without OMARCHY_PATH did not install the sudoers policy"
  grep -q $'^sudo\ttee\t' "$log_file" || fail "dev link skipped the runtime writer"
  grep -q $'^sudo\tinstall\t' "$log_file" || fail "dev link skipped the sudoers writer"
}

rm -f "$descriptor" "$conf_file" "$sudoers_file"
: >"$log_file"
run_link_without_environment || fail "packaged dev link failed with OMARCHY_PATH unset" "$(<"$test_tmp/nopath.err")"
assert_link_written
pass "dev link uses the packaged helper and writes configuration without a session environment"

runtime_checkout="$test_tmp/runtime checkout"
mkdir -p "$runtime_checkout/install/helpers"
cp "$ROOT/install/helpers/runtime-link.sh" "$runtime_checkout/install/helpers/"
mv "$packaged_root/install/helpers/runtime-link.sh" "$packaged_root/install/helpers/runtime-link.saved"
printf 'export OMARCHY_PATH="%s"\n' "$runtime_checkout" >"$conf_file"
rm -f "$sudoers_file"
: >"$log_file"
run_link_without_environment || fail "dev link ignored the configured checkout without OMARCHY_PATH" "$(<"$test_tmp/nopath.err")"
assert_link_written
pass "dev link uses the configured checkout without a session environment or packaged helper"

printf 'export OMARCHY_PATH="/opt/omarchy\n' >"$conf_file"
: >"$log_file"
parse_status=0
run_link_without_environment || parse_status=$?
(( parse_status == 2 )) || fail "dev link does not preserve the configuration syntax-error status" "$parse_status"
[[ ! -s $log_file ]] || fail "dev link writes system files with an unbalanced quote in the runtime configuration"
grep -F "Error: could not load runtime configuration: $conf_file" "$test_tmp/nopath.err" >/dev/null ||
  fail "dev link does not explain its configuration parse failure" "$(<"$test_tmp/nopath.err")"
grep -Fx 'Repair or remove it, then retry.' "$test_tmp/nopath.err" >/dev/null ||
  fail "dev link does not explain how to recover from a configuration parse failure"
pass "dev link explains configuration syntax errors before privileged writes"

printf 'return 42\n' >"$conf_file"
: >"$log_file"
runtime_status=0
run_link_without_environment || runtime_status=$?
(( runtime_status == 42 )) || fail "dev link does not preserve a failing configuration's exit status" "$runtime_status"
[[ ! -s $log_file ]] || fail "dev link writes system files after failing to load its runtime configuration"
grep -F "Error: could not load runtime configuration: $conf_file" "$test_tmp/nopath.err" >/dev/null ||
  fail "dev link does not explain its runtime configuration load failure" "$(<"$test_tmp/nopath.err")"
grep -Fx 'Repair or remove it, then retry.' "$test_tmp/nopath.err" >/dev/null ||
  fail "dev link does not explain how to recover from a configuration load failure"
pass "dev link refuses a broken runtime configuration before privileged writes"

printf 'false\nexport OMARCHY_PATH="%s"\n' "$runtime_checkout" >"$conf_file"
: >"$log_file"
if run_link_without_environment; then
  fail "dev link suppresses errexit while loading its runtime configuration"
fi
[[ ! -s $log_file ]] || fail "dev link writes system files after a failed configuration command"
pass "dev link preserves errexit while loading its runtime configuration"

OMARCHY_DEV_LINK_COMMAND="$packaged_bin/omarchy-dev-link" \
  OMARCHY_TEST_RUNTIME_PATH="$runtime_checkout" \
  run_link "$checkout" --no-reboot >/dev/null
assert_link_written
pass "dev link keeps the active environment ahead of the configured runtime"

# A stale dev link must not prevent recovery through the packaged commands.
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
    rm -f "$sudoers_file"
    : >"$log_file"
    if [[ $origin == "config" ]]; then
      run_link_without_environment || fail "dev link cannot recover a $scenario checkout from config" "$(<"$test_tmp/nopath.err")"
    else
      OMARCHY_DEV_LINK_COMMAND="$packaged_bin/omarchy-dev-link" \
        OMARCHY_TEST_RUNTIME_PATH="$stale_checkout" \
        run_link "$checkout" --no-reboot >"$test_tmp/nopath.out" 2>"$test_tmp/nopath.err" ||
        fail "dev link cannot recover a $scenario checkout from the environment" "$(<"$test_tmp/nopath.err")"
    fi
    assert_link_written
    pass "dev link recovers a $scenario checkout from $origin through the packaged helper"
  done
done

mv "$packaged_root/install/helpers/runtime-link.sh" "$packaged_root/install/helpers/runtime-link.saved"
printf 'export OMARCHY_PATH="%s"\n' "$stale_checkout" >"$conf_file"
cp "$conf_file" "$test_tmp/conf-before-refusal"
: >"$log_file"
if run_link_without_environment; then
  fail "dev link accepts two unusable runtime helpers"
fi
for candidate in "$stale_checkout" "$packaged_root"; do
  grep -F "$candidate/install/helpers/runtime-link.sh" "$test_tmp/nopath.err" >/dev/null ||
    fail "dev link does not name both unusable helpers" "$(<"$test_tmp/nopath.err")"
done
[[ ! -s $log_file ]] || fail "dev link writes system files without a usable runtime helper"
cmp -s "$conf_file" "$test_tmp/conf-before-refusal" || fail "dev link changes the configuration when helper resolution fails"
pass "dev link names both unusable helpers and refuses before writing"

mv "$packaged_root/install/helpers/runtime-link.saved" "$packaged_root/install/helpers/runtime-link.sh"
for scenario in directory unreadable dangling-symlink; do
  bad_conf="$test_tmp/config-$scenario"
  case "$scenario" in
    directory) mkdir "$bad_conf" ;;
    unreadable) touch "$bad_conf"; chmod 000 "$bad_conf" ;;
    dangling-symlink) ln -s "$test_tmp/missing-config-target" "$bad_conf" ;;
  esac
  : >"$log_file"
  if conf_file="$bad_conf" run_link_without_environment; then
    fail "dev link ignores a $scenario runtime configuration"
  fi
  grep -F "Error: runtime configuration is not a readable regular file: $bad_conf" "$test_tmp/nopath.err" >/dev/null ||
    fail "dev link does not explain the $scenario configuration refusal" "$(<"$test_tmp/nopath.err")"
  grep -Fx 'Repair or remove it, then retry.' "$test_tmp/nopath.err" >/dev/null ||
    fail "dev link does not explain how to recover from a $scenario configuration"
  [[ ! -s $log_file ]] || fail "dev link writes system files with a $scenario runtime configuration"
  pass "dev link explains and refuses a $scenario configuration before writing"
done
