#!/bin/bash
# The desktop-overlay migrations that mirror the product's Omasnap, OWE,
# Elsewhen, and mise PATH changes only do user-side wiring: packages come from
# the desktop manifest's package transaction, so each migration must fail
# loudly when its package is absent and must never install anything itself.

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

migrations="$ROOT/migrations/desktop-overlay"
omasnap_migration="$migrations/1790272914.sh"
owe_migration="$migrations/1790272915.sh"
elsewhen_migration="$migrations/1790272916.sh"
mise_migration="$migrations/1790272917.sh"

test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/bin" "$test_dir/home"
export CALL_LOG="$test_dir/calls"

for stub in omarchy-pkg-add omarchy-pkg-drop omarchy-hook-install omarchy-shell omarchy-bar systemctl omasnap; do
  cat >"$test_dir/bin/$stub" <<SH
#!/bin/bash
echo "$stub \$*" >>"\$CALL_LOG"
SH
done
cat >"$test_dir/bin/omarchy-pkg-present" <<'SH'
#!/bin/bash
[[ -n ${TEST_PRESENT_PACKAGES:-} ]] && grep -qx "$1" <<<"$TEST_PRESENT_PACKAGES"
SH
cat >"$test_dir/bin/omarchy-cmd-present" <<'SH'
#!/bin/bash
[[ ${TEST_MISE_PRESENT:-0} == 1 ]]
SH
cat >"$test_dir/bin/omarchy-overlay-stages" <<'SH'
#!/bin/bash
(( ${TEST_STAGES_STATUS:-0} == 0 )) || exit "$TEST_STAGES_STATUS"
printf '%s\n' "${TEST_STAGES:-core link config capture}" | tr ' ' '\n'
SH
chmod +x "$test_dir/bin/"*

# A PATH with only the tools the migrations use, so "command not found" cases
# do not depend on what the host has installed.
mkdir -p "$test_dir/tools"
for tool in grep sed mv rm ln mkdir readlink date tr printf; do
  ln -s "$(command -v "$tool")" "$test_dir/tools/$tool"
done

# Migrations run under the runner's strict mode; keep the same flags here.
run_migration() {
  : >"$CALL_LOG"
  HOME="$test_dir/home" OMARCHY_PATH="${OMARCHY_PATH_OVERRIDE:-$ROOT}" PATH="${TEST_PATH:-$test_dir/bin:$ROOT/bin:$PATH}" \
    "$BASH" -euo pipefail "$@"
}

for migration in "$omasnap_migration" "$owe_migration" "$elsewhen_migration" "$mise_migration"; do
  ! grep -Eq '^[[:space:]]*(omarchy-pkg-(add|drop)|(sudo )?pacman)( |$)' "$migration" ||
    fail "overlay migrations never install or remove packages themselves" "$migration"
done
pass "overlay migrations leave package installation and removal to the desktop manifest"

# --- Omasnap -------------------------------------------------------------
imv_config="$test_dir/home/.config/imv/config"
launcher="$test_dir/home/.local/share/applications/omasnap.desktop"
legacy_binding='<Ctrl+e> = exec tensaku-edit "$imv_current_file" & ; quit'
new_binding='<Ctrl+e> = exec omasnap "$imv_current_file" & ; quit'
write_legacy_imv() {
  mkdir -p "${imv_config%/*}"
  printf '[binds]\n# Edit the current image in Tensaku and quit the viewer\n%s\n' "$legacy_binding" >"$imv_config"
}

write_legacy_imv
TEST_STAGES="core link config" run_migration "$omasnap_migration" >"$test_dir/out" ||
  fail "the Omasnap migration succeeds when capture was never adopted"
grep -qxF "$legacy_binding" "$imv_config" || fail "an overlay without the capture stage keeps its image editor binding"
pass "the Omasnap migration leaves an overlay without the capture stage untouched"

if TEST_STAGES="" TEST_STAGES_STATUS=42 run_migration "$omasnap_migration" >"$test_dir/out" 2>"$test_dir/err"; then
  fail "an unreadable stage ledger must fail the Omasnap migration, not read as capture absent"
fi
grep -qxF "$legacy_binding" "$imv_config" || fail "a failed stage lookup leaves the imv binding untouched"
pass "the Omasnap migration fails when the stage ledger cannot be read"

mkdir -p "$test_dir/bin-without-omasnap"
for stub in omarchy-overlay-stages omarchy-pkg-present; do
  ln -sf "$test_dir/bin/$stub" "$test_dir/bin-without-omasnap/$stub"
done
if TEST_PATH="$test_dir/bin-without-omasnap:$test_dir/tools" run_migration "$omasnap_migration" >"$test_dir/out" 2>"$test_dir/err"; then
  fail "the Omasnap migration must fail when capture is recorded but omasnap is missing"
fi
grep -q 'omarchy overlay setup packages capture' "$test_dir/err" ||
  fail "the Omasnap migration names the capture repair command" "$(cat "$test_dir/err")"
grep -qxF "$legacy_binding" "$imv_config" || fail "a missing omasnap leaves the imv binding untouched"
pass "the Omasnap migration stays pending until omasnap is installed"

