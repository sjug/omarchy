#!/bin/bash

set -euo pipefail

# shellcheck disable=SC1091
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
installed_state="$test_tmp/installed.state"

mkdir -p "$stub_bin" "$test_home" \
  "$fake_checkout/bin" "$fake_checkout/install/helpers" \
  "$fake_checkout/migrations/desktop-overlay" \
  "$fake_checkout/themes/tokyo-night" "$fake_checkout/themes/catppuccin" \
  "$fake_checkout/default/fonts/omarchy" "$fake_checkout/default/bash" \
  "$fake_checkout/default/uwsm/env.d" "$fake_checkout/default/wayland-sessions" \
  "$fake_checkout/default/sddm/omarchy" "$fake_checkout/etc/sddm.conf.d" \
  "$fake_checkout/config/hypr" "$fake_checkout/config/foot" \
  "$fake_checkout/config/git" "$fake_checkout/config/tmux" "$system_root"

cp "$ROOT/bin/omarchy-overlay-setup" "$fake_checkout/bin/"
cp "$ROOT/bin/omarchy-installation-type" "$fake_checkout/bin/"
cp "$ROOT/bin/omarchy-overlay-stages" "$fake_checkout/bin/"
cp "$ROOT/bin/omarchy-overlay-register" "$fake_checkout/bin/"
cp "$ROOT/bin/omarchy-overlay-status" "$fake_checkout/bin/"
cp "$ROOT/bin/omarchy-dev-setup-desktop" "$fake_checkout/bin/"
cp "$ROOT/bin/omarchy-cmd-present" "$fake_checkout/bin/"
cp "$ROOT/bin/omarchy-refresh-config" "$fake_checkout/bin/"
cp "$ROOT/bin/omarchy-done" "$fake_checkout/bin/"
cp "$ROOT/install/helpers/runtime-link.sh" "$fake_checkout/install/helpers/"

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
: >"$fake_checkout/migrations/desktop-overlay/100-existing.sh"

cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_TEST_SUDO_LOG"
if [[ $1 == "pacman-key" && $2 == "--list-keys" && ${OMARCHY_TEST_KEY_PRESENT:-0} == 0 ]]; then
  exit 1
fi
case "$1" in
  pacman)
    if [[ ${OMARCHY_TEST_PACMAN_MUTATES:-0} == "1" ]]; then
      "$@"
    fi
    exit
    ;;
  cp|install|mv|rm|systemctl|tee|test)
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
if [[ $1 == "-Qq" ]]; then
  shift
  result=0
  for requested in "$@"; do
    if "$0" -Q "$requested"; then
      echo "$requested"
    else
      result=1
    fi
  done
  exit "$result"
fi
if [[ ( $1 == "-Q" || $1 == "-Qq" ) && -n ${2:-} ]]; then
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
  if [[ -f ${OMARCHY_TEST_INSTALLED_STATE:-} ]] && grep -Fxq "$2" "$OMARCHY_TEST_INSTALLED_STATE"; then
    exit 0
  fi
  exit 1
fi
if [[ $1 == "-Syu" ]]; then
  for package in "$@"; do
    [[ $package == -* ]] || printf '%s\n' "$package" >>"$OMARCHY_TEST_INSTALLED_STATE"
  done
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
printf 'export OMARCHY_PATH=%s\n' "$1" >"$OMARCHY_OVERLAY_SETUP_OMARCHY_CONF"
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
    OMARCHY_TEST_INSTALLED_STATE="$installed_state" \
    OMARCHY_TEST_PACMAN_MUTATES="${OMARCHY_TEST_PACMAN_MUTATES:-0}" \
    OMARCHY_TEST_SYSTEMCTL_STATE="$systemctl_state" \
    OMARCHY_UPDATE_UNATTENDED="${OMARCHY_UPDATE_UNATTENDED:-0}" \
    OMARCHY_OVERLAY_SETUP_PACMAN_CONF="$pacman_conf" \
    OMARCHY_OVERLAY_SETUP_OMARCHY_CONF="$omarchy_conf" \
    OMARCHY_OVERLAY_SETUP_SYSTEM_ROOT="$system_root" \
    bash "$fake_checkout/bin/omarchy-overlay-setup" "$@"
}

reset_run() {
  rm -rf "$test_home"
  mkdir -p "$test_home"
  rm -rf "$system_root"
  mkdir -p "$system_root"
  rm -f "$omarchy_conf"
  rm -f "$installed_state"
  printf 'sddm=disabled\ndefault=graphical.target\n' >"$systemctl_state"
  : >"$sudo_log"
  : >"$call_log"
}

seed_registration() {
  local stages="$1"
  mkdir -p "$system_root/etc/omarchy"
  printf 'OMARCHY_INSTALLATION=desktop_overlay\nOMARCHY_DESKTOP_OWNER=%s\nOMARCHY_DESKTOP_STAGES=%s\n' \
    "$(id -un)" "$stages" >"$system_root/etc/omarchy/installation.conf"
}

seed_config_prerequisites() {
  printf 'export OMARCHY_PATH=%s\n' "$fake_checkout" >"$omarchy_conf"
  mkdir -p \
    "$test_home/.config/hypr" \
    "$test_home/.config/omarchy/branding" \
    "$test_home/.config/btop/themes" \
    "$test_home/.config/uwsm/env.d" \
    "$test_home/.local/state/omarchy/done"
  : >"$test_home/.config/hypr/hyprland.lua"
  : >"$test_home/.config/omarchy/branding/about.txt"
  : >"$test_home/.config/omarchy/branding/screensaver.txt"
  : >"$test_home/.local/state/omarchy/done/first-run-user"
  ln -s "$test_home/generated-btop.theme" "$test_home/.config/btop/themes/current.theme"
  cat >"$test_home/.config/uwsm/env.d/10-omarchy" <<'ENV'
# Written by omarchy-overlay-setup. uwsm doesn't source /etc/profile.d,
# so resolve OMARCHY_PATH, then load the packaged session environment
# (session defaults, user overrides, mise activation) from the checkout.
[ -r /etc/omarchy.conf ] && . /etc/omarchy.conf
[ -r "${OMARCHY_PATH:-/usr/share/omarchy}/default/bash/env-bootstrap" ] && . "${OMARCHY_PATH:-/usr/share/omarchy}/default/bash/env-bootstrap"
[ -r "${OMARCHY_PATH:-/usr/share/omarchy}/default/uwsm/env.d/10-omarchy" ] && . "${OMARCHY_PATH:-/usr/share/omarchy}/default/uwsm/env.d/10-omarchy"
ENV
}

