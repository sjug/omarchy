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
export TEST_QUERY_LOG="$test_tmp/query.log"

cat >"$stub_bin/pacman" <<'SH'
#!/bin/bash
[[ $1 == "-Qq" ]] || exit 1
printf '%s\n' "$*" >>"$TEST_QUERY_LOG"
shift
result=0
for requested in "$@"; do
  found=0
  for installed in ${TEST_INSTALLED_PACKAGES:-}; do
    if [[ $requested == "$installed" ]]; then
      echo "$installed"
      found=1
    fi
  done
  (( found )) || result=1
done
exit "$result"
SH
chmod +x "$stub_bin/pacman"

detect() {
  OMARCHY_INSTALLATION_CONF_PATH="$descriptor" \
    OMARCHY_RUNTIME_CONF_PATH="$runtime_conf" \
    OMARCHY_PATH="$test_tmp/checkout" \
    PATH="$stub_bin:$PATH" \
    "$ROOT/bin/omarchy-installation-type"
}

classify() {
  OMARCHY_INSTALLATION_CONF_PATH="$descriptor" \
    OMARCHY_RUNTIME_CONF_PATH="$runtime_conf" \
    OMARCHY_PATH="$test_tmp/checkout" \
    PATH="$stub_bin:$PATH" \
    "$ROOT/bin/omarchy-installation-type" --classify-only
}

rm -f "$descriptor" "$runtime_conf"
[[ $(TEST_INSTALLED_PACKAGES=omarchy detect) == "product" ]] || fail "legacy omarchy package is detected as a product install"
[[ $(TEST_INSTALLED_PACKAGES=omarchy-dev detect) == "product" ]] || fail "legacy omarchy-dev package is detected as a product install"
pass "product packages provide the compatibility installation-type fallback"

: >"$TEST_QUERY_LOG"
[[ $(TEST_INSTALLED_PACKAGES='omarchy-dev omarchy-settings' classify) == "product" ]] || fail "mixed batched results lose product precedence"
[[ $(<"$TEST_QUERY_LOG") == '-Qq omarchy omarchy-dev omarchy-settings omarchy-settings-dev' ]] || fail "detector does not use one package query"
pass "one batched query handles missing packages and preserves product precedence"

OMARCHY_INSTALLATION_CONF_PATH="$descriptor" bash "$ROOT/install/config/installation.sh"
[[ $(<"$descriptor") == "OMARCHY_INSTALLATION=product" ]] ||
  fail "product system setup does not write the canonical installation descriptor" "$(<"$descriptor")"
grep -F 'config/installation.sh' "$ROOT/install/config/all.sh" >/dev/null ||
  fail "product system setup does not run installation descriptor setup"
pass "fresh product setup writes its explicit installation type"

printf 'OMARCHY_INSTALLATION=product\n' >"$descriptor"
[[ $(TEST_INSTALLED_PACKAGES=omarchy detect) == "product" ]] || fail "an explicit product descriptor is accepted"
if TEST_INSTALLED_PACKAGES="" detect >"$test_tmp/out" 2>"$test_tmp/err"; then
  fail "a product descriptor without its product package is accepted"
fi
grep -q "neither omarchy nor omarchy-dev is installed" "$test_tmp/err" ||
  fail "a missing product package has a targeted remedy" "$(<"$test_tmp/err")"
grep -q 'omarchy-overlay-register --repair' "$test_tmp/err" ||
  fail "a stale product descriptor names the overlay repair path" "$(<"$test_tmp/err")"
pass "an explicit product descriptor requires its product package"

printf 'OMARCHY_INSTALLATION=desktop_overlay\nOMARCHY_DESKTOP_STAGES=core,link\n' >"$descriptor"
printf 'export OMARCHY_PATH="%s"\n' "$test_tmp/checkout" >"$runtime_conf"
[[ $(TEST_INSTALLED_PACKAGES="" detect) == "desktop_overlay" ]] || fail "a desktop-overlay descriptor is accepted"
printf 'export OMARCHY_PATH=/different/checkout\n' >"$runtime_conf"
if TEST_INSTALLED_PACKAGES="" detect >"$test_tmp/out" 2>"$test_tmp/err"; then
  fail "a stale session/check-out path mismatch is accepted"
fi
grep -q "does not match the desktop-overlay checkout" "$test_tmp/err" ||
  fail "a checkout mismatch identifies both sources of truth" "$(<"$test_tmp/err")"
[[ $(TEST_INSTALLED_PACKAGES="" classify) == "desktop_overlay" ]] ||
  fail "classification-only mode cannot identify a stale desktop overlay"
