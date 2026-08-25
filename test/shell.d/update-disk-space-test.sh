#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

unset GUM_STATUS
unset OMARCHY_UPDATE_FORCE
unset TEST_AVAILABLE_BYTES
unset TEST_DF_INVALID

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
test_home="$test_tmp/home"
runtime_dir="$test_tmp/runtime"
snapshot_marker="$test_tmp/snapshot"
gum_marker="$test_tmp/gum"
pkg_prune_marker="$test_tmp/pkg-prune"
storage_conf="$test_tmp/storage.conf"
sudo_marker="$test_tmp/sudo"
lvs_marker="$test_tmp/lvs"
mkdir -p "$stub_bin" "$test_home" "$runtime_dir"

run_update() {
  HOME="$test_home" \
  XDG_RUNTIME_DIR="$runtime_dir" \
  PATH="$stub_bin:$ROOT/bin:$PATH" \
  LC_ALL=C \
  OMARCHY_UPDATE_LOGGED=1 \
  OMARCHY_STORAGE_CONF_PATH="$storage_conf" \
  TEST_AVAILABLE_BYTES=${TEST_AVAILABLE_BYTES:-$((9 * 1024 * 1024 * 1024))} \
  TEST_DF_INVALID=${TEST_DF_INVALID:-0} \
  TEST_DATA_PERCENT=${TEST_DATA_PERCENT:-20.00} \
  TEST_METADATA_PERCENT=${TEST_METADATA_PERCENT:-10.00} \
  TEST_LVS_FAIL=${TEST_LVS_FAIL:-0} \
  TEST_LVS_MALFORMED=${TEST_LVS_MALFORMED:-0} \
  SNAPSHOT_MARKER="$snapshot_marker" \
  GUM_MARKER="$gum_marker" \
  PKG_PRUNE_MARKER="$pkg_prune_marker" \
  SUDO_MARKER="$sudo_marker" \
  LVS_MARKER="$lvs_marker" \
  GUM_STATUS=${GUM_STATUS:-1} \
    "$ROOT/bin/omarchy-update" "$@"
}

run_requirement_check() {
  PATH="$stub_bin:$ROOT/bin:$PATH" \
  LC_ALL=C \
  OMARCHY_STORAGE_CONF_PATH="$storage_conf" \
  TEST_AVAILABLE_BYTES=${TEST_AVAILABLE_BYTES:-$((20 * 1024 * 1024 * 1024))} \
  TEST_DF_INVALID=${TEST_DF_INVALID:-0} \
  TEST_DATA_PERCENT=${TEST_DATA_PERCENT:-20.00} \
  TEST_METADATA_PERCENT=${TEST_METADATA_PERCENT:-10.00} \
  TEST_LVS_FAIL=${TEST_LVS_FAIL:-0} \
  TEST_LVS_MALFORMED=${TEST_LVS_MALFORMED:-0} \
  SUDO_MARKER="$sudo_marker" \
  LVS_MARKER="$lvs_marker" \
    "$ROOT/bin/omarchy-update-requires-free-space"
}

write_storage_conf() {
  local backend="$1"

  printf 'OMARCHY_STORAGE_BACKEND=%s\nOMARCHY_STORAGE_VG=omarchy\nOMARCHY_STORAGE_ROOT_POOL=root-pool\n' "$backend" >"$storage_conf"
}

write_stub() {
  local name="$1"
  local body="$2"

  cat >"$stub_bin/$name" <<SH
#!/bin/bash
$body
SH
  chmod +x "$stub_bin/$name"
}

write_stub df '
if (( TEST_DF_INVALID )); then
  printf "Avail\nunknown\n"
else
  printf "Avail\n%s\n" "$TEST_AVAILABLE_BYTES"
fi'

write_stub gum '
printf "%s\n" "$*" >>"$GUM_MARKER"
if [[ ${1:-} == "confirm" ]]; then
  exit "$GUM_STATUS"
fi
exit 0'

write_stub omarchy-snapshot '
touch "$SNAPSHOT_MARKER"
exit 0'

write_stub sudo '
printf "%s\n" "$*" >>"$SUDO_MARKER"
exec "$@"'

