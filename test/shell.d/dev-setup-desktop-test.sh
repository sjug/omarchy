#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

# The orchestrator resolves its own realpath to find the checkout, so the
# real scripts under test are copied (not symlinked) into a fixture checkout
# whose bin/ otherwise holds logging stubs for every privileged or heavy step.
fake_checkout="$test_tmp/checkout"
test_home="$test_tmp/home"
stub_bin="$test_tmp/stubs"
sudo_log="$test_tmp/sudo.log"
call_log="$test_tmp/calls.log"
pacman_conf="$test_tmp/pacman.conf"
omarchy_conf="$test_tmp/omarchy.conf"
system_root="$test_tmp/system-root"
systemctl_state="$test_tmp/systemctl.state"

mkdir -p "$stub_bin" "$test_home" \
  "$fake_checkout/bin" "$fake_checkout/install" \
  "$fake_checkout/themes/tokyo-night" "$fake_checkout/themes/catppuccin" \
  "$fake_checkout/default/fonts/omarchy" "$fake_checkout/default/bash" \
  "$fake_checkout/default/uwsm/env.d" "$fake_checkout/default/wayland-sessions" \
  "$fake_checkout/default/sddm/omarchy" "$fake_checkout/etc/sddm.conf.d" \
  "$fake_checkout/config/hypr" "$fake_checkout/config/foot" \
  "$fake_checkout/config/git" "$fake_checkout/config/tmux" "$system_root"

cp "$ROOT/bin/omarchy-dev-setup-desktop" "$fake_checkout/bin/"
cp "$ROOT/bin/omarchy-cmd-present" "$fake_checkout/bin/"
cp "$ROOT/bin/omarchy-refresh-config" "$fake_checkout/bin/"
cp "$ROOT/bin/omarchy-done" "$fake_checkout/bin/"

cat >"$fake_checkout/install/omarchy-desktop.packages" <<'PKGS'
# fixture manifest
# group: core
hyprland
foot # trailing comment

quickshell
ttf-jetbrains-mono-nerd-basic
omarchy-keyring
# group: audio
alsa-utils
# group: files
nautilus
# group: connectivity
bluez
# group: capture
grim
# group: power
brightnessctl
# group: display-manager
qt6-wayland
sddm
PKGS

echo 'lua' >"$fake_checkout/config/hypr/hyprland.lua"
echo 'ini' >"$fake_checkout/config/foot/foot.ini"
echo 'gitconfig' >"$fake_checkout/config/git/config"
echo 'tmux' >"$fake_checkout/config/tmux/tmux.conf"
: >"$fake_checkout/default/fonts/omarchy/omarchy.ttf"
: >"$fake_checkout/default/bash/env-bootstrap"
: >"$fake_checkout/default/uwsm/env.d/10-omarchy"
printf '[Desktop Entry]\n' >"$fake_checkout/default/wayland-sessions/omarchy.desktop"
printf '[Theme]\nCurrent=omarchy\n' >"$fake_checkout/etc/sddm.conf.d/10-theme.conf"
printf '[General]\nDisplayServer=wayland\n' >"$fake_checkout/etc/sddm.conf.d/10-wayland.conf"
echo 'hyprland greeter config' >"$fake_checkout/default/sddm/hyprland.lua"
echo 'sddm theme' >"$fake_checkout/default/sddm/omarchy/Main.qml"
echo 'sddm metadata' >"$fake_checkout/default/sddm/omarchy/metadata.desktop"
echo 'sddm theme config' >"$fake_checkout/default/sddm/omarchy/theme.conf"
for theme_asset in bullet.png entry.png entry-failed.png lock.png lock-failed.png logo.png; do
  : >"$fake_checkout/default/sddm/omarchy/$theme_asset"
done
echo 'about branding' >"$fake_checkout/icon.txt"
echo 'screensaver branding' >"$fake_checkout/logo.txt"

cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_TEST_SUDO_LOG"
if [[ $1 == "pacman-key" && $2 == "--list-keys" && ${OMARCHY_TEST_KEY_PRESENT:-0} == 0 ]]; then
  exit 1
fi
case "$1" in
  cp|install|rm|systemctl|tee)
    "$@"
    exit
    ;;
esac
if [[ ! -t 0 ]]; then
  cat >/dev/null
fi
SH

printf '#!/bin/bash\nexit 0\n' >"$stub_bin/fc-cache"

cat >"$stub_bin/pacman" <<'SH'
#!/bin/bash
if [[ $1 == "-Q" && -n ${2:-} ]]; then
  for installed in ${OMARCHY_TEST_PRODUCT_INSTALLED:-}; do
    if [[ $2 == "$installed" ]]; then
      exit 0
    fi
  done
  for installed in ${OMARCHY_TEST_INSTALLED_PACKAGES:-}; do
    if [[ $2 == "$installed" ]]; then
      exit 0
    fi
  done
  exit 1
fi
exit 0
SH