printf 'export OMARCHY_PATH="%s"\n' "$test_tmp/checkout" >"$runtime_conf"
pass "desktop-overlay detection binds runtime use while classification remains diagnostic"
for product_package in omarchy omarchy-dev omarchy-settings omarchy-settings-dev; do
  if TEST_INSTALLED_PACKAGES="$product_package" detect >"$test_tmp/out" 2>"$test_tmp/err"; then
    fail "desktop overlay is accepted with conflicting package $product_package"
  fi
  grep -q "product package $product_package is installed" "$test_tmp/err" ||
    fail "overlay conflict identifies $product_package" "$(<"$test_tmp/err")"
done
pass "desktop-overlay detection fails closed on every product-package conflict"

printf 'OMARCHY_INSTALLATION=desktop_overlay\nOMARCHY_INSTALLATION=product\n' >"$descriptor"
if TEST_INSTALLED_PACKAGES=omarchy detect >"$test_tmp/out" 2>"$test_tmp/err"; then
  fail "duplicate installation assignments are accepted"
fi
grep -q "exactly one valid OMARCHY_INSTALLATION" "$test_tmp/err" ||
  fail "duplicate assignments report an invalid descriptor" "$(<"$test_tmp/err")"

printf 'OMARCHY_INSTALLATION=future_shape\n' >"$descriptor"
if detect >"$test_tmp/out" 2>"$test_tmp/err"; then
  fail "an unknown installation type is accepted"
fi
grep -q "unsupported OMARCHY_INSTALLATION value 'future_shape'" "$test_tmp/err" ||
  fail "an unknown type is named in the error" "$(<"$test_tmp/err")"
grep -q 'omarchy-overlay-register --repair' "$test_tmp/err" ||
  fail "an invalid descriptor names its supported repair command" "$(<"$test_tmp/err")"
pass "malformed and unknown descriptors fail closed"

rm -f "$descriptor"
if TEST_INSTALLED_PACKAGES=omarchy-settings detect >"$test_tmp/out" 2>"$test_tmp/err"; then
  fail "a companion package alone is accepted as a product install"
fi
grep -q "installed without the omarchy or omarchy-dev product package" "$test_tmp/err" ||
  fail "a companion-only install gets a product repair" "$(<"$test_tmp/err")"
pass "a partial product install is distinguished from an overlay"

printf 'OMARCHY_PATH=/home/test/omarchy\n' >"$runtime_conf"
if TEST_INSTALLED_PACKAGES="" detect >"$test_tmp/out" 2>"$test_tmp/err"; then
  fail "an unregistered checkout is assigned an update path"
fi
grep -q "omarchy overlay register" "$test_tmp/err" || fail "unregistered checkout names overlay registration" "$(<"$test_tmp/err")"
grep -q '^  ./bin/omarchy-overlay-register core link config audio files connectivity capture power lock session-entry display-manager$' "$test_tmp/err" ||
  fail "unregistered checkout prints the complete adoption command" "$(<"$test_tmp/err")"
grep -q "omarchy upgrade to-quattro" "$test_tmp/err" || fail "unregistered checkout names the pre-quattro remedy" "$(<"$test_tmp/err")"
pass "an unregistered checkout fails closed with both applicable remediations"

[[ $(TEST_INSTALLED_PACKAGES="" classify) == "checkout_unregistered" ]] ||
  fail "classification-only detection cannot identify an unregistered checkout"
pass "classification-only detection exposes the read-only checkout fallback"

# Until the repeated type dispatch is centralized, keep its complete consumer
# inventory explicit. Adding another installation type requires auditing every
# entry here so no command can silently retain a product-only fallback.
expected_guarded_commands=(
  omarchy-channel-current
  omarchy-channel-set
  omarchy-dev-link
  omarchy-dev-unlink
  omarchy-migrate
  omarchy-overlay-migrate
  omarchy-overlay-stages
  omarchy-update
  omarchy-update-available
  omarchy-update-dev
  omarchy-update-overlay
  omarchy-version
  omarchy-version-channel
)
mapfile -t actual_guarded_commands < <(
  rg -l 'omarchy-installation-type' "$ROOT"/bin/omarchy-* |
    sed 's#.*/##' |
    grep -v '^omarchy-installation-type$' |
    sort
)
mapfile -t expected_guarded_commands < <(printf '%s\n' "${expected_guarded_commands[@]}" | sort)
[[ ${actual_guarded_commands[*]} == "${expected_guarded_commands[*]}" ]] ||
  fail "installation-type guard inventory drifted" "expected: ${expected_guarded_commands[*]}" "actual: ${actual_guarded_commands[*]}"
pass "every installation-type consumer is explicitly inventoried"