seed_display_manager_prerequisites() {
  seed_registration core,link,config
  seed_config_prerequisites
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

# --- Checkout entry points locate their sibling orchestrator without relying
# on a link stage having already put the checkout's bin directory on PATH.
for wrapper in omarchy-dev-setup-desktop omarchy-overlay-register omarchy-overlay-status; do
  wrapper_output=$(env -i HOME="$test_home" PATH=/usr/bin bash "$fake_checkout/bin/$wrapper" --help)
  grep -q '^Usage: omarchy-overlay-setup ' <<<"$wrapper_output" ||
    fail "$wrapper cannot launch the sibling setup command before PATH is configured" "$wrapper_output"
done
if env -i HOME="$test_home" PATH=/usr/bin bash "$fake_checkout/bin/omarchy-overlay-status" unknown-stage >/dev/null 2>&1; then
  fail "the overlay status wrapper silently drops its arguments"
fi
pass "checkout wrappers work before link and forward their arguments"

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
  if fakeroot bash "$fake_checkout/bin/omarchy-overlay-setup" core >/dev/null 2>&1; then
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

# The compatibility status command remains diagnostic on a packaged product;
# it must not mislabel the product descriptor as a repairable overlay failure.
reset_run
mkdir -p "$system_root/etc/omarchy"
printf 'OMARCHY_INSTALLATION=product\n' >"$system_root/etc/omarchy/installation.conf"
status_output=$(OMARCHY_TEST_PRODUCT_INSTALLED=omarchy run_setup status)
grep -q 'installation:  packaged Omarchy product' <<<"$status_output" ||
  fail "overlay status does not identify a packaged product" "$status_output"
grep -q 'desktop overlay not applicable' <<<"$status_output" ||
  fail "overlay status presents a product as an invalid overlay" "$status_output"
if grep -q 'repair' <<<"$status_output"; then
  fail "overlay status tells a product system to convert itself into an overlay" "$status_output"
fi
[[ ! -s $sudo_log ]] || fail "product status is not read-only" "$(<"$sudo_log")"
pass "overlay status reports product systems without an overlay repair hint"

# --- config depends on link.
reset_run
printf '[omarchy]\nServer = x\n' >"$pacman_conf"
if run_setup config >/dev/null 2>&1; then
  fail "config without link is refused"
fi
config_err=$(run_setup config 2>&1 || true)
grep -q "register an existing overlay" <<<"$config_err" ||
  fail "the config-without-link error names the link stage" "$config_err"
pass "config requires link and says so"

# --- An omarchy.conf pointing at a different checkout is not a valid link.
reset_run
printf '[omarchy]\nServer = x\n' >"$pacman_conf"
printf 'export OMARCHY_PATH=/definitely/wrong\n' >"$omarchy_conf"
seed_registration core,link
if OMARCHY_TEST_INSTALLED_PACKAGES="hyprland foot quickshell ttf-jetbrains-mono-nerd-basic omarchy-keyring" run_setup config >/dev/null 2>&1; then
  fail "config with a mislinked omarchy.conf is refused"
fi
mislink_err=$(OMARCHY_TEST_INSTALLED_PACKAGES="hyprland foot quickshell ttf-jetbrains-mono-nerd-basic omarchy-keyring" run_setup config 2>&1 || true)
grep -q "points at /definitely/wrong, not this checkout" <<<"$mislink_err" ||
  fail "the mislink error names the wrong path" "$mislink_err"
if OMARCHY_TEST_INSTALLED_PACKAGES="hyprland foot quickshell ttf-jetbrains-mono-nerd-basic omarchy-keyring" run_setup audio >/dev/null 2>&1; then
  fail "a non-link setup stage can extend a ledger from the wrong checkout"
fi
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

# An existing checkout link with no descriptor is the legacy monolithic setup,
# not a fresh staged install. Do not create a core-only ledger that immediately
# makes its already-installed config unreachable through the staged interface.
reset_run
printf '[omarchy]\nServer = x\n' >"$pacman_conf"
printf 'export OMARCHY_PATH=%s\n' "$fake_checkout" >"$omarchy_conf"
if run_setup core >"$test_tmp/legacy-core.out" 2>"$test_tmp/legacy-core.err"; then
  fail "setup core creates a partial ledger over an existing checkout desktop"
fi
grep -q '^  ./bin/omarchy-overlay-register core link config audio files connectivity capture power lock session-entry display-manager$' "$test_tmp/legacy-core.err" ||
  fail "legacy checkout refusal does not lead with the complete adoption command" "$(<"$test_tmp/legacy-core.err")"
grep -qi 'omit stages that are not installed' "$test_tmp/legacy-core.err" ||
  fail "legacy checkout refusal does not explain how to tailor registration" "$(<"$test_tmp/legacy-core.err")"
[[ ! -s $sudo_log ]] || fail "legacy checkout detection happens after system changes" "$(<"$sudo_log")"
[[ ! -e $system_root/etc/omarchy/installation.conf ]] || fail "legacy checkout refusal writes a partial descriptor"
pass "legacy checkout desktops are directed to one-step adoption before setup"

# --- Config writes user state plus the root-owned stage ledger once core and
# link are already recorded.
reset_run
printf '[omarchy]\nServer = x\n' >"$pacman_conf"
printf 'export OMARCHY_PATH=%s\n' "$fake_checkout" >"$omarchy_conf"
seed_registration core,link
mkdir -p "$test_home/.config/omarchy/branding"
echo 'custom about branding' >"$test_home/.config/omarchy/branding/about.txt"
echo 'custom screensaver branding' >"$test_home/.config/omarchy/branding/screensaver.txt"
OMARCHY_TEST_INSTALLED_PACKAGES="hyprland foot quickshell ttf-jetbrains-mono-nerd-basic omarchy-keyring" run_setup config >/dev/null
if (( $(wc -l <"$sudo_log") != 2 )); then
  fail "config uses sudo only to validate credentials and update the stage ledger" "$(<"$sudo_log")"
fi
grep -qx 'sudo-keepalive' "$call_log" ||
  fail "config does not keep its sudo credential alive through the final ledger write" "$(<"$call_log")"
btop_theme_link="$test_home/.config/btop/themes/current.theme"
[[ -L $btop_theme_link ]] || fail "config creates the btop current-theme symlink"
[[ $(readlink "$btop_theme_link") == "$test_home/.local/state/omarchy/current/theme/btop.theme" ]] ||
  fail "btop current-theme symlink targets the generated Omarchy theme" "$(readlink "$btop_theme_link")"
grep -qx 'custom about branding' "$test_home/.config/omarchy/branding/about.txt" ||
  fail "config preserves existing About branding"
grep -qx 'custom screensaver branding' "$test_home/.config/omarchy/branding/screensaver.txt" ||
  fail "config preserves existing screensaver branding"
pass "config preserves custom branding, links btop to the theme, and records completion"
grep -qx 'theme-set-gnome' "$call_log" ||
  fail "config synchronizes the generated theme to GTK applications" "$(<"$call_log")"

# --- Invalid branding targets are refused before config writes begin. A
# successful config stage must never leave a runtime path it knows is broken.
reset_run
printf '[omarchy]\nServer = x\n' >"$pacman_conf"
printf 'export OMARCHY_PATH=%s\n' "$fake_checkout" >"$omarchy_conf"
seed_registration core,link
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
if (( $(wc -l <"$sudo_log") != 8 )); then
  fail "core makes exactly eight direct sudo invocations, including the stage ledger" "$(<"$sudo_log")"
fi
grep -qx 'sudo-keepalive' "$call_log" || fail "core starts the sudo keepalive for its package transaction" "$(<"$call_log")"
(( $(wc -l <"$call_log") == 1 )) || fail "core runs no link, lock, or theme steps" "$(<"$call_log")"
[[ ! -e $test_home/.config ]] || fail "core writes nothing to \$HOME"
pass "core installs its package group with sudo keepalive and nothing else"

# A freshly recorded core-only overlay has no runtime link yet. The next
# piecemeal stage must be able to classify that descriptor, establish the link,
# and extend the ledger without requiring a new shell first.
: >"$sudo_log"
: >"$call_log"
OMARCHY_TEST_INSTALLED_PACKAGES="hyprland foot quickshell ttf-jetbrains-mono-nerd-basic omarchy-keyring" run_setup link >/dev/null
expected_descriptor=$'OMARCHY_INSTALLATION=desktop_overlay\nOMARCHY_DESKTOP_OWNER='"$(id -un)"$'\nOMARCHY_DESKTOP_STAGES=core,link'
[[ $(<"$system_root/etc/omarchy/installation.conf") == "$expected_descriptor" ]] ||
  fail "link extends a core-only overlay ledger" "$(<"$system_root/etc/omarchy/installation.conf")"
grep -qx "tee $omarchy_conf" "$sudo_log" ||
  fail "link writes the runtime checkout immediately after a core-only setup" "$(<"$sudo_log")"
pass "piecemeal core then link setup works without restarting the shell"

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

# --- register adopts a fully probed pre-existing overlay without replaying
# installation work. This is the one-time transition used by existing hosts.
reset_run
printf '[omarchy]\nServer = x\n' >"$pacman_conf"
seed_config_prerequisites
core_packages="hyprland foot quickshell ttf-jetbrains-mono-nerd-basic omarchy-keyring"
OMARCHY_TEST_INSTALLED_PACKAGES="$core_packages" run_setup register core link config >/dev/null
descriptor="$system_root/etc/omarchy/installation.conf"
expected_descriptor=$'OMARCHY_INSTALLATION=desktop_overlay\nOMARCHY_DESKTOP_OWNER='"$(id -un)"$'\nOMARCHY_DESKTOP_STAGES=core,link,config'
[[ $(<"$descriptor") == "$expected_descriptor" ]] || fail "registration writes the canonical root-owned stage ledger" "$(<"$descriptor")"
[[ ! -s $call_log ]] || fail "registration replays no setup actions" "$(<"$call_log")"
if (( $(wc -l <"$sudo_log") != 2 )); then
  fail "registration uses sudo only for validation and descriptor installation" "$(<"$sudo_log")"
fi
[[ -f $test_home/.local/state/omarchy/desktop-overlay-migrations/100-existing.sh ]] || fail "registration establishes the separate overlay migration baseline"
[[ -f $test_home/.local/state/omarchy/desktop-overlay-migrations/.baseline-established ]] || fail "registration records that its migration baseline was established"
pass "registration records an existing overlay only after every selected stage probes successfully"

reset_run
printf '[omarchy]\nServer = x\n' >"$pacman_conf"
if OMARCHY_TEST_INSTALLED_PACKAGES="$core_packages" run_setup register link >"$test_tmp/register-link.out" 2>"$test_tmp/register-link.err"; then
  fail "registration accepts link without core and writes an unusable ledger"
fi
grep -q "registering 'link' also requires the core stage" "$test_tmp/register-link.err" ||
  fail "link-only registration explains its missing core dependency" "$(<"$test_tmp/register-link.err")"
[[ ! -e $system_root/etc/omarchy/installation.conf ]] || fail "link-only registration writes a descriptor"
pass "registration cannot write a link-only ledger that every overlay command rejects"

# --- An explicit repair replaces invalid or stale descriptors, but only after
# the requested stages pass the same adoption probes as normal registration.
for broken_descriptor in \
  'not-an-assignment' \
  'OMARCHY_INSTALLATION=product'; do
  reset_run
  printf '[omarchy]\nServer = x\n' >"$pacman_conf"
  mkdir -p "$system_root/etc/omarchy"
  printf '%s\n' "$broken_descriptor" >"$system_root/etc/omarchy/installation.conf"
  OMARCHY_TEST_INSTALLED_PACKAGES="$core_packages" run_setup register --repair core >/dev/null
  grep -qx 'OMARCHY_INSTALLATION=desktop_overlay' "$system_root/etc/omarchy/installation.conf" ||
    fail "register --repair did not replace a broken descriptor" "$(<"$system_root/etc/omarchy/installation.conf")"
  grep -qx "OMARCHY_DESKTOP_OWNER=$(id -un)" "$system_root/etc/omarchy/installation.conf" ||
    fail "register --repair did not record the current owner" "$(<"$system_root/etc/omarchy/installation.conf")"
  grep -qx 'OMARCHY_DESKTOP_STAGES=core' "$system_root/etc/omarchy/installation.conf" ||
    fail "register --repair did not write the probed stage ledger" "$(<"$system_root/etc/omarchy/installation.conf")"
  [[ -f $test_home/.local/state/omarchy/desktop-overlay-migrations/100-existing.sh ]] ||
    fail "first overlay registration through repair did not baseline existing migrations"
  [[ -f $test_home/.local/state/omarchy/desktop-overlay-migrations/.baseline-established ]] ||
    fail "first overlay registration through repair did not write its baseline sentinel"
done
pass "register --repair establishes a baseline whenever its sentinel is absent"

reset_run
printf '[omarchy]\nServer = x\n' >"$pacman_conf"
mkdir -p "$system_root/etc/omarchy" "$test_home/.local/state/omarchy/desktop-overlay-migrations"
printf 'not-an-assignment\n' >"$system_root/etc/omarchy/installation.conf"
touch "$test_home/.local/state/omarchy/desktop-overlay-migrations/.baseline-established"
OMARCHY_TEST_INSTALLED_PACKAGES="$core_packages" run_setup register --repair core >/dev/null
[[ ! -e $test_home/.local/state/omarchy/desktop-overlay-migrations/100-existing.sh ]] ||
  fail "repair re-baselines migrations despite an existing sentinel"
pass "register --repair preserves pending migrations when the baseline sentinel exists"

reset_run
printf '[omarchy]\nServer = x\n' >"$pacman_conf"
seed_config_prerequisites
mkdir -p "$system_root/usr/local/share/wayland-sessions"
cp "$fake_checkout/default/wayland-sessions/omarchy.desktop" "$system_root/usr/local/share/wayland-sessions/omarchy.desktop"
if OMARCHY_TEST_INSTALLED_PACKAGES="$core_packages sddm qt6-wayland" \
  run_setup register core link config display-manager >"$test_tmp/register-dm.out" 2>"$test_tmp/register-dm.err"; then
  fail "registration accepts display-manager packages without the configured greeter"
fi
grep -q "SDDM is not fully configured" "$test_tmp/register-dm.err" ||
  fail "display-manager registration reports incomplete greeter state" "$(<"$test_tmp/register-dm.err")"
[[ ! -s $sudo_log ]] || fail "failed display-manager registration happens before sudo" "$(<"$sudo_log")"
pass "display-manager registration proves the greeter configuration, not only its packages"

reset_run
printf '[omarchy]\nServer = x\n' >"$pacman_conf"
seed_registration core,audio,files
OMARCHY_TEST_INSTALLED_PACKAGES="$core_packages" run_setup packages core audio files >/dev/null
grep -qx 'pacman -Syu --needed --noconfirm hyprland foot quickshell ttf-jetbrains-mono-nerd-basic omarchy-keyring alsa-utils nautilus' "$sudo_log" ||
  fail "package reconciliation uses one transaction for the recorded package stages" "$(<"$sudo_log")"
grep -qx "pacman-key --list-keys 40DFB630FF42BCFFB047046CF0134EE680CAC571" "$sudo_log" ||
  fail "package reconciliation does not verify its pinned signing key" "$(<"$sudo_log")"
if grep -q "tee -a $pacman_conf\|xdg-mime\|install -Dm644.*installation.conf" "$sudo_log" "$call_log"; then
  fail "package reconciliation rewrites a present repository, file-stage preference, or ledger" "sudo:\n$(<"$sudo_log")\ncalls:\n$(<"$call_log")"
fi
if run_setup packages capture >/dev/null 2>&1; then
  fail "package reconciliation accepts an unrecorded stage"
fi
pass "package reconciliation is ledger-limited, noninteractive, and has no stage-file side effects"

reset_run
printf '[core]\nInclude = /etc/pacman.d/mirrorlist\n' >"$pacman_conf"
seed_registration core
OMARCHY_TEST_INSTALLED_PACKAGES="$core_packages" run_setup packages core >/dev/null
grep -qx '\[omarchy\]' "$pacman_conf" || fail "package reconciliation does not restore a missing Omarchy repository"
repo_line=$(grep -n "tee -a $pacman_conf" "$sudo_log" | cut -d: -f1)
key_line=$(grep -n 'pacman-key --lsign-key' "$sudo_log" | cut -d: -f1)
pacman_line=$(grep -n '^pacman -Syu' "$sudo_log" | cut -d: -f1)
(( repo_line < key_line && key_line < pacman_line )) ||
  fail "package reconciliation does not restore repository, key, then packages in order" "$(<"$sudo_log")"
pass "package reconciliation restores a missing repository and pinned signing key"

# An invalid descriptor cannot block restoration of missing core packages.
# Repair installs and verifies core first, then replaces only the bad ledger.
reset_run
printf '[core]\nInclude = /etc/pacman.d/mirrorlist\n' >"$pacman_conf"
mkdir -p "$system_root/etc/omarchy"
printf 'not-an-assignment\n' >"$system_root/etc/omarchy/installation.conf"
OMARCHY_TEST_PACMAN_MUTATES=1 run_setup core --repair >/dev/null
expected_descriptor=$'OMARCHY_INSTALLATION=desktop_overlay\nOMARCHY_DESKTOP_OWNER='"$(id -un)"$'\nOMARCHY_DESKTOP_STAGES=core'
[[ $(<"$system_root/etc/omarchy/installation.conf") == "$expected_descriptor" ]] ||
  fail "setup core --repair did not replace the invalid descriptor with its verified stage" "$(<"$system_root/etc/omarchy/installation.conf")"
compgen -G "$system_root/etc/omarchy/installation.conf.omarchy-overlay-repair.*.bak" >/dev/null ||
  fail "setup core --repair did not preserve the invalid descriptor"
[[ -f $test_home/.local/state/omarchy/desktop-overlay-migrations/.baseline-established ]] ||
  fail "setup core --repair did not establish migration state"
grep -qx 'pacman -Syu --needed hyprland foot quickshell ttf-jetbrains-mono-nerd-basic omarchy-keyring' "$sudo_log" ||
  fail "setup core --repair did not restore missing core packages" "$(<"$sudo_log")"
pass "setup core --repair recovers an invalid descriptor and missing core packages atomically"

reset_run
printf '[omarchy]\nServer = x\n' >"$pacman_conf"
seed_registration core,lock
OMARCHY_TEST_INSTALLED_PACKAGES="$core_packages" run_setup artifacts lock >/dev/null
grep -qx 'apply-lock' "$call_log" || fail "artifact reconciliation reapplies the recorded lock artifact" "$(<"$call_log")"
if grep -q 'pacman\|installation.conf' "$sudo_log"; then
  fail "artifact reconciliation starts a package transaction or rewrites the stage ledger" "$(<"$sudo_log")"
fi
if run_setup artifacts session-entry >/dev/null 2>&1; then
  fail "artifact reconciliation accepts an unrecorded static stage"
fi
pass "artifact reconciliation is ledger-limited and package-free"

# --- lock and session-entry are small explicit opt-ins.
reset_run
printf '[omarchy]\nServer = x\n' >"$pacman_conf"
seed_registration core
OMARCHY_TEST_INSTALLED_PACKAGES="hyprland foot quickshell ttf-jetbrains-mono-nerd-basic omarchy-keyring" run_setup lock >/dev/null
grep -qx "apply-lock" "$call_log" || fail "lock runs omarchy-apply-lock" "$(<"$call_log")"
if (( $(wc -l <"$sudo_log") != 2 )); then
  fail "lock primes sudo, delegates PAM setup, and records the stage" "$(<"$sudo_log")"
fi
reset_run
printf '[omarchy]\nServer = x\n' >"$pacman_conf"
seed_registration core
OMARCHY_TEST_INSTALLED_PACKAGES="hyprland foot quickshell ttf-jetbrains-mono-nerd-basic omarchy-keyring" run_setup session-entry >/dev/null
grep -qx "install -Dm644 $fake_checkout/default/wayland-sessions/omarchy.desktop $system_root/usr/local/share/wayland-sessions/omarchy.desktop" "$sudo_log" ||
  fail "session-entry installs the greeter session file" "$(<"$sudo_log")"
if (( $(wc -l <"$sudo_log") != 3 )); then
  fail "session-entry makes exactly three direct sudo invocations, including the stage ledger" "$(<"$sudo_log")"
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

# A user may deliberately switch to another greeter after initially recording
# display-manager. Update-time artifact checks must explain how to stop managing
# that stale stage without changing either greeter or the rollback files.
seed_registration core,link,config,session-entry,display-manager
: >"$sudo_log"
if run_setup artifacts --check display-manager >"$test_tmp/stale-dm.out" 2>"$test_tmp/stale-dm.err"; then
  fail "display-manager artifact preflight accepts a different active greeter"
fi
grep -q 'omarchy overlay register --repair core link config session-entry' "$test_tmp/stale-dm.err" ||
  fail "stale display-manager guidance does not print the exact repaired stage ledger" "$(<"$test_tmp/stale-dm.err")"
grep -q 'current greeter and stored rollback files will remain unchanged' "$test_tmp/stale-dm.err" ||
  fail "stale display-manager guidance does not describe its non-destructive effect" "$(<"$test_tmp/stale-dm.err")"
grep -q 'omarchy overlay setup display-manager' "$test_tmp/stale-dm.err" ||
  fail "stale display-manager guidance does not explain re-adoption" "$(<"$test_tmp/stale-dm.err")"
[[ ! -s $sudo_log ]] || fail "stale display-manager preflight changes host state" "$(<"$sudo_log")"
pass "stale display-manager preflight provides a non-destructive repair and re-adoption path"

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
grep -qx "test -e $system_root/var/lib/sddm/state.conf" "$sudo_log" ||
  fail "display-manager does not inspect protected SDDM runtime state through sudo" "$(<"$sudo_log")"
grep -qx 'original state' "$transaction_dir/backup/7" ||
  fail "display-manager rollback did not capture the protected SDDM runtime state"
[[ $(stat -c %a "$test_home/.local/state/omarchy/dev-setup-desktop/display-manager") == "700" ]] ||
  fail "display-manager keeps rollback state private to the user"
printf '[Last]\nSession=/usr/local/share/wayland-sessions/omarchy.desktop\nUser=remembered-user\n' \
  >"$system_root/var/lib/sddm/state.conf"
# The real SDDM state directory is private to sddm. Status must treat it as
# runtime state and remain accurate without traversing it as the desktop user.
chmod 000 "$system_root/var/lib/sddm"
status_output=$(OMARCHY_TEST_INSTALLED_PACKAGES="$core_packages sddm qt6-wayland" run_setup status)
chmod 0755 "$system_root/var/lib/sddm"
grep -q 'display-manager: configured and enabled' <<<"$status_output" ||
  fail "status recognizes a complete display-manager setup" "$status_output"
grep -q "display-manager-rollback: available (transaction $transaction_id)" <<<"$status_output" ||
  fail "status reports the active display-manager rollback" "$status_output"
pass "display-manager installs authenticated SDDM for the next boot with a rollback baseline"

# A release must reject unsupported managed paths before touching an existing
# transaction. The writer also enforces this independently of preflight.
cp -a "$transaction_dir" "$test_tmp/transaction-before-rejection"
cp "$fake_checkout/bin/omarchy-overlay-setup" "$test_tmp/setup-before-rejection"
sed -i '/^display_manager_paths=(/a display_manager_paths+=("$(system_path /etc/pam.d/sddm)")' "$fake_checkout/bin/omarchy-overlay-setup"
for check_option in --check ''; do
  : >"$sudo_log"
  : >"$call_log"
  check_args=(artifacts)
  [[ -z $check_option ]] || check_args+=("$check_option")
  if OMARCHY_TEST_INSTALLED_PACKAGES="$core_packages sddm qt6-wayland" run_setup "${check_args[@]}" display-manager >"$test_tmp/scope.out" 2>&1; then
    fail "unsupported managed path reaches artifact application"
  fi
  grep -q 'managed display-manager paths are outside the supported scope' "$test_tmp/scope.out" || fail "scope refusal lacks guidance"
  [[ ! -s $sudo_log && ! -s $call_log ]] || fail "scope refusal follows privileged or artifact work"
  diff -r "$test_tmp/transaction-before-rejection" "$transaction_dir" || fail "scope rejection changes rollback data"
  [[ $(<"$active_record") == "$transaction_id" ]] || fail "scope rejection changes the active record"
done
(
  # Load the real inventory functions without executing the setup orchestrator.
  # shellcheck disable=SC1090
  source <(sed -n '/^validate_display_manager_paths()/,/^capture_display_manager_path()/p' "$fake_checkout/bin/omarchy-overlay-setup" | sed '$d')
  # Consumed by the real writer sourced above.
  # shellcheck disable=SC2034
  display_manager_recorded_paths=("$system_root/etc/pam.d/sddm")
  if write_display_manager_inventory "$transaction_dir" >"$test_tmp/writer.out" 2>&1; then
    fail "inventory writer accepts an unsupported path"
  fi
)
diff -r "$test_tmp/transaction-before-rejection" "$transaction_dir" || fail "writer refusal changes rollback data or creates inventory.new"
cp "$test_tmp/setup-before-rejection" "$fake_checkout/bin/omarchy-overlay-setup"
OMARCHY_TEST_INSTALLED_PACKAGES="$core_packages sddm qt6-wayland" run_setup artifacts --check display-manager >/dev/null
pass "unsupported managed paths cannot poison a transaction through preflight or its writer"

# Old records have no inventory. Even a reordered future managed-path array
# must use the frozen legacy mapping to validate and restore those backups.
rm "$transaction_dir/inventory"
sed -i '/^display_manager_paths=(/a display_manager_paths=("${display_manager_paths[1]}" "${display_manager_paths[0]}" "${display_manager_paths[@]:2}" "$(system_path /etc/sddm.conf.d/future.conf)")' \
  "$fake_checkout/bin/omarchy-overlay-setup"
echo 'host future config' >"$system_root/etc/sddm.conf.d/future.conf"
OMARCHY_TEST_INSTALLED_PACKAGES="$core_packages sddm qt6-wayland" run_setup artifacts --check display-manager >/dev/null
[[ ! -e $transaction_dir/inventory ]] || fail "legacy inventory preflight writes state"
pass "legacy rollback survives managed-path reordering and additions in read-only preflight"

# Status and repair must not turn a valid foreign-owner ledger into a takeover.
cp "$system_root/etc/omarchy/installation.conf" "$test_tmp/owner-ledger.saved"
sed -i 's/^OMARCHY_DESKTOP_OWNER=.*/OMARCHY_DESKTOP_OWNER=somebody-else/' "$system_root/etc/omarchy/installation.conf"
for operation_args in 'status' 'register --repair core' 'core --repair'; do
  : >"$sudo_log"
  read -r -a owner_args <<<"$operation_args"
  if OMARCHY_TEST_INSTALLED_PACKAGES="$core_packages" run_setup "${owner_args[@]}" >"$test_tmp/owner.out" 2>&1; then
    fail "foreign-owner operation succeeds: $operation_args"
  fi
  grep -q "registered to 'somebody-else'; run as that user" "$test_tmp/owner.out" || fail "owner error recommends repair"
  [[ ! -s $sudo_log ]] || fail "foreign-owner refusal follows privileged work"
done
status_output=$(OMARCHY_TEST_PRODUCT_INSTALLED=omarchy run_setup status)
grep -q 'desktop overlay not applicable' <<<"$status_output" || fail "stale foreign overlay descriptor hides product status"
[[ ! -s $sudo_log ]] || fail "product status requests sudo"
cp "$test_tmp/owner-ledger.saved" "$system_root/etc/omarchy/installation.conf"
pass "status and both repair routes identify the owner without granting a transfer"

# Registration may adopt display-manager only when the original rollback
# boundary already exists. It must neither invent a post-install baseline nor
# consume the transaction that the earlier setup created.
rm -f "$system_root/etc/omarchy/installation.conf"
: >"$sudo_log"
OMARCHY_TEST_INSTALLED_PACKAGES="$core_packages sddm qt6-wayland" \
  run_setup register core link config session-entry display-manager >/dev/null
[[ $(<"$active_record") == "$transaction_id" ]] || fail "display-manager registration replaces its pre-install rollback record"
mv "$active_record" "$active_record.saved"
: >"$sudo_log"
if OMARCHY_TEST_INSTALLED_PACKAGES="$core_packages sddm qt6-wayland" \
  run_setup artifacts display-manager >"$test_tmp/artifacts-no-baseline.out" 2>"$test_tmp/artifacts-no-baseline.err"; then
  fail "display-manager artifact reconciliation invents a post-install rollback baseline"
fi
grep -q 'requires its original rollback transaction' "$test_tmp/artifacts-no-baseline.err" ||
  fail "display-manager artifact reconciliation does not explain the missing baseline" "$(<"$test_tmp/artifacts-no-baseline.err")"
grep -q 'omitting display-manager' "$test_tmp/artifacts-no-baseline.err" ||
  fail "missing display-manager rollback guidance does not name the repair path" "$(<"$test_tmp/artifacts-no-baseline.err")"
[[ ! -s $sudo_log ]] || fail "a missing artifact rollback baseline is detected after privileged writes" "$(<"$sudo_log")"
mv "$active_record.saved" "$active_record"
rm -f "$system_root/etc/omarchy/installation.conf"
mv "$active_record" "$active_record.saved"
if OMARCHY_TEST_INSTALLED_PACKAGES="$core_packages sddm qt6-wayland" \
  run_setup register core link config session-entry display-manager >"$test_tmp/adopt-dm.out" 2>"$test_tmp/adopt-dm.err"; then
  fail "display-manager registration invents a rollback baseline from already-installed Omarchy files"
fi
grep -q 'no valid pre-install rollback transaction exists' "$test_tmp/adopt-dm.err" ||
  fail "display-manager adoption does not explain the missing original baseline" "$(<"$test_tmp/adopt-dm.err")"
[[ ! -e $system_root/etc/omarchy/installation.conf ]] || fail "failed display-manager adoption writes a descriptor"

# Registering without display-manager and then selecting its setup stage must
# not provide a second route to manufacture the same false baseline.
seed_registration core,link,config,session-entry
: >"$sudo_log"
if OMARCHY_TEST_INSTALLED_PACKAGES="$core_packages sddm qt6-wayland" \
  run_setup display-manager >"$test_tmp/setup-adopt-dm.out" 2>"$test_tmp/setup-adopt-dm.err"; then
  fail "display-manager setup invents a rollback baseline from already-installed Omarchy files"
fi
grep -q 'already configured, but its original rollback transaction is missing' "$test_tmp/setup-adopt-dm.err" ||
  fail "display-manager setup does not explain the missing original baseline" "$(<"$test_tmp/setup-adopt-dm.err")"
[[ ! -e $active_record ]] || fail "refused display-manager setup writes an active rollback record"
[[ ! -s $sudo_log ]] || fail "false-baseline setup is detected after privileged writes" "$(<"$sudo_log")"

mv "$active_record.saved" "$active_record"
seed_registration core,link,config,session-entry,display-manager
pass "display-manager adoption paths require and preserve a real pre-install rollback transaction"

echo 'later setup autologin' >"$system_root/etc/sddm.conf.d/autologin.conf"
OMARCHY_TEST_INSTALLED_PACKAGES="$core_packages sddm qt6-wayland" run_setup display-manager >"$test_tmp/reapply.out"
grep -Fxq "    rollback: captured $system_root/etc/sddm.conf.d/future.conf" "$test_tmp/reapply.out" || fail "extending the transaction does not announce the captured path"
[[ ! -e $system_root/etc/sddm.conf.d/autologin.conf ]] || fail "explicit setup retains autologin"
grep -q 'recovery copy:' "$test_tmp/reapply.out" || fail "setup deletes autologin without announcing its backup"
grep -rlx 'later setup autologin' "$transaction_dir"/autologin-preserved.* >/dev/null || fail "setup loses later autologin edits"
grep -qx 'original autologin' "$transaction_dir/backup/3" || fail "setup replaces original rollback baseline"
pass "explicit setup preserves later autologin edits separately from the original baseline"

: >"$sudo_log"
: >"$call_log"
rm -f "$test_home/.config/btop/themes/current.theme"
OMARCHY_TEST_INSTALLED_PACKAGES="$core_packages sddm qt6-wayland" run_setup artifacts --check display-manager >/dev/null
[[ ! -s $sudo_log && ! -s $call_log ]] ||
  fail "artifact check mode writes before the update package transaction" "sudo:\n$(<"$sudo_log")\ncalls:\n$(<"$call_log")"
OMARCHY_TEST_INSTALLED_PACKAGES="sddm qt6-wayland" run_setup artifacts --check display-manager >/dev/null ||
  fail "artifact preflight refuses packages that reconciliation is meant to restore"

# Reconciliation owns the installed theme/config files, not whether this host
# currently launches a greeter or keeps SDDM's mutable runtime state.
rm -f "$system_root/var/lib/sddm/state.conf"
echo 'host-added autologin' >"$system_root/etc/sddm.conf.d/autologin.conf"
printf 'sddm=disabled\ndefault=custom.target\n' >"$systemctl_state"
OMARCHY_TEST_INSTALLED_PACKAGES="$core_packages sddm qt6-wayland" run_setup artifacts display-manager >/dev/null
grep -qx 'host-added autologin' "$system_root/etc/sddm.conf.d/autologin.conf" || fail "artifact refresh removes host autologin"
grep -qx '1' <(head -n 1 "$transaction_dir/inventory") || fail "legacy transaction was not versioned"
grep -qx 'host future config' "$transaction_dir/backup/8" || fail "new managed path lacks its original backup"
# Retire that path again and simulate the intervening release overwriting it.
sed -i '/^display_manager_paths=(.*display_manager_paths\[1\]/c\display_manager_paths=("${display_manager_paths[1]}" "${display_manager_paths[0]}" "${display_manager_paths[@]:2}")' "$fake_checkout/bin/omarchy-overlay-setup"
echo 'updated future config' >"$system_root/etc/sddm.conf.d/future.conf"
cp "$transaction_dir/inventory" "$test_tmp/inventory.saved"
for bad_inventory in unknown-version unsafe-path duplicate-path; do
  cp "$test_tmp/inventory.saved" "$transaction_dir/inventory"
  case "$bad_inventory" in
    unknown-version) sed -i '1s/.*/99/' "$transaction_dir/inventory" ;;
    unsafe-path) printf '%s\n' /etc/passwd >>"$transaction_dir/inventory" ;;
    duplicate-path) tail -n 1 "$test_tmp/inventory.saved" >>"$transaction_dir/inventory" ;;
  esac
  : >"$sudo_log"
  if OMARCHY_TEST_INSTALLED_PACKAGES="$core_packages sddm qt6-wayland" run_setup display-manager-rollback >/dev/null 2>&1; then
    fail "rollback accepts $bad_inventory"
  fi
  [[ ! -s $sudo_log ]] || fail "invalid inventory causes privileged work"
