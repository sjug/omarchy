#!/bin/bash
# The desktop-overlay migrations that mirror product changes only do user-side
# wiring: packages come from
# the desktop manifest's package transaction, so each migration must fail
# loudly when its package is absent and must never install anything itself.

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

migrations="$ROOT/migrations/desktop-overlay"
omasnap_migration="$migrations/1790272914.sh"
owe_migration="$migrations/1790272915.sh"
mise_migration="$migrations/1790272917.sh"
elsewhen_migration="$migrations/1791987965.sh"
dictation_migration="$migrations/1791987966.sh"
layouts_migration="$migrations/1791987967.sh"
keyboard_widget_migration="$migrations/1791987968.sh"
input_method_migration="$migrations/1791987969.sh"
scrollbars_migration="$migrations/1791987970.sh"
secret_portal_migration="$migrations/1791987971.sh"
wallpaper_migration="$migrations/1791987972.sh"

test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/bin" "$test_dir/home"
export CALL_LOG="$test_dir/calls"

for stub in omarchy-pkg-add omarchy-pkg-drop omarchy-hook-install omarchy-shell omarchy-bar omarchy-input-method hyprctl systemctl omasnap; do
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
if [[ $1 == "mise" ]]; then
  [[ ${TEST_MISE_PRESENT:-0} == 1 ]]
else
  [[ -n ${TEST_PRESENT_COMMANDS:-} ]] && grep -qx "$1" <<<"$TEST_PRESENT_COMMANDS"
fi
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

# Migrations run under the runner's strict mode; keep the same flags here. The
# XDG base directories would otherwise point the migrations at the real home.
run_migration() {
  : >"$CALL_LOG"
  env -u XDG_CONFIG_HOME -u XDG_STATE_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME \
    HOME="$test_dir/home" OMARCHY_PATH="${OMARCHY_PATH_OVERRIDE:-$ROOT}" PATH="${TEST_PATH:-$test_dir/bin:$ROOT/bin:$PATH}" \
    "$BASH" -euo pipefail "$@"
}