mkdir -p "${launcher%/*}"
printf '[Desktop Entry]\nNoDisplay=true\n' >"$launcher"
TEST_PRESENT_PACKAGES=$'satty\ntensaku' run_migration "$omasnap_migration" >"$test_dir/out" ||
  fail "the Omasnap migration succeeds with the legacy imv config"
grep -qxF "$new_binding" "$imv_config" || fail "the imv edit binding is repointed at omasnap" "$(cat "$imv_config")"
grep -qx '# Edit the current image in Omasnap and quit the viewer' "$imv_config" || fail "the imv edit comment names Omasnap"
[[ ! -e $launcher ]] || fail "the legacy NoDisplay launcher override is moved aside"
backups=("$launcher".bak.*)
[[ -f ${backups[0]} ]] && grep -qx 'NoDisplay=true' "${backups[0]}" || fail "the hidden launcher is kept as an announced backup"
grep -q "${backups[0]}" "$test_dir/out" || fail "the migration announces where the hidden launcher went" "$(cat "$test_dir/out")"
rm -f "$launcher".bak.*
grep -q 'omarchy-pkg-drop satty tensaku' "$test_dir/out" ||
  fail "the Omasnap migration advises the removal of satty and tensaku" "$(cat "$test_dir/out")"
[[ ! -s $CALL_LOG ]] || fail "the Omasnap migration calls no helper that changes the system" "$(cat "$CALL_LOG")"
pass "the Omasnap migration rewires imv and only advises package removal"

printf '[Desktop Entry]\nName=My Omasnap\nExec=omasnap --custom\n' >"$launcher"
run_migration "$omasnap_migration" >"$test_dir/out" || fail "the Omasnap migration reruns cleanly"
{ [[ -f $launcher ]] && grep -qx 'Exec=omasnap --custom' "$launcher"; } || fail "a user-written visible launcher is preserved in place"
printf '[Desktop Entry]\nName=My hidden Omasnap\nExec=omasnap --custom\nNoDisplay=true\n' >"$launcher"
run_migration "$omasnap_migration" >"$test_dir/out" || fail "a customised hidden launcher does not stop the migration"
backups=("$launcher".bak.*)
{ [[ ! -e $launcher && -f ${backups[0]} ]] && grep -qx 'Exec=omasnap --custom' "${backups[0]}"; } ||
  fail "a customised hidden launcher is moved aside with its contents intact"
rm -f "$launcher".bak.*
grep -qxF "$new_binding" "$imv_config" || fail "a rerun keeps the omasnap binding"
! grep -q 'omarchy-pkg-drop' "$test_dir/out" || fail "no removal advice without satty or tensaku"
pass "the Omasnap migration preserves a customised launcher and is idempotent"

rm -f "$imv_config"
run_migration "$omasnap_migration" >"$test_dir/out" || fail "the Omasnap migration tolerates a missing imv config"
pass "the Omasnap migration is quiet on a host without an imv config"

# --- OWE -----------------------------------------------------------------
# The hook path and unit path are package-owned; rewrite them into the test
# tree the way the product Elsewhen test does.
owe_root="$test_dir/owe"
mkdir -p "$owe_root/share" "$owe_root/units" "$test_dir/home/.config/systemd/user"
sed -e "s|/usr/share/owe|$owe_root/share|g" -e "s|/usr/lib/systemd/user|$owe_root/units|g" \
  "$owe_migration" >"$test_dir/owe-migration.sh"

if run_migration "$test_dir/owe-migration.sh" >"$test_dir/out" 2>"$test_dir/err"; then
  fail "the OWE migration must fail when owe is not installed"
fi
grep -q 'omarchy overlay setup packages core' "$test_dir/err" ||
  fail "the OWE migration names the repair command" "$(cat "$test_dir/err")"
[[ ! -s $CALL_LOG ]] || fail "the OWE migration touches nothing without its package" "$(cat "$CALL_LOG")"
pass "the OWE migration stays pending until owe is installed"

printf '#!/bin/bash\n' >"$owe_root/share/10-owe-sync"
chmod +x "$owe_root/share/10-owe-sync"
touch "$owe_root/units/owed.service"
cat >"$test_dir/bin/systemctl" <<'SH'
#!/bin/bash
echo "systemctl $*" >>"$CALL_LOG"
case "$*" in
  "--user enable owed.service") exit "${TEST_ENABLE_STATUS:-0}" ;;
  "--user is-active --quiet graphical-session.target") exit "${TEST_SESSION_STATUS:-1}" ;;
esac
SH
run_migration "$test_dir/owe-migration.sh" >"$test_dir/out" || fail "the OWE migration succeeds once owe is installed"
grep -qx "omarchy-hook-install theme-set $owe_root/share/10-owe-sync" "$CALL_LOG" ||
  fail "the OWE migration registers the theme-set hook" "$(cat "$CALL_LOG")"