done
cp "$test_tmp/inventory.saved" "$transaction_dir/inventory"
[[ $(<"$active_record") == "$transaction_id" ]] || fail "an idempotent display-manager rerun replaces its original baseline"
(( $(find "$test_home/.local/state/omarchy/dev-setup-desktop/display-manager/transactions" -mindepth 1 -maxdepth 1 -type d | wc -l) == 1 )) ||
  fail "an idempotent display-manager rerun creates a second transaction"
[[ ! -e $system_root/var/lib/sddm/state.conf ]] ||
  fail "display-manager artifact reconciliation recreates deleted SDDM runtime state"
[[ $(<"$systemctl_state") == $'sddm=disabled\ndefault=custom.target' ]] ||
  fail "display-manager artifact reconciliation changes service or default-target state" "$(<"$systemctl_state")"
if grep -q 'systemctl enable\|systemctl set-default' "$sudo_log"; then
  fail "display-manager artifact reconciliation invokes service-state changes" "$(<"$sudo_log")"
fi
pass "display-manager artifact reconciliation preserves rollback, runtime, service, and target state"

: >"$sudo_log"
printf 'sddm=enabled\ndefault=graphical.target\n' >"$systemctl_state"
printf 'invalid descriptor\n' >"$system_root/etc/omarchy/installation.conf"
rollback_output=$(OMARCHY_TEST_INSTALLED_PACKAGES='' run_setup display-manager-rollback 2>&1)
grep -qx 'host future config' "$system_root/etc/sddm.conf.d/future.conf" || fail "rollback loses a retired path's original backup"
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
grep -qx 'invalid descriptor' "$system_root/etc/omarchy/installation.conf" ||
  fail "rollback rewrites an invalid installation descriptor"
