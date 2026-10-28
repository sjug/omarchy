#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

template="$ROOT/default/snapper/root"
lvm_xfs_template="$ROOT/default/snapper/root-lvm-xfs"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

fake_bin="$test_tmp/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/snapper" <<'STUB'
#!/bin/bash
printf 'snapper %s\n' "$*" >>"$TEST_LOG"
STUB
chmod +x "$fake_bin/snapper"

cat >"$fake_bin/systemctl" <<'STUB'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$TEST_LOG"
STUB
chmod +x "$fake_bin/systemctl"

TEST_LOG="$test_tmp/calls.log" \
PATH="$fake_bin:$PATH" \
OMARCHY_SNAPPER_CONFIGURE_TEST=1 \
OMARCHY_PATH="$ROOT" \
OMARCHY_SNAPPER_CONFIG_PATH="$test_tmp/etc/snapper/configs/root" \
OMARCHY_SNAPPER_CONF_PATH="$test_tmp/etc/conf.d/snapper" \
  bash -euo pipefail "$ROOT/install/config/snapper.sh" >/dev/null

cmp -s "$template" "$test_tmp/etc/snapper/configs/root" || fail "snapshot configure installs the Omarchy Snapper template"
grep -Fx 'SNAPPER_CONFIGS="root"' "$test_tmp/etc/conf.d/snapper" >/dev/null || fail "snapshot configure writes /etc/conf.d/snapper"
grep -Fx 'systemctl disable --now snapper-timeline.timer' "$test_tmp/calls.log" >/dev/null || fail "snapshot configure disables timeline snapshots"
grep -Fx 'systemctl enable --now snapper-cleanup.timer limine-snapper-sync.service' "$test_tmp/calls.log" >/dev/null || fail "snapshot configure enables cleanup and Limine snapshot sync"
pass "snapshot configure normalizes Snapper policy and services"

: >"$test_tmp/calls.log"

TEST_LOG="$test_tmp/calls.log" \
PATH="$fake_bin:$PATH" \
OMARCHY_PATH="$ROOT" \
OMARCHY_SNAPPER_BACKEND=lvm_xfs \
OMARCHY_SNAPPER_CONFIG_PATH="$test_tmp/etc/snapper/configs/root-lvm-xfs" \
OMARCHY_SNAPPER_CONF_PATH="$test_tmp/etc/conf.d/snapper-lvm-xfs" \
  bash -euo pipefail "$ROOT/install/config/snapper.sh" >/dev/null

cmp -s "$lvm_xfs_template" "$test_tmp/etc/snapper/configs/root-lvm-xfs" || fail "LVM/XFS snapshot configure installs the LVM/XFS template"
grep -Fx 'snapper --no-dbus -c root create-config --fstype=lvm(xfs) /' "$test_tmp/calls.log" >/dev/null || fail "LVM/XFS snapshot configure selects Snapper's thin-LVM XFS backend"
grep -Fx 'systemctl disable --now limine-snapper-sync.service limine-snapper-sync.path' "$test_tmp/calls.log" >/dev/null || fail "LVM/XFS snapshot configure disables the Btrfs Limine sync"
grep -Fx 'systemctl enable --now snapper-cleanup.timer' "$test_tmp/calls.log" >/dev/null || fail "LVM/XFS snapshot configure enables cleanup"
pass "snapshot configure uses Snapper's LVM/XFS backend without Btrfs boot sync"

snapshot_command="$ROOT/bin/omarchy-snapshot"
storage_conf="$test_tmp/storage.conf"
printf 'OMARCHY_STORAGE_BACKEND=lvm_xfs\n' >"$storage_conf"

if snapshot_output=$(
  PATH="$fake_bin:$ROOT/bin:$PATH" \
  OMARCHY_STORAGE_CONF_PATH="$storage_conf" \
    "$snapshot_command" restore 2>&1
); then
  fail "LVM/XFS snapshot restore guard returns success"
else
  snapshot_status=$?
fi
((snapshot_status == 2)) || fail "LVM/XFS snapshot restore guard returns status 2"
[[ $snapshot_output == *"LVM/XFS restore is not available"* ]] || fail "LVM/XFS snapshot restore guard explains the boundary"
pass "snapshot restore stops before the Btrfs restore command on LVM/XFS"

hibernation_command="$ROOT/bin/omarchy-hibernation-setup"
if hibernation_output=$(
  OMARCHY_STORAGE_CONF_PATH="$storage_conf" \
    "$hibernation_command" --force --no-rebuild 2>&1
); then
  fail "LVM/XFS hibernation guard returns success"
else
  hibernation_status=$?
fi
((hibernation_status == 2)) || fail "LVM/XFS hibernation guard returns status 2"
[[ $hibernation_output == *"zram without disk-backed swap"* ]] || fail "LVM/XFS hibernation guard explains the zram-only policy"
pass "hibernation setup stops before Btrfs operations on LVM/XFS"

cat >"$fake_bin/sudo" <<'STUB'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$TEST_LOG"
STUB
chmod +x "$fake_bin/sudo"

: >"$test_tmp/calls.log"
refresh_output=$(
  TEST_LOG="$test_tmp/calls.log" \
  PATH="$fake_bin:$PATH" \
  OMARCHY_PATH="$ROOT" \
  OMARCHY_STORAGE_CONF_PATH="$storage_conf" \
    "$ROOT/bin/omarchy-refresh-limine"
)
grep -Fx 'sudo limine-update' "$test_tmp/calls.log" >/dev/null || fail "Limine refresh still updates the bootloader on LVM/XFS"
! grep -F 'limine-snapper-sync' "$test_tmp/calls.log" >/dev/null || fail "Limine refresh invokes Btrfs snapshot sync on LVM/XFS"
[[ $refresh_output == *"Skipping Btrfs snapshot-menu sync"* ]] || fail "Limine refresh reports the skipped Btrfs snapshot sync"
pass "Limine refresh skips only the Btrfs snapshot-menu sync on LVM/XFS"