cat >"$stub_bin/systemctl" <<'SH'
#!/bin/bash
case "$1" in
  get-default)
    sed -n 's/^default=//p' "$OMARCHY_TEST_SYSTEMCTL_STATE"
    ;;
  is-enabled)
    unit="${@: -1}"
    if [[ $unit == "sddm.service" ]] && grep -qx 'sddm=enabled' "$OMARCHY_TEST_SYSTEMCTL_STATE"; then
      [[ $2 == "--quiet" ]] || echo enabled
      exit 0
    else
      [[ ${2:-} == "--quiet" ]] || echo disabled
      exit 1
    fi
    ;;
  enable)
    if grep -qx 'sddm=missing' "$OMARCHY_TEST_SYSTEMCTL_STATE"; then
      exit 1
    fi
    sed -i 's/^sddm=.*/sddm=enabled/' "$OMARCHY_TEST_SYSTEMCTL_STATE"
    ;;
  disable)
    if grep -qx 'sddm=missing' "$OMARCHY_TEST_SYSTEMCTL_STATE"; then
      exit 1
    fi
    sed -i 's/^sddm=.*/sddm=disabled/' "$OMARCHY_TEST_SYSTEMCTL_STATE"
    ;;
  set-default)
    sed -i "s/^default=.*/default=$2/" "$OMARCHY_TEST_SYSTEMCTL_STATE"
    ;;
esac
SH

cat >"$stub_bin/xdg-mime" <<'SH'
#!/bin/bash
printf 'xdg-mime %s\n' "$*" >>"$OMARCHY_TEST_CALL_LOG"
SH

cat >"$fake_checkout/bin/omarchy-dev-link" <<'SH'
#!/bin/bash
printf 'dev-link %s\n' "$*" >>"$OMARCHY_TEST_CALL_LOG"
printf 'export OMARCHY_PATH=%s\n' "$1" >"$OMARCHY_DEV_SETUP_OMARCHY_CONF"
SH

cat >"$fake_checkout/bin/omarchy-apply-lock" <<'SH'
#!/bin/bash
printf 'apply-lock\n' >>"$OMARCHY_TEST_CALL_LOG"
SH

cat >"$fake_checkout/bin/omarchy-theme-set" <<'SH'
#!/bin/bash
printf 'theme-set %s headless=%s\n' "$1" "${OMARCHY_THEME_HEADLESS:-0}" >>"$OMARCHY_TEST_CALL_LOG"
SH

cat >"$fake_checkout/bin/omarchy-theme-set-gnome" <<'SH'
#!/bin/bash
printf 'theme-set-gnome\n' >>"$OMARCHY_TEST_CALL_LOG"
SH

cat >"$fake_checkout/bin/omarchy-sudo-keepalive" <<'SH'
#!/bin/bash
sudo -v
printf 'sudo-keepalive\n' >>"$OMARCHY_TEST_CALL_LOG"
SH