grep -q 'invalid installation descriptor was left unchanged' <<<"$rollback_output" ||
  fail "rollback does not report the descriptor it could not repair" "$rollback_output"
grep -q 'retained packages: sddm qt6-wayland' <<<"$rollback_output" ||
  fail "rollback states its conservative package-retention boundary" "$rollback_output"
pass "display-manager rollback survives an invalid descriptor and restores the host state"

# --- Rollback still restores its files and target, consumes the transaction,
# and reports the service-state problem if SDDM was removed out of band.
reset_run
cp "$ROOT/bin/omarchy-overlay-setup" "$fake_checkout/bin/omarchy-overlay-setup"
printf '[omarchy]\nServer = x\n' >"$pacman_conf"
seed_display_manager_prerequisites
printf 'sddm=disabled\ndefault=multi-user.target\n' >"$systemctl_state"
OMARCHY_TEST_INSTALLED_PACKAGES="$core_packages" run_setup display-manager >/dev/null
legacy_active="$test_home/.local/state/omarchy/dev-setup-desktop/display-manager/active"
legacy_transaction=$(<"$legacy_active")
rm "$test_home/.local/state/omarchy/dev-setup-desktop/display-manager/transactions/$legacy_transaction/inventory"
sed -i '/^display_manager_paths=(/a display_manager_paths=("${display_manager_paths[1]}" "${display_manager_paths[0]}" "${display_manager_paths[@]:2}")' "$fake_checkout/bin/omarchy-overlay-setup"
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
pass "legacy rollback survives a reordered release and a missing SDDM unit"

