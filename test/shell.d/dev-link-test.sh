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
cp "$ROOT/bin/omarchy-dev-link" "$packaged_bin/"
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