chmod +x "$stub_bin"/* "$fake_checkout/bin"/*

run_setup() {
  env -i HOME="$test_home" PATH="$stub_bin:/usr/bin" \
    OMARCHY_TEST_SUDO_LOG="$sudo_log" OMARCHY_TEST_CALL_LOG="$call_log" \
    OMARCHY_TEST_PRODUCT_INSTALLED="${OMARCHY_TEST_PRODUCT_INSTALLED:-}" \
    OMARCHY_TEST_INSTALLED_PACKAGES="${OMARCHY_TEST_INSTALLED_PACKAGES:-}" \
    OMARCHY_TEST_KEY_PRESENT="${OMARCHY_TEST_KEY_PRESENT:-0}" \
    OMARCHY_TEST_SYSTEMCTL_STATE="$systemctl_state" \
    OMARCHY_DEV_SETUP_PACMAN_CONF="$pacman_conf" \
    OMARCHY_DEV_SETUP_OMARCHY_CONF="$omarchy_conf" \
    OMARCHY_DEV_SETUP_SYSTEM_ROOT="$system_root" \
    bash "$fake_checkout/bin/omarchy-dev-setup-desktop" "$@"
}

reset_run() {
  rm -rf "$test_home"
  mkdir -p "$test_home"
  rm -rf "$system_root"
  mkdir -p "$system_root"
  rm -f "$omarchy_conf"
  printf 'sddm=disabled\ndefault=graphical.target\n' >"$systemctl_state"
  : >"$sudo_log"
  : >"$call_log"
}

seed_display_manager_prerequisites() {
  printf 'export OMARCHY_PATH=%s\n' "$fake_checkout" >"$omarchy_conf"
  mkdir -p \
    "$test_home/.config/hypr" \
    "$test_home/.config/omarchy/branding" \
    "$test_home/.config/btop/themes" \
    "$test_home/.local/state/omarchy/done"
  : >"$test_home/.config/hypr/hyprland.lua"
  : >"$test_home/.config/omarchy/branding/about.txt"
  : >"$test_home/.config/omarchy/branding/screensaver.txt"
  : >"$test_home/.local/state/omarchy/done/first-run-user"
  ln -s "$test_home/generated-btop.theme" "$test_home/.config/btop/themes/current.theme"
}

# --- No stage or an unknown stage is a usage error, not a silent default.
reset_run
if run_setup >/dev/null 2>&1; then
  fail "running without a stage is refused"
fi
if run_setup frobnicate >/dev/null 2>&1; then
  fail "an unknown stage is refused"
fi
[[ ! -s $sudo_log ]] || fail "usage errors happen before sudo" "$(<"$sudo_log")"
pass "missing or unknown stages are usage errors before sudo"

# --- Theme validation happens before sudo, covering the full theme-set rules.
for bad_theme in '<div>' '..' 'nested/theme' 'no-such-theme'; do
  reset_run
  if run_setup config --theme "$bad_theme" >/dev/null 2>&1; then
    fail "theme '$bad_theme' is rejected"
  fi
  if [[ -s $sudo_log ]]; then
    fail "theme '$bad_theme' is rejected before sudo runs" "$(<"$sudo_log")"
  fi
done
pass "invalid themes are rejected before sudo or any system change"

# --- A checkout without the manifest is refused.
reset_run
mv "$fake_checkout/install/omarchy-desktop.packages" "$test_tmp/manifest.stash"
if run_setup core >/dev/null 2>&1; then
  fail "a checkout without the desktop manifest is refused"
fi
mv "$test_tmp/manifest.stash" "$fake_checkout/install/omarchy-desktop.packages"
pass "a checkout without the desktop manifest is refused"

# --- A system with the product packages installed is refused before sudo.
for product_pkg in omarchy omarchy-dev omarchy-settings omarchy-settings-dev; do
  reset_run
  if OMARCHY_TEST_PRODUCT_INSTALLED=$product_pkg run_setup core >/dev/null 2>&1; then
    fail "a system with $product_pkg installed is refused"
  fi
  if [[ -s $sudo_log ]]; then
    fail "the $product_pkg refusal happens before sudo" "$(<"$sudo_log")"
  fi
done
pass "systems with Omarchy product packages installed are refused before sudo"

# --- Root invocation is refused outright.
if command -v fakeroot >/dev/null 2>&1; then
  reset_run
  if fakeroot bash "$fake_checkout/bin/omarchy-dev-setup-desktop" core >/dev/null 2>&1; then
    fail "running as root is refused"
  fi
  pass "running as root is refused"
fi

# --- status is read-only: no sudo, no writes, reports the missing pieces.
reset_run
status_output=$(run_setup status)
[[ ! -s $sudo_log ]] || fail "status never uses sudo" "$(<"$sudo_log")"
[[ ! -e $test_home/.config ]] || fail "status writes nothing to \$HOME"
grep -q 'core: 5 of 5 packages missing' <<<"$status_output" || fail "status reports missing core packages" "$status_output"
grep -q 'link: not linked' <<<"$status_output" || fail "status reports the missing link" "$status_output"
grep -q 'config: not seeded' <<<"$status_output" || fail "status reports unseeded config" "$status_output"
pass "status is read-only and reports missing stages"

# --- config depends on link.
reset_run
printf '[omarchy]\nServer = x\n' >"$pacman_conf"
if run_setup config >/dev/null 2>&1; then
  fail "config without link is refused"
fi
config_err=$(run_setup config 2>&1 || true)
grep -q "run 'omarchy-dev-setup-desktop link' first" <<<"$config_err" ||
  fail "the config-without-link error names the link stage" "$config_err"
pass "config requires link and says so"

# --- An omarchy.conf pointing at a different checkout is not a valid link.
reset_run
printf '[omarchy]\nServer = x\n' >"$pacman_conf"
printf 'export OMARCHY_PATH=/definitely/wrong\n' >"$omarchy_conf"
if OMARCHY_TEST_INSTALLED_PACKAGES="hyprland foot quickshell ttf-jetbrains-mono-nerd-basic omarchy-keyring" run_setup config >/dev/null 2>&1; then
  fail "config with a mislinked omarchy.conf is refused"
fi
mislink_err=$(OMARCHY_TEST_INSTALLED_PACKAGES="hyprland foot quickshell ttf-jetbrains-mono-nerd-basic omarchy-keyring" run_setup config 2>&1 || true)
grep -q "points at /definitely/wrong, not this checkout" <<<"$mislink_err" ||
  fail "the mislink error names the wrong path" "$mislink_err"
status_output=$(run_setup status)
grep -q 'link: points at /definitely/wrong, not this checkout' <<<"$status_output" ||
  fail "status reports a mislinked checkout" "$status_output"
pass "an omarchy.conf pointing elsewhere is reported and refused, not accepted"

# --- --no-session-entry cannot silently no-op an explicit session-entry run.
reset_run
if run_setup session-entry --no-session-entry >/dev/null 2>&1; then
  fail "session-entry with --no-session-entry is refused instead of a silent no-op"
fi
[[ ! -s $sudo_log ]] || fail "the contradictory flag combination fails before sudo" "$(<"$sudo_log")"
pass "session-entry plus --no-session-entry is refused"

reset_run
if run_setup display-manager --no-session-entry >/dev/null 2>&1; then
  fail "display-manager accepts --no-session-entry"
fi
[[ ! -s $sudo_log ]] || fail "the display-manager session-entry conflict fails before sudo" "$(<"$sudo_log")"
pass "display-manager cannot be separated from the session entry it launches"

# --- Dependency failures are preflighted before a selected package stage acts.
reset_run
printf '[core]\nInclude = /etc/pacman.d/mirrorlist\n' >"$pacman_conf"
if run_setup core config >/dev/null 2>&1; then
  fail "core plus config without link is refused"
fi
[[ ! -s $sudo_log ]] || fail "core plus config fails before sudo or pacman" "$(<"$sudo_log")"
pass "stage dependencies are validated before package or system changes"

reset_run
printf '[omarchy]\nServer = x\n' >"$pacman_conf"
if run_setup lock >/dev/null 2>&1; then
  fail "a non-core stage without core is refused"
fi
[[ ! -s $sudo_log ]] || fail "a missing core dependency fails before sudo" "$(<"$sudo_log")"
pass "non-core stages require the core package stage"

# --- Config alone is user-scoped once core and link are already present.
reset_run
printf '[omarchy]\nServer = x\n' >"$pacman_conf"
printf 'export OMARCHY_PATH=%s\n' "$fake_checkout" >"$omarchy_conf"
mkdir -p "$test_home/.config/omarchy/branding"
echo 'custom about branding' >"$test_home/.config/omarchy/branding/about.txt"
echo 'custom screensaver branding' >"$test_home/.config/omarchy/branding/screensaver.txt"
OMARCHY_TEST_INSTALLED_PACKAGES="hyprland foot quickshell ttf-jetbrains-mono-nerd-basic omarchy-keyring" run_setup config >/dev/null
[[ ! -s $sudo_log ]] || fail "config alone does not prime sudo" "$(<"$sudo_log")"
if grep -qx 'sudo-keepalive' "$call_log"; then
  fail "config alone does not start the sudo keepalive" "$(<"$call_log")"
fi
btop_theme_link="$test_home/.config/btop/themes/current.theme"
[[ -L $btop_theme_link ]] || fail "config creates the btop current-theme symlink"
[[ $(readlink "$btop_theme_link") == "$test_home/.local/state/omarchy/current/theme/btop.theme" ]] ||
  fail "btop current-theme symlink targets the generated Omarchy theme" "$(readlink "$btop_theme_link")"
grep -qx 'custom about branding' "$test_home/.config/omarchy/branding/about.txt" ||
  fail "config preserves existing About branding"
grep -qx 'custom screensaver branding' "$test_home/.config/omarchy/branding/screensaver.txt" ||
  fail "config preserves existing screensaver branding"
pass "config is user-scoped, preserves custom branding, and links btop to the generated theme"
grep -qx 'theme-set-gnome' "$call_log" ||
  fail "config synchronizes the generated theme to GTK applications" "$(<"$call_log")"

# --- Invalid branding targets are refused before config writes begin. A
# successful config stage must never leave a runtime path it knows is broken.
reset_run
printf '[omarchy]\nServer = x\n' >"$pacman_conf"
printf 'export OMARCHY_PATH=%s\n' "$fake_checkout" >"$omarchy_conf"
mkdir -p "$test_home/.config/omarchy/branding"
ln -s "$test_home/missing-branding" "$test_home/.config/omarchy/branding/screensaver.txt"
if OMARCHY_TEST_INSTALLED_PACKAGES="hyprland foot quickshell ttf-jetbrains-mono-nerd-basic omarchy-keyring" run_setup config >/dev/null 2>&1; then
  fail "config accepts a dangling screensaver-branding symlink"
fi
[[ ! -e $test_home/.local/share/fonts/omarchy.ttf ]] || fail "branding validation happens before config writes"
pass "config refuses broken branding targets before modifying user config"

# --- core alone: repo plus core packages, nothing user-level.
reset_run
printf '[core]\nInclude = /etc/pacman.d/mirrorlist\n' >"$pacman_conf"
run_setup core >/dev/null
grep -qx "pacman -Syu --needed hyprland foot quickshell ttf-jetbrains-mono-nerd-basic omarchy-keyring" "$sudo_log" ||
  fail "core installs exactly the comment-stripped core group" "$(<"$sudo_log")"
grep -q "tee -a $pacman_conf" "$sudo_log" || fail "core adds the repo stanza when missing" "$(<"$sudo_log")"
grep -qx 'SigLevel = Required DatabaseOptional' "$pacman_conf" ||
  fail "core requires Omarchy package signatures while permitting the unsigned repository database" "$(<"$pacman_conf")"
grep -qx "pacman-key --recv-keys 40DFB630FF42BCFFB047046CF0134EE680CAC571 --keyserver keys.openpgp.org" "$sudo_log" ||
  fail "core imports only the pinned Omarchy signing key" "$(<"$sudo_log")"
grep -qx "pacman-key --lsign-key 40DFB630FF42BCFFB047046CF0134EE680CAC571" "$sudo_log" ||
  fail "core locally trusts the pinned Omarchy signing key" "$(<"$sudo_log")"
if (( $(wc -l <"$sudo_log") != 7 )); then
  fail "core makes exactly seven direct sudo invocations" "$(<"$sudo_log")"
fi
grep -qx 'sudo-keepalive' "$call_log" || fail "core starts the sudo keepalive for its package transaction" "$(<"$call_log")"
(( $(wc -l <"$call_log") == 1 )) || fail "core runs no link, lock, or theme steps" "$(<"$call_log")"
[[ ! -e $test_home/.config ]] || fail "core writes nothing to \$HOME"
pass "core installs its package group with sudo keepalive and nothing else"

# --- A key already present in pacman's keyring is pinned and locally trusted
# without another network retrieval.
reset_run
printf '[omarchy]\nServer = x\n' >"$pacman_conf"
OMARCHY_TEST_KEY_PRESENT=1 run_setup core >/dev/null
grep -qx "pacman-key --list-keys 40DFB630FF42BCFFB047046CF0134EE680CAC571" "$sudo_log" ||
  fail "core checks the complete pinned fingerprint" "$(<"$sudo_log")"
if grep -q "pacman-key --recv-keys" "$sudo_log"; then
  fail "core does not retrieve a signing key that is already present" "$(<"$sudo_log")"
fi
grep -qx "pacman-key --lsign-key 40DFB630FF42BCFFB047046CF0134EE680CAC571" "$sudo_log" ||
  fail "core locally trusts the existing pinned key" "$(<"$sudo_log")"
pass "core reuses an existing exact Omarchy signing key without retrieving it"

# --- The full Arch font package is a functional superset of Omarchy's basic
# package. Preserve it rather than provoking pacman to remove it as a conflict.
reset_run
printf '[omarchy]\nServer = x\n' >"$pacman_conf"
font_output=$(OMARCHY_TEST_INSTALLED_PACKAGES="ttf-jetbrains-mono-nerd" run_setup core)
grep -qx "pacman -Syu --needed hyprland foot quickshell omarchy-keyring" "$sudo_log" ||
  fail "core omits the conflicting basic font when the full font is installed" "$(<"$sudo_log")"
grep -q 'preserving installed package: ttf-jetbrains-mono-nerd' <<<"$font_output" ||
  fail "core reports that it preserves the installed full font" "$font_output"
status_output=$(OMARCHY_TEST_INSTALLED_PACKAGES="ttf-jetbrains-mono-nerd" run_setup status)
grep -q 'core: 4 of 5 packages missing' <<<"$status_output" ||
  fail "status counts the full font as satisfying the basic requirement" "$status_output"
pass "core preserves an installed full JetBrains Mono Nerd Font package"

# --- lock and session-entry are small explicit opt-ins.
reset_run
printf '[omarchy]\nServer = x\n' >"$pacman_conf"
OMARCHY_TEST_INSTALLED_PACKAGES="hyprland foot quickshell ttf-jetbrains-mono-nerd-basic omarchy-keyring" run_setup lock >/dev/null
grep -qx "apply-lock" "$call_log" || fail "lock runs omarchy-apply-lock" "$(<"$call_log")"
if (( $(wc -l <"$sudo_log") != 1 )); then
  fail "lock primes sudo and delegates the rest" "$(<"$sudo_log")"
fi
reset_run
printf '[omarchy]\nServer = x\n' >"$pacman_conf"
OMARCHY_TEST_INSTALLED_PACKAGES="hyprland foot quickshell ttf-jetbrains-mono-nerd-basic omarchy-keyring" run_setup session-entry >/dev/null
grep -qx "install -Dm644 $fake_checkout/default/wayland-sessions/omarchy.desktop $system_root/usr/local/share/wayland-sessions/omarchy.desktop" "$sudo_log" ||
  fail "session-entry installs the greeter session file" "$(<"$sudo_log")"
if (( $(wc -l <"$sudo_log") != 2 )); then
  fail "session-entry makes exactly two direct sudo invocations" "$(<"$sudo_log")"
fi
pass "lock and session-entry are independent opt-in stages"

# --- display-manager refuses to take over another greeter's systemd alias.
reset_run
printf '[omarchy]\nServer = x\n' >"$pacman_conf"
seed_display_manager_prerequisites
mkdir -p "$system_root/etc/systemd/system"
ln -s /usr/lib/systemd/system/gdm.service "$system_root/etc/systemd/system/display-manager.service"
if OMARCHY_TEST_INSTALLED_PACKAGES="hyprland foot quickshell ttf-jetbrains-mono-nerd-basic omarchy-keyring" \
  run_setup display-manager >/dev/null 2>&1; then
  fail "display-manager replaces an existing non-SDDM display manager"
fi
[[ ! -s $sudo_log ]] || fail "the display-manager conflict is refused before sudo" "$(<"$sudo_log")"
pass "display-manager refuses to replace another greeter"

# --- display-manager records one baseline, configures authenticated SDDM for
# the next boot, and rolls every owned path and boot target back exactly.
reset_run
printf '[omarchy]\nServer = x\n' >"$pacman_conf"
seed_display_manager_prerequisites
printf 'sddm=disabled\ndefault=multi-user.target\n' >"$systemctl_state"
mkdir -p \
  "$system_root/etc/sddm.conf.d" \
  "$system_root/usr/share/sddm/themes/omarchy" \
  "$system_root/var/lib/sddm"
echo 'original theme config' >"$system_root/etc/sddm.conf.d/10-theme.conf"
echo 'original autologin' >"$system_root/etc/sddm.conf.d/autologin.conf"
echo 'original theme asset' >"$system_root/usr/share/sddm/themes/omarchy/original.qml"
echo 'original state' >"$system_root/var/lib/sddm/state.conf"

core_packages="hyprland foot quickshell ttf-jetbrains-mono-nerd-basic omarchy-keyring"
OMARCHY_TEST_INSTALLED_PACKAGES="$core_packages" run_setup display-manager >/dev/null

grep -qx "pacman -Syu --needed qt6-wayland sddm" "$sudo_log" ||
  fail "display-manager installs exactly SDDM and Qt Wayland support" "$(<"$sudo_log")"
grep -qx "systemctl set-default graphical.target" "$sudo_log" ||
  fail "display-manager moves a multi-user host to graphical.target" "$(<"$sudo_log")"
grep -qx "systemctl enable sddm.service" "$sudo_log" ||
  fail "display-manager enables SDDM without starting it" "$(<"$sudo_log")"
grep -qx "install -Dm644 $fake_checkout/default/sddm/omarchy/Main.qml $system_root/usr/share/sddm/themes/omarchy/Main.qml" "$sudo_log" ||
  fail "display-manager publishes theme files through root-owned installs" "$(<"$sudo_log")"
if grep -q "cp -a $fake_checkout/default/sddm/omarchy" "$sudo_log"; then
  fail "display-manager preserves user ownership from the checkout into the greeter theme" "$(<"$sudo_log")"
fi
if grep -q "systemctl start\|systemctl restart\|autologin.conf.*install" "$sudo_log"; then
  fail "display-manager neither starts a live greeter nor installs autologin" "$(<"$sudo_log")"
fi
cmp -s "$fake_checkout/etc/sddm.conf.d/10-theme.conf" "$system_root/etc/sddm.conf.d/10-theme.conf" ||
  fail "display-manager installs the Omarchy SDDM theme selection"
cmp -s "$fake_checkout/default/wayland-sessions/omarchy.desktop" "$system_root/usr/local/share/wayland-sessions/omarchy.desktop" ||
  fail "display-manager installs the Omarchy UWSM session entry"
[[ ! -e $system_root/etc/sddm.conf.d/autologin.conf ]] || fail "display-manager removes autologin"
grep -qx 'original state' "$system_root/var/lib/sddm/state.conf" ||
  fail "display-manager overwrites pre-existing SDDM runtime state"

active_record="$test_home/.local/state/omarchy/dev-setup-desktop/display-manager/active"
[[ -f $active_record ]] || fail "display-manager records an active rollback transaction"
transaction_id=$(<"$active_record")
transaction_dir="$test_home/.local/state/omarchy/dev-setup-desktop/display-manager/transactions/$transaction_id"
[[ -d $transaction_dir ]] || fail "display-manager keeps the rollback payload"
[[ $(stat -c %a "$test_home/.local/state/omarchy/dev-setup-desktop/display-manager") == "700" ]] ||
  fail "display-manager keeps rollback state private to the user"
printf '[Last]\nSession=/usr/local/share/wayland-sessions/omarchy.desktop\nUser=remembered-user\n' \
  >"$system_root/var/lib/sddm/state.conf"
status_output=$(OMARCHY_TEST_INSTALLED_PACKAGES="$core_packages sddm qt6-wayland" run_setup status)
grep -q 'display-manager: configured and enabled' <<<"$status_output" ||
  fail "status recognizes a complete display-manager setup" "$status_output"
grep -q "display-manager-rollback: available (transaction $transaction_id)" <<<"$status_output" ||
  fail "status reports the active display-manager rollback" "$status_output"
pass "display-manager installs authenticated SDDM for the next boot with a rollback baseline"

: >"$sudo_log"
: >"$call_log"
OMARCHY_TEST_INSTALLED_PACKAGES="$core_packages sddm qt6-wayland" run_setup display-manager >/dev/null
[[ $(<"$active_record") == "$transaction_id" ]] || fail "an idempotent display-manager rerun replaces its original baseline"
(( $(find "$test_home/.local/state/omarchy/dev-setup-desktop/display-manager/transactions" -mindepth 1 -maxdepth 1 -type d | wc -l) == 1 )) ||
  fail "an idempotent display-manager rerun creates a second transaction"
grep -qx 'User=remembered-user' "$system_root/var/lib/sddm/state.conf" ||
  fail "a display-manager rerun clobbers SDDM's remembered runtime state"
pass "display-manager reruns preserve the original rollback boundary and SDDM runtime state"

: >"$sudo_log"
rollback_output=$(OMARCHY_TEST_INSTALLED_PACKAGES='' run_setup display-manager-rollback)
grep -qx "systemctl disable sddm.service" "$sudo_log" ||
  fail "rollback restores SDDM's disabled state" "$(<"$sudo_log")"
grep -qx "systemctl set-default multi-user.target" "$sudo_log" ||
  fail "rollback restores the prior default target" "$(<"$sudo_log")"
grep -qx 'original theme config' "$system_root/etc/sddm.conf.d/10-theme.conf" ||
  fail "rollback restores the original SDDM config"
grep -qx 'original autologin' "$system_root/etc/sddm.conf.d/autologin.conf" ||
  fail "rollback restores the original autologin policy"
grep -qx 'original theme asset' "$system_root/usr/share/sddm/themes/omarchy/original.qml" ||
  fail "rollback restores the original SDDM theme directory"
grep -qx 'original state' "$system_root/var/lib/sddm/state.conf" ||
  fail "rollback restores the original SDDM state"
[[ ! -e $system_root/usr/local/share/wayland-sessions/omarchy.desktop ]] ||
  fail "rollback removes a session entry that was absent before setup"
[[ ! -e $active_record ]] || fail "a completed rollback remains active"
grep -q 'retained packages: sddm qt6-wayland' <<<"$rollback_output" ||
  fail "rollback states its conservative package-retention boundary" "$rollback_output"
pass "display-manager rollback restores files, service state, and target while retaining inert packages"

# --- Rollback still restores its files and target, consumes the transaction,
# and reports the service-state problem if SDDM was removed out of band.
reset_run
printf '[omarchy]\nServer = x\n' >"$pacman_conf"
seed_display_manager_prerequisites
printf 'sddm=disabled\ndefault=multi-user.target\n' >"$systemctl_state"
OMARCHY_TEST_INSTALLED_PACKAGES="$core_packages" run_setup display-manager >/dev/null
grep -qx 'Session=omarchy.desktop' "$system_root/var/lib/sddm/state.conf" ||
  fail "display-manager does not seed the Omarchy session when SDDM runtime state is absent"
printf 'sddm=missing\ndefault=graphical.target\n' >"$systemctl_state"
rollback_output=$(OMARCHY_TEST_INSTALLED_PACKAGES='' run_setup display-manager-rollback 2>&1)
grep -q "Warning: could not restore SDDM's disabled state" <<<"$rollback_output" ||
  fail "rollback does not report a missing SDDM unit" "$rollback_output"
grep -qx 'default=multi-user.target' "$systemctl_state" ||
  fail "a missing SDDM unit prevents rollback from restoring the default target" "$(<"$systemctl_state")"
[[ ! -e $test_home/.local/state/omarchy/dev-setup-desktop/display-manager/active ]] ||
  fail "a missing SDDM unit leaves the rollback transaction armed"
pass "display-manager rollback completes when the SDDM unit disappeared"

# --- all: every stage in dependency order, repo missing from pacman.conf.
reset_run
printf '[core]\nInclude = /etc/pacman.d/mirrorlist\n' >"$pacman_conf"
run_setup all >/dev/null

grep -qx -- "-v" "$sudo_log" || fail "sudo credentials are primed" "$(<"$sudo_log")"
grep -q "cp -f $pacman_conf $pacman_conf.omarchy-dev-setup-desktop." "$sudo_log" ||
  fail "pacman.conf is backed up before the repo is added" "$(<"$sudo_log")"
grep -qx "pacman -Syu --needed hyprland foot quickshell ttf-jetbrains-mono-nerd-basic omarchy-keyring alsa-utils nautilus bluez grim brightnessctl" "$sudo_log" ||
  fail "all installs every package group in one transaction" "$(<"$sudo_log")"
grep -qx "install -Dm644 $fake_checkout/default/wayland-sessions/omarchy.desktop $system_root/usr/local/share/wayland-sessions/omarchy.desktop" "$sudo_log" ||
  fail "the session entry lands in /usr/local/share/wayland-sessions" "$(<"$sudo_log")"
if (( $(wc -l <"$sudo_log") != 8 )); then
  fail "no direct sudo invocations happen beyond the expected eight" "$(<"$sudo_log")"
fi
pass "direct sudo invocations are exactly the expected eight (dev-link and apply-lock contracts are theirs)"

grep -q "dev-link $fake_checkout --no-reboot --no-sudo-path" "$call_log" ||
  fail "the checkout is dev-linked without a reboot prompt or the dev sudoers policy" "$(<"$call_log")"
grep -qx "apply-lock" "$call_log" || fail "lock screen PAM setup runs" "$(<"$call_log")"
grep -qx "theme-set tokyo-night headless=1" "$call_log" || fail "the default theme is generated headlessly" "$(<"$call_log")"
grep -qx "theme-set-gnome" "$call_log" || fail "the default theme is synchronized to GTK applications" "$(<"$call_log")"
grep -qx "sudo-keepalive" "$call_log" || fail "package installation keeps sudo credentials alive" "$(<"$call_log")"
grep -qx "xdg-mime default org.gnome.Nautilus.desktop inode/directory" "$call_log" ||
  fail "the files stage registers the default directory handler" "$(<"$call_log")"
pass "dev-link, lock PAM, mime registration, and desktop theme generation all run"

uwsm_env="$test_home/.config/uwsm/env.d/10-omarchy"
[[ -f $uwsm_env ]] || fail "the uwsm environment file is written"
grep -q '/etc/omarchy.conf' "$uwsm_env" || fail "uwsm environment resolves OMARCHY_PATH from /etc/omarchy.conf" "$(<"$uwsm_env")"
grep -q 'default/bash/env-bootstrap' "$uwsm_env" || fail "uwsm environment sources env-bootstrap" "$(<"$uwsm_env")"
grep -q 'default/uwsm/env.d/10-omarchy' "$uwsm_env" || fail "uwsm environment chains the packaged session defaults" "$(<"$uwsm_env")"
if grep -qF "$fake_checkout" "$uwsm_env"; then
  fail "uwsm environment embeds no checkout pathname" "$(<"$uwsm_env")"
fi
pass "uwsm environment reproduces the packaged chain without embedding the path"

[[ -f $test_home/.local/share/fonts/omarchy.ttf ]] || fail "the icon font is installed"
[[ -f $test_home/.config/hypr/hyprland.lua ]] || fail "desktop configs are seeded"
[[ -f $test_home/.config/foot/foot.ini ]] || fail "foot config is seeded"
[[ -L $test_home/.config/btop/themes/current.theme ]] || fail "btop follows the generated Omarchy theme"
cmp -s "$fake_checkout/icon.txt" "$test_home/.config/omarchy/branding/about.txt" ||
  fail "config seeds the default About branding when absent"
cmp -s "$fake_checkout/logo.txt" "$test_home/.config/omarchy/branding/screensaver.txt" ||
  fail "config seeds the default screensaver branding when absent"
if [[ -e $test_home/.config/git || -e $test_home/.config/tmux ]]; then
  fail "non-desktop configs are not seeded by default"
fi
[[ -f $test_home/.local/state/omarchy/done/first-run-user ]] || fail "first-run provisioning is marked complete"
pass "font, desktop-only configs, and the first-run marker land in \$HOME"

# --- all with existing repo, --no-session-entry, --all-configs, theme
# --- normalization, and backup of a pre-existing uwsm env file.
reset_run
mkdir -p "$test_home/.config/uwsm/env.d"
echo 'user tweak' >"$test_home/.config/uwsm/env.d/10-omarchy"
printf '[omarchy]\nSigLevel = Optional TrustAll\nServer = https://pkgs.omarchy.org/stable/$arch\n' >"$pacman_conf"
run_setup all --no-session-entry --all-configs --theme "Catppuccin" >/dev/null

if grep -q "tee -a $pacman_conf" "$sudo_log"; then
  fail "an existing [omarchy] repo is left alone" "$(<"$sudo_log")"
fi
if grep -q "wayland-sessions" "$sudo_log"; then
  fail "--no-session-entry skips the greeter entry" "$(<"$sudo_log")"
fi
if (( $(wc -l <"$sudo_log") != 5 )); then
  fail "only sudo -v, pinned key setup, and pacman run as direct sudo invocations" "$(<"$sudo_log")"
fi
grep -qx "theme-set catppuccin headless=1" "$call_log" || fail "theme names are normalized like omarchy-theme-set" "$(<"$call_log")"
[[ -f $test_home/.config/git/config && -f $test_home/.config/tmux/tmux.conf ]] ||
  fail "--all-configs seeds every shipped config"
pass "existing repo, --no-session-entry, --all-configs, and normalization behave"

# uwsm sources every file in env.d, so the backup must land elsewhere and
# env.d must hold nothing but the active file.
mapfile -t uwsm_env_dir_files < <(find "$test_home/.config/uwsm/env.d" -type f)
if (( ${#uwsm_env_dir_files[@]} != 1 )) || [[ ${uwsm_env_dir_files[0]} != "$test_home/.config/uwsm/env.d/10-omarchy" ]]; then
  fail "env.d contains only the active uwsm env file" "${uwsm_env_dir_files[*]}"
fi
mapfile -t uwsm_backups < <(find "$test_home/.config/uwsm/backups" -name '10-omarchy.bak.*')
(( ${#uwsm_backups[@]} == 1 )) || fail "a pre-existing uwsm env file is backed up exactly once outside env.d"
grep -qx 'user tweak' "${uwsm_backups[0]}" || fail "the uwsm backup preserves the previous content"
grep -q '/etc/omarchy.conf' "$test_home/.config/uwsm/env.d/10-omarchy" ||
  fail "the uwsm env file is replaced with the bootstrap version"
pass "a pre-existing uwsm env file is backed up outside env.d, which keeps only the active file"

# --- status after a full run reports completion of the user-level stages.
status_output=$(OMARCHY_TEST_PRODUCT_INSTALLED='' run_setup status)
grep -q 'link: linked to this checkout' <<<"$status_output" || fail "status verifies the link points at this checkout" "$status_output"
grep -q 'link: uwsm environment present' <<<"$status_output" || fail "status sees the uwsm environment" "$status_output"
grep -q 'config: seeded' <<<"$status_output" || fail "status sees the seeded config" "$status_output"
pass "status reflects completed stages"

mv "$test_home/.config/omarchy/branding/screensaver.txt" "$test_home/.config/omarchy/branding/screensaver.txt.missing"
status_output=$(OMARCHY_TEST_PRODUCT_INSTALLED='' run_setup status)
grep -q 'config: not seeded' <<<"$status_output" ||
  fail "status reports config incomplete when required branding is absent" "$status_output"
pass "status includes required runtime branding in config completeness"