for migration in "$migrations"/*.sh; do
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
# tree so the test never touches the real system paths.
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
# The package ships the hook as a plain 0644 file; omarchy-hook-install makes
# its installed copy executable.
chmod 644 "$owe_root/share/10-owe-sync"
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

# --- Elsewhen -------------------------------------------------------------
shell_json="$test_dir/home/.config/omarchy/shell.json"
mkdir -p "${shell_json%/*}"
printf '%s\n' '{"bar":{"layout":{"center":[{"id":"omarchy.clock"}]}}}' >"$shell_json"
run_migration "$elsewhen_migration" >/dev/null
[[ $(<"$CALL_LOG") == $'omarchy-shell -q shell rescanPlugins\nomarchy-bar put omarchy.elsewhen --after omarchy.clock' ]] ||
  fail "the Elsewhen migration rescans plugins and puts the clock's neighbour on the bar" "$(<"$CALL_LOG")"
pass "the Elsewhen migration puts the built-in world clock after the clock"

printf '%s\n' '{"bar":{"layout":{"center":[{"id":"omarchy.clock"},{"id":"omarchy.elsewhen"}]}}}' >"$shell_json"
run_migration "$elsewhen_migration" >/dev/null
! grep -q '^omarchy-bar ' "$CALL_LOG" || fail "the Elsewhen migration moves a world clock already on the bar" "$(<"$CALL_LOG")"
pass "the Elsewhen migration leaves a world clock already on the bar where it is"

printf '%s\n' '{"bar":{"layout":{"center":[{"id":"omarchy.clock"},{"id":"omacom.elsewhen","cities":["Tokyo"]}],"right":["omacom.elsewhen"]},"centerAnchor":"omacom.elsewhen"},"disabledPlugins":["omacom.elsewhen"]}' >"$shell_json"
run_migration "$elsewhen_migration" >/dev/null
! grep -q '^omarchy-bar ' "$CALL_LOG" || fail "the Elsewhen migration duplicates a legacy world clock entry" "$(<"$CALL_LOG")"
jq -e '.bar.layout.center[1] == {"id":"omarchy.elsewhen","cities":["Tokyo"]}' "$shell_json" >/dev/null ||
  fail "a legacy world clock object keeps its place and settings under the new id" "$(<"$shell_json")"
jq -e '.bar.layout.right == ["omarchy.elsewhen"] and .bar.centerAnchor == "omarchy.elsewhen" and .disabledPlugins == ["omarchy.elsewhen"]' "$shell_json" >/dev/null ||
  fail "legacy world clock references are renamed everywhere" "$(<"$shell_json")"
! grep -q 'omacom' "$shell_json" || fail "no legacy world clock id remains" "$(<"$shell_json")"
pass "the Elsewhen migration renames a legacy world clock in place, settings included"

printf '%s\n' '{"bar":{"layout":{"center":[{"id":"omarchy.clock"}]}},"disabledPlugins":["omacom.elsewhen"]}' >"$shell_json"
run_migration "$elsewhen_migration" >/dev/null
! grep -q '^omarchy-bar ' "$CALL_LOG" || fail "the Elsewhen migration enables a world clock the user turned off" "$(<"$CALL_LOG")"
jq -e '.disabledPlugins == ["omarchy.elsewhen"]' "$shell_json" >/dev/null || fail "a turned-off world clock stays off under the new id" "$(<"$shell_json")"
pass "the Elsewhen migration leaves a world clock the user turned off"

# --- Dictation backend ----------------------------------------------------
dictation_config="$test_dir/home/.config/omarchy/defaults/dictation"
run_migration "$dictation_migration" >/dev/null
[[ ! -e $dictation_config ]] || fail "the dictation migration picks a backend without Voxtype"
[[ ! -s $CALL_LOG ]] || fail "the dictation migration reloads Hyprland without Voxtype" "$(<"$CALL_LOG")"
TEST_PRESENT_COMMANDS=voxtype run_migration "$dictation_migration" >"$test_dir/out"
[[ $(<"$dictation_config") == "voxtype" ]] || fail "an existing Voxtype setup keeps Voxtype as its backend"
grep -qx 'hyprctl reload' "$CALL_LOG" || fail "the dictation migration rebinds the keys" "$(<"$CALL_LOG")"
grep -q "do not run 'omarchy refresh config omarchy/defaults/dictation'" "$test_dir/out" ||
  fail "the dictation migration warns against refreshing the default away" "$(<"$test_dir/out")"
printf 'something-else\n' >"$dictation_config"
TEST_PRESENT_PACKAGES=voxtype-bin run_migration "$dictation_migration" >/dev/null
[[ $(<"$dictation_config") == "something-else" ]] || fail "the dictation migration overrides a chosen backend"
pass "the dictation migration keeps Voxtype for its users and never overrides a choice"

# --- Workspace layouts ----------------------------------------------------
layouts_dir="$test_dir/home/.local/state/omarchy/workspace-layouts"
mkdir -p "$layouts_dir"
printf '%s\n' 'hl.workspace_rule({ workspace = "2", layout = "scrolling" })' >"$layouts_dir/2.lua"
printf '%s\n' 'hl.workspace_rule({ workspace = "-98", layout = "monocle" })' >"$layouts_dir/-98.lua"
run_migration "$layouts_migration" >/dev/null
[[ ! -e $layouts_dir/-98.lua ]] || fail "a named workspace's saved layout is dropped"
[[ $(<"$layouts_dir/2.lua") == 'o.workspace_mode({ workspace = "2", mode = "scrolling" })' ]] ||
  fail "a saved layout becomes a workspace mode" "$(<"$layouts_dir/2.lua")"
grep -qx 'hyprctl reload' "$CALL_LOG" || fail "dropping a named layout reloads Hyprland" "$(<"$CALL_LOG")"
run_migration "$layouts_migration" >/dev/null
[[ $(<"$layouts_dir/2.lua") == 'o.workspace_mode({ workspace = "2", mode = "scrolling" })' ]] ||
  fail "the layout migration is idempotent" "$(<"$layouts_dir/2.lua")"
[[ ! -s $CALL_LOG ]] || fail "a rerun with nothing to drop reloads Hyprland" "$(<"$CALL_LOG")"
pass "the layout migration drops named workspaces' layouts and saves the rest as modes"

# --- Keyboard layout widget ----------------------------------------------
run_migration "$keyboard_widget_migration" >/dev/null
[[ $(<"$CALL_LOG") == "omarchy-bar move omarchy.keyboard-layout --from-section center --section right --index 0" ]] ||
  fail "the keyboard layout widget leads the right-hand cluster" "$(<"$CALL_LOG")"
cat >"$test_dir/bin/omarchy-bar" <<'SH'
#!/bin/bash
echo "omarchy-bar $*" >>"$CALL_LOG"
exit 1
SH
run_migration "$keyboard_widget_migration" >/dev/null || fail "a bar that cannot move the widget fails the migration"
cat >"$test_dir/bin/omarchy-bar" <<'SH'
#!/bin/bash
echo "omarchy-bar $*" >>"$CALL_LOG"
SH
pass "the keyboard layout widget moves from the center only, best-effort"

# --- Input-method defaults ------------------------------------------------
# The shipped unit path is package-owned; rewrite it into the test tree.
im_units="$test_dir/im-units"
mkdir -p "$im_units"
sed "s|/usr/lib/systemd/user|$im_units|g" "$input_method_migration" >"$test_dir/input-method-migration.sh"
user_unit="$test_dir/home/.config/systemd/user/omarchy-fcitx5.service"
mkdir -p "${user_unit%/*}"

run_migration "$test_dir/input-method-migration.sh" >/dev/null
[[ ! -s $CALL_LOG ]] || fail "input-method defaults apply without fcitx5" "$(<"$CALL_LOG")"
TEST_PRESENT_COMMANDS=fcitx5 run_migration "$test_dir/input-method-migration.sh" >/dev/null
[[ ! -s $CALL_LOG ]] || fail "input-method defaults apply where fcitx5 runs outside omarchy-fcitx5.service" "$(<"$CALL_LOG")"
pass "input-method defaults skip hosts that do not run fcitx5 through Omarchy's unit"

git -C "$ROOT" show 28ceaae70:default/systemd/user/omarchy-fcitx5.service >"$user_unit"
TEST_PRESENT_COMMANDS=fcitx5 run_migration "$test_dir/input-method-migration.sh" >/dev/null
cmp -s "$user_unit" "$ROOT/default/systemd/user/omarchy-fcitx5.service" ||
  fail "an unmodified copy of the previous unit becomes the current one"
grep -qx 'systemctl --user daemon-reload' "$CALL_LOG" || fail "a replaced unit is reloaded" "$(<"$CALL_LOG")"
grep -qx 'omarchy-input-method configure --defaults' "$CALL_LOG" || fail "the input-method defaults are written" "$(<"$CALL_LOG")"
printf '# mine\n' >>"$user_unit"
cp "$user_unit" "$test_dir/custom-unit"
TEST_PRESENT_COMMANDS=fcitx5 run_migration "$test_dir/input-method-migration.sh" >/dev/null
cmp -s "$user_unit" "$test_dir/custom-unit" || fail "a customised unit is replaced"
! grep -q 'daemon-reload' "$CALL_LOG" || fail "an untouched unit triggers a reload" "$(<"$CALL_LOG")"
! grep -Eq '^omarchy-pkg-(add|drop) ' "$CALL_LOG" || fail "input-method defaults install engines" "$(<"$CALL_LOG")"
pass "input-method defaults refresh only Omarchy's own previous unit and install no engines"

# --- Chromium overlay scrollbars ----------------------------------------
printf '%s\n' '--ozone-platform=wayland' '--enable-features=TouchpadOverscrollHistoryNavigation' >"$test_dir/home/.config/chromium-flags.conf"
printf '%s' '--ozone-platform=wayland' >"$test_dir/home/.config/brave-origin-flags.conf"
run_migration "$scrollbars_migration" >/dev/null
grep -qx -- '--enable-features=TouchpadOverscrollHistoryNavigation,OverlayScrollbar' "$test_dir/home/.config/chromium-flags.conf" ||
  fail "an existing feature list gains overlay scrollbars" "$(<"$test_dir/home/.config/chromium-flags.conf")"
[[ $(<"$test_dir/home/.config/brave-origin-flags.conf") == $'--ozone-platform=wayland\n--enable-features=OverlayScrollbar' ]] ||
  fail "a flags file without features gets its own line" "$(<"$test_dir/home/.config/brave-origin-flags.conf")"
run_migration "$scrollbars_migration" >/dev/null
(( $(grep -c OverlayScrollbar "$test_dir/home/.config/chromium-flags.conf") == 1 )) || fail "the scrollbar migration is idempotent"
pass "Chromium-family flags gain overlay scrollbars once"

# --- Secret portal --------------------------------------------------------
portal_backends="$test_dir/portals"
mkdir -p "$portal_backends"
sed "s|/usr/share/xdg-desktop-portal/portals|$portal_backends|g" "$secret_portal_migration" >"$test_dir/secret-portal-migration.sh"
portal_config="$test_dir/home/.config/xdg-desktop-portal/hyprland-portals.conf"
run_migration "$test_dir/secret-portal-migration.sh" >/dev/null
[[ ! -e $portal_config ]] || fail "the Secret portal is configured without GNOME Keyring's backend"
touch "$portal_backends/gnome-keyring.portal"
run_migration "$test_dir/secret-portal-migration.sh" >/dev/null
cmp -s "$portal_config" "$ROOT/config/xdg-desktop-portal/hyprland-portals.conf" ||
  fail "the Secret portal routes to GNOME Keyring where its backend is installed"
printf 'mine\n' >"$portal_config"
run_migration "$test_dir/secret-portal-migration.sh" >/dev/null
[[ $(<"$portal_config") == "mine" ]] || fail "an existing portal configuration is replaced"
pass "the Secret portal reaches GNOME Keyring only where the host has its backend"

# --- Renumbered wallpaper -------------------------------------------------
checkout="$test_dir/wallpaper-checkout"
current="$test_dir/home/.local/state/omarchy/current"
mkdir -p "$checkout/themes/tokyo-night/backgrounds" "$current/theme/backgrounds"
printf 'quattro' >"$checkout/themes/tokyo-night/backgrounds/2-quattro.webp"
printf 'liftoff' >"$checkout/themes/tokyo-night/backgrounds/0-liftoff.webp"
printf 'quattro' >"$current/theme/backgrounds/1-quattro.webp"
printf 'tokyo-night\n' >"$current/theme.name"
ln -sfn "$current/theme/backgrounds/1-quattro.webp" "$current/background"
OMARCHY_PATH_OVERRIDE="$checkout" run_migration "$wallpaper_migration" >/dev/null
[[ $(readlink "$current/background") == "$current/theme/backgrounds/2-quattro.webp" ]] ||
  fail "the wallpaper follows its renumbered file" "$(readlink "$current/background")"
[[ $(<"$current/theme/backgrounds/2-quattro.webp") == "quattro" ]] || fail "the renumbered file is staged"
grep -qx "omarchy-shell -q background set $current/theme/backgrounds/2-quattro.webp" "$CALL_LOG" ||
  fail "the running shell shows the repaired wallpaper" "$(<"$CALL_LOG")"
OMARCHY_PATH_OVERRIDE="$checkout" run_migration "$wallpaper_migration" >/dev/null
[[ ! -s $CALL_LOG ]] || fail "a wallpaper whose file still exists is left alone" "$(<"$CALL_LOG")"
printf 'other' >"$checkout/themes/tokyo-night/backgrounds/3-quattro.webp"
ln -sfn "$current/theme/backgrounds/1-quattro.webp" "$current/background"
OMARCHY_PATH_OVERRIDE="$checkout" run_migration "$wallpaper_migration" >/dev/null
[[ $(readlink "$current/background") == "$current/theme/backgrounds/1-quattro.webp" ]] ||
  fail "an ambiguous renumbering guesses a wallpaper"
pass "the wallpaper follows a renumbered theme background only when the match is unambiguous"

# --- Agent skill links ----------------------------------------------------
skill_migration="$migrations/1791987973.sh"
mkdir -p "$test_dir/home/.claude/skills" "$test_dir/home/.codex/skills" "$test_dir/home/.agents/skills"
ln -sfn /old/checkout/default/omarchy-skill "$test_dir/home/.claude/skills/omarchy"
ln -sfn /somewhere/else/omarchy "$test_dir/home/.codex/skills/omarchy"
run_migration "$skill_migration" >/dev/null
[[ $(readlink "$test_dir/home/.claude/skills/omarchy") == "$ROOT/default/agents/skills/omarchy" ]] ||
  fail "a link to the old skill location follows the skill" "$(readlink "$test_dir/home/.claude/skills/omarchy")"
[[ $(readlink "$test_dir/home/.codex/skills/omarchy") == "/somewhere/else/omarchy" ]] || fail "a user's own skill link is replaced"
[[ ! -e $test_dir/home/.agents/skills/omarchy && ! -L $test_dir/home/.agents/skills/omarchy ]] || fail "a missing skill link is created"
pass "agent skill links that point at the old location follow the skill, and no others change"
