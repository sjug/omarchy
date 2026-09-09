#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"

# The edge channel installs omarchy-dev. Older builds did not declare
# provides=(omarchy), so a query for plain omarchy finds nothing there.
cat >"$stub_bin/pacman" <<'STUB'
#!/bin/bash
[[ $1 == "-Q" ]] || exit 1
shift
for package in "$@"; do
  case ",${OMARCHY_TEST_PACKAGES:-}," in
    *",$package,"*)
      echo "$package ${OMARCHY_TEST_VERSION:-4.0.0-1}"
      exit 0
      ;;
  esac
done
echo "error: package '$1' was not found" >&2
exit 1
STUB
chmod +x "$stub_bin/pacman"

cat >"$stub_bin/omarchy-installation-type" <<'STUB'
#!/bin/bash
echo "${OMARCHY_TEST_INSTALLATION_TYPE:-product}"
STUB
chmod +x "$stub_bin/omarchy-installation-type"

cat >"$stub_bin/omarchy-overlay-stages" <<'STUB'
#!/bin/bash
[[ ${OMARCHY_TEST_STAGE_STATUS:-0} == "0" ]] || {
  echo "invalid overlay stage ledger" >&2
  exit "$OMARCHY_TEST_STAGE_STATUS"
}
echo core
STUB
chmod +x "$stub_bin/omarchy-overlay-stages"

version() {
  OMARCHY_TEST_PACKAGES="$1" \
    OMARCHY_PATH="${2:-/usr/share/omarchy}" \
    OMARCHY_TEST_INSTALLATION_TYPE="${3:-product}" \
    PATH="$stub_bin:$PATH" \
    "$ROOT/bin/omarchy-version"
}

[[ $(version omarchy) == "4.0.0-1" ]] || fail "version reports the stable package"
pass "version reports the stable package"

[[ $(version omarchy-dev) == "4.0.0-1" ]] || fail "version reports the edge package"
pass "version reports the edge package"

# A checkout reports its hash instead, so packages are irrelevant there.
[[ $(version "" "$test_tmp/checkout") == "dev" ]] || fail "version reports a dev checkout"
pass "version reports a dev checkout"

[[ $(version "" "$test_tmp/checkout" desktop_overlay) == "desktop overlay" ]] || fail "version identifies a desktop-overlay checkout"
pass "version distinguishes a desktop overlay from a product dev checkout"

overlay_version=$(
  OMARCHY_TEST_INSTALLATION_TYPE=desktop_overlay \
    OMARCHY_TEST_STAGE_STATUS=1 \
    OMARCHY_PATH="$test_tmp/checkout" \
    PATH="$stub_bin:$PATH" \
    "$ROOT/bin/omarchy-version"
)
[[ $overlay_version == "desktop overlay" ]] ||
  fail "read-only version depends on the owner-scoped stage reader" "$overlay_version"
overlay_channel=$(
  OMARCHY_TEST_INSTALLATION_TYPE=desktop_overlay \
    OMARCHY_TEST_STAGE_STATUS=1 \
    OMARCHY_PATH="$test_tmp/checkout" \
    PATH="$stub_bin:$PATH" \
    "$ROOT/bin/omarchy-version-channel"
)
[[ $overlay_channel == "desktop-overlay" ]] ||
  fail "read-only channel depends on the owner-scoped stage reader" "$overlay_channel"
pass "read-only overlay version and channel do not require ledger ownership"

cat >"$stub_bin/git" <<'STUB'
#!/bin/bash
if [[ $1 == "-C" && $3 == "rev-parse" && $4 == "--short" && $5 == "HEAD" ]]; then
  echo deadbee
else
  exit 1
fi
STUB
chmod +x "$stub_bin/git"

[[ $(version "" "$test_tmp/checkout" checkout_unregistered) == "dev (deadbee)" ]] ||
  fail "unregistered checkout version loses the pre-registration dev fallback"
pass "unregistered checkout version keeps the read-only dev fallback"

unregistered_version_channel=$(
  OMARCHY_TEST_INSTALLATION_TYPE=checkout_unregistered \
    OMARCHY_PATH="$test_tmp/checkout" \
    PATH="$stub_bin:$PATH" \
    "$ROOT/bin/omarchy-version-channel"
)
[[ $unregistered_version_channel == "dev" ]] ||
  fail "unregistered checkout channel loses the pre-registration fallback" "$unregistered_version_channel"
pass "unregistered checkout channel keeps the read-only dev fallback"

runtime_conf="$test_tmp/omarchy.conf"
printf 'export OMARCHY_PATH=%q\n' "$test_tmp/checkout" >"$runtime_conf"
outside_session_version=$(
  env -u OMARCHY_PATH \
    OMARCHY_RUNTIME_CONF_PATH="$runtime_conf" \
    OMARCHY_TEST_INSTALLATION_TYPE=desktop_overlay \
    PATH="$stub_bin:$PATH" \
    "$ROOT/bin/omarchy-version"
)
[[ $outside_session_version == "desktop overlay (deadbee)" ]] ||
  fail "read-only overlay version requires an active graphical session" "$outside_session_version"
pass "read-only overlay version resolves the registered checkout outside a session"

if version "" >/dev/null 2>&1; then
  fail "version fails when no Omarchy package is installed"
fi
pass "version fails when no Omarchy package is installed"

# The snapshot description is only a label, so a failed lookup must not abort
# the update under set -e.
snapshot_desc=$(
  set -e
  PATH="$stub_bin:$PATH" OMARCHY_TEST_PACKAGES="" OMARCHY_PATH=/usr/share/omarchy \
    bash -c 'DESC="$(omarchy-version 2>/dev/null || echo unknown)"; echo "$DESC"' 2>/dev/null
) || fail "snapshot survives an unknown version"

[[ $snapshot_desc == "unknown" ]] || fail "snapshot labels an unknown version" "actual: $snapshot_desc"
pass "snapshot survives an unknown version"