write_stub lvs '
printf "%s|%s\n" "$LC_ALL" "$*" >>"$LVS_MARKER"
(( TEST_LVS_FAIL == 0 )) || exit 5
if (( TEST_LVS_MALFORMED )); then
  printf "unknown values\n"
else
  printf "  %s  %s  \n" "$TEST_DATA_PERCENT" "$TEST_METADATA_PERCENT"
fi'

write_stub omarchy-update-pkg-prune '
touch "$PKG_PRUNE_MARKER"
exit 0'

for command in \
  omarchy-cmd-present \
  omarchy-toggle-idle \
  pkexec \
  systemd-inhibit \
  omarchy-update-dev \
  omarchy-update-keyring \
  omarchy-update-system-pkgs \
  omarchy-migrate \
  omarchy-update-aur-pkgs \
  omarchy-update-mise \
  omarchy-update-orphan-pkgs \
  omarchy-hook \
  omarchy-update-analyze-logs \
  omarchy-shell \
  omarchy-update-restart; do
  write_stub "$command" 'exit 0'
done
write_stub omarchy-update-available 'exit 1'
write_stub pkexec 'exec "$@"'

set +e
TEST_AVAILABLE_BYTES=$((9 * 1024 * 1024 * 1024)) \
  run_requirement_check >/dev/null
status=$?
set -e
(( status == 1 )) || fail "free-space helper exits non-zero when disk space is low"
pass "free-space helper reports low disk space through its exit status"

set +e
output=$(run_update -y)
status=$?
set -e
(( status == 1 )) || fail "non-interactive update exits non-zero with low disk space"
[[ $output == *"You need at least 10 GiB free to safely update Omarchy."* ]] || fail "low disk space emits a warning"
[[ ! -f $gum_marker ]] || fail "non-interactive update does not prompt for low disk space"
[[ ! -f $snapshot_marker ]] || fail "non-interactive update stops before snapshotting with low disk space"
pass "non-interactive update stops with low disk space"

rm -f "$snapshot_marker" "$gum_marker"
set +e
output=$(run_update)
status=$?
set -e
(( status == 1 )) || fail "interactive update exits non-zero with low disk space"
[[ $output == *"You need at least 10 GiB free to safely update Omarchy."* ]] || fail "interactive low-space update explains the requirement"
[[ ! -f $gum_marker ]] || fail "interactive update stops before confirmation with low disk space"
[[ ! -f $snapshot_marker ]] || fail "interactive update stops before snapshotting with low disk space"
pass "interactive update stops before confirmation with low disk space"

rm -f "$snapshot_marker" "$gum_marker"
output=$(OMARCHY_UPDATE_FORCE=1 run_update -y)
[[ -z $output ]] || fail "forced update does not emit the free-space warning"
[[ ! -f $gum_marker ]] || fail "forced non-interactive update does not prompt"
[[ -f $snapshot_marker ]] || fail "forced update continues with low disk space"
pass "forced update skips the free-space requirement"

rm -f "$snapshot_marker" "$gum_marker"
output=$(TEST_AVAILABLE_BYTES=$((10 * 1024 * 1024 * 1024)) run_update -y)
[[ $output != *"You need at least 10 GiB free"* ]] || fail "space equal to the threshold does not produce a warning"
[[ -f $snapshot_marker ]] || fail "space equal to the threshold allows the update"
pass "disk-space threshold includes the exact boundary"

rm -f "$snapshot_marker" "$gum_marker"
GUM_STATUS=0 TEST_AVAILABLE_BYTES=$((10 * 1024 * 1024 * 1024)) run_update >/dev/null
grep -q "confirm Continue with update?" "$gum_marker" ||
  fail "interactive update with enough space uses the normal confirmation prompt"
[[ -f $snapshot_marker ]] || fail "accepting the normal confirmation starts the update"
pass "interactive update keeps the normal confirmation prompt when space is sufficient"

rm -f "$snapshot_marker"
output=$(TEST_DF_INVALID=1 run_update -y)
[[ -z $output ]] || fail "failed disk-space detection remains silent"
[[ -f $snapshot_marker ]] || fail "failed disk-space detection does not block the update"
pass "failed disk-space detection silently continues"