# --- all: every stage in dependency order, repo missing from pacman.conf.
reset_run
printf '[core]\nInclude = /etc/pacman.d/mirrorlist\n' >"$pacman_conf"
run_setup all >/dev/null

grep -qx -- "-v" "$sudo_log" || fail "sudo credentials are primed" "$(<"$sudo_log")"
grep -q "cp -f $pacman_conf $pacman_conf.omarchy-overlay-setup." "$sudo_log" ||
  fail "pacman.conf is backed up before the repo is added" "$(<"$sudo_log")"
grep -qx "pacman -Syu --needed hyprland foot quickshell ttf-jetbrains-mono-nerd-basic omarchy-keyring alsa-utils nautilus bluez grim brightnessctl" "$sudo_log" ||
  fail "all installs every package group in one transaction" "$(<"$sudo_log")"
grep -qx "install -Dm644 $fake_checkout/default/wayland-sessions/omarchy.desktop $system_root/usr/local/share/wayland-sessions/omarchy.desktop" "$sudo_log" ||
  fail "the session entry lands in /usr/local/share/wayland-sessions" "$(<"$sudo_log")"
if (( $(wc -l <"$sudo_log") != 11 )); then
  fail "no direct sudo invocations happen beyond the expected eleven" "$(<"$sudo_log")"