grep -qx 'systemctl --user enable owed.service' "$CALL_LOG" || fail "the OWE migration enables owed.service"
! grep -q 'systemctl --user start owed.service' "$CALL_LOG" || fail "a TTY update does not start the renderer"
pass "the OWE migration registers the hook and enables the renderer for the next login"

TEST_SESSION_STATUS=0 run_migration "$test_dir/owe-migration.sh" >"$test_dir/out" || fail "the OWE migration reruns cleanly"
grep -qx 'systemctl --user start owed.service' "$CALL_LOG" || fail "a live session starts the renderer" "$(cat "$CALL_LOG")"
pass "the OWE migration starts the renderer inside a graphical session and is idempotent"

TEST_ENABLE_STATUS=1 run_migration "$test_dir/owe-migration.sh" >"$test_dir/out" || fail "an enable failure falls back to a wants link"
[[ $(readlink "$test_dir/home/.config/systemd/user/graphical-session.target.wants/owed.service") == "$owe_root/units/owed.service" ]] ||
  fail "the fallback links owed.service into graphical-session.target.wants"
pass "the OWE migration falls back to a manual wants link when enable fails"

# --- Elsewhen ------------------------------------------------------------
packaged_root="$test_dir/packaged"
sed "s|/usr/share/omarchy|$packaged_root|g" "$elsewhen_migration" >"$test_dir/elsewhen-migration.sh"
plugin="$test_dir/home/.config/omarchy/plugins/omacom.elsewhen"

if run_migration "$test_dir/elsewhen-migration.sh" >"$test_dir/out" 2>"$test_dir/err"; then
  fail "the Elsewhen migration must fail when elsewhen is not installed"
fi
grep -q 'omarchy overlay setup packages core' "$test_dir/err" ||
  fail "the Elsewhen migration names the repair command" "$(cat "$test_dir/err")"
[[ ! -e $plugin && ! -L $plugin && ! -s $CALL_LOG ]] ||
  fail "the Elsewhen migration links and places nothing without its package"
pass "the Elsewhen migration stays pending until elsewhen is installed"

mkdir -p "$packaged_root/shell/plugins/omacom.elsewhen"
expected=$'omarchy-shell -q shell rescanPlugins\nomarchy-bar put omacom.elsewhen --before omarchy.clock'
run_migration "$test_dir/elsewhen-migration.sh" >"$test_dir/out" || fail "the Elsewhen migration succeeds once elsewhen is installed"
[[ $(readlink "$plugin") == "$packaged_root/shell/plugins/omacom.elsewhen" ]] || fail "the checkout-backed shell gets a user plugin link"
[[ $(cat "$CALL_LOG") == "$expected" ]] || fail "scan and placement run in order" "$(cat "$CALL_LOG")"
pass "the Elsewhen migration links the packaged plugin and places it before the clock"

run_migration "$test_dir/elsewhen-migration.sh" >"$test_dir/out" || fail "the Elsewhen migration reruns cleanly"
[[ $(readlink "$plugin") == "$packaged_root/shell/plugins/omacom.elsewhen" ]] || fail "the link survives a rerun"
pass "the Elsewhen migration is idempotent"

ln -sfn "$packaged_root/plugins/omacom.elsewhen" "$plugin"
run_migration "$test_dir/elsewhen-migration.sh" >"$test_dir/out" || fail "a stranded link does not stop the migration"
[[ $(readlink "$plugin") == "$packaged_root/shell/plugins/omacom.elsewhen" ]] ||
  fail "a link stranded at the package's old path is re-pointed" "$(readlink "$plugin")"
pass "the Elsewhen migration repairs the link stranded by the package's move"

ln -sfn "$test_dir/custom-plugin" "$plugin"
run_migration "$test_dir/elsewhen-migration.sh" >"$test_dir/out" || fail "a custom link does not stop the migration"
[[ $(readlink "$plugin") == "$test_dir/custom-plugin" ]] || fail "a link the user made is preserved, even dangling"
pass "the Elsewhen migration leaves a user-made link alone"

# --- mise PATH fix ------------------------------------------------------
checkout="$test_dir/checkout"
mkdir -p "$checkout/migrations"
cat >"$checkout/migrations/1789095456.sh" <<'SH'
echo "product mise migration" >>"$CALL_LOG"
false
echo "continued past a failure" >>"$CALL_LOG"
SH

OMARCHY_PATH_OVERRIDE="$checkout" TEST_MISE_PRESENT=0 run_migration "$mise_migration" >/dev/null ||
  fail "the mise migration succeeds without mise"
[[ ! -s $CALL_LOG ]] || fail "the mise migration does nothing without mise" "$(cat "$CALL_LOG")"
pass "the mise migration is a no-op on hosts without mise"

if OMARCHY_PATH_OVERRIDE="$checkout" TEST_MISE_PRESENT=1 run_migration "$mise_migration" >/dev/null 2>&1; then
  fail "a failing product PATH fix must fail the overlay migration"
fi
[[ $(cat "$CALL_LOG") == "product mise migration" ]] ||
  fail "the product PATH fix runs under strict mode and stops at its first failure" "$(cat "$CALL_LOG")"
pass "the mise migration reuses the product PATH fix under strict error handling"