rm -f "$sudo_marker" "$lvs_marker"
write_storage_conf btrfs
TEST_LVS_FAIL=1 run_requirement_check >/dev/null
[[ ! -f $sudo_marker && ! -f $lvs_marker ]] || fail "Btrfs storage does not query LVM pool health"
pass "Btrfs storage skips the LVM thin-pool gate"

write_storage_conf lvm_xfs
rm -f "$sudo_marker" "$lvs_marker"
TEST_DATA_PERCENT=79.99 TEST_METADATA_PERCENT=69.99 run_requirement_check >/dev/null
grep -qx 'env LC_ALL=C lvs --noheadings -o data_percent,metadata_percent omarchy/root-pool' "$sudo_marker" ||
  fail "thin-pool health runs lvs through sudo with an explicit C locale"
grep -qx 'C|--noheadings -o data_percent,metadata_percent omarchy/root-pool' "$lvs_marker" ||
  fail "thin-pool health requests both padded percentage fields from the configured pool"
pass "LVM/XFS pool usage below both boundaries allows the update"

set +e
output=$(TEST_DATA_PERCENT=80.00 TEST_METADATA_PERCENT=69.99 run_requirement_check)
status=$?
set -e
(( status == 1 )) || fail "Data usage at 80 percent blocks the update"
[[ $output == *"80.00% data usage (safety limit: 80%)"* ]] || fail "Data boundary reports the measured usage and limit"
[[ $output == *"Retry in a minute; if this persists, the pool can no longer grow."* ]] || fail "Data boundary explains the autoextend race and persistent failure"
[[ $output != *"metadata usage"* ]] || fail "Data boundary does not misreport metadata pressure"
pass "Data usage is gated independently at 80 percent"

set +e
output=$(TEST_DATA_PERCENT=79.99 TEST_METADATA_PERCENT=70.00 run_requirement_check)
status=$?
set -e
(( status == 1 )) || fail "metadata usage at 70 percent blocks the update"
[[ $output == *"70.00% metadata usage (safety limit: 70%)"* ]] || fail "metadata boundary reports the measured usage and limit"
[[ $output == *"metadata must be extended or repaired before updating"* ]] || fail "metadata boundary explains the required recovery"
[[ $output != *"% data usage (safety limit: 80%)"* ]] || fail "metadata boundary does not misreport data pressure"
pass "metadata usage is gated independently at 70 percent"

set +e
output=$(TEST_LVS_FAIL=1 run_requirement_check)
status=$?
set -e
(( status == 1 )) || fail "an unqueryable LVM/XFS pool fails closed"
[[ $output == *"cannot verify the LVM root thin-pool health"* ]] || fail "failed pool query explains why the update stopped"
[[ $output == *"OMARCHY_UPDATE_FORCE=1"* ]] || fail "failed pool query names the emergency bypass"
pass "LVM/XFS pool query failure stops with recovery guidance"

set +e
output=$(TEST_LVS_MALFORMED=1 run_requirement_check)
status=$?
set -e
(( status == 1 )) || fail "malformed LVM/XFS pool percentages fail closed"
[[ $output == *"cannot verify the LVM root thin-pool health"* ]] || fail "malformed pool output reports the verification failure"
pass "invalid LVM percentage output fails closed"

rm -f "$sudo_marker" "$lvs_marker"
OMARCHY_UPDATE_FORCE=1 TEST_LVS_FAIL=1 run_requirement_check >/dev/null
[[ ! -f $sudo_marker && ! -f $lvs_marker ]] || fail "forced update bypasses the LVM query"
pass "OMARCHY_UPDATE_FORCE bypasses thin-pool health checks"

rm -f "$snapshot_marker" "$pkg_prune_marker" "$gum_marker"
set +e
output=$(TEST_AVAILABLE_BYTES=$((20 * 1024 * 1024 * 1024)) TEST_DATA_PERCENT=80.00 TEST_METADATA_PERCENT=20.00 run_update -y)
status=$?
set -e
(( status == 1 )) || fail "unsafe thin-pool usage stops the update pipeline"
[[ ! -f $gum_marker ]] || fail "unsafe thin-pool usage stops before update confirmation"
[[ ! -f $pkg_prune_marker ]] || fail "unsafe thin-pool usage stops before package-cache pruning"
[[ ! -f $snapshot_marker ]] || fail "unsafe thin-pool usage stops before snapshotting"
pass "thin-pool health is gated before update churn"