fi
pass "direct sudo invocations are exactly the expected eleven (apply-lock's contract is its own)"

grep -qx "tee $omarchy_conf" "$sudo_log" ||
  fail "the checkout is linked without the dev sudoers policy" "$(<"$sudo_log")"
grep -qx "apply-lock" "$call_log" || fail "lock screen PAM setup runs" "$(<"$call_log")"
grep -qx "theme-set tokyo-night headless=1" "$call_log" || fail "the default theme is generated headlessly" "$(<"$call_log")"
grep -qx "theme-set-gnome" "$call_log" || fail "the default theme is synchronized to GTK applications" "$(<"$call_log")"
grep -qx "sudo-keepalive" "$call_log" || fail "package installation keeps sudo credentials alive" "$(<"$call_log")"
grep -qx "xdg-mime default org.gnome.Nautilus.desktop inode/directory" "$call_log" ||
  fail "the files stage registers the default directory handler" "$(<"$call_log")"
pass "runtime link, lock PAM, mime registration, and desktop theme generation all run"

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
# shellcheck disable=SC2016
printf '[omarchy]\nSigLevel = Optional TrustAll\nServer = https://pkgs.omarchy.org/stable/$arch\n' >"$pacman_conf"
run_setup all --no-session-entry --all-configs --theme "Catppuccin" >/dev/null

if grep -q "tee -a $pacman_conf" "$sudo_log"; then
  fail "an existing [omarchy] repo is left alone" "$(<"$sudo_log")"
fi
if grep -q "wayland-sessions" "$sudo_log"; then
  fail "--no-session-entry skips the greeter entry" "$(<"$sudo_log")"
fi
if (( $(wc -l <"$sudo_log") != 8 )); then
  fail "only sudo -v, pinned key setup, pacman, runtime link, and ledger write run as direct sudo invocations" "$(<"$sudo_log")"
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
