#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The desktop manifest exists so checkout-backed installs get the session
# without the product's boot/storage/login integration. Both properties it
# claims are enforced here: every package it lists is one the product ships,
# and none of the integration packages it exists to avoid sneak in.
mapfile -t product_packages < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' \
  "$ROOT/install/omarchy-base.packages" "$ROOT/install/omarchy-other.packages")
mapfile -t desktop_packages < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$ROOT/install/omarchy-desktop.packages")

(( ${#desktop_packages[@]} > 0 )) || fail "desktop manifest lists packages"

declare -A in_product=()
for package in "${product_packages[@]}"; do
  in_product[$package]=1
done

not_shipped=()
for package in "${desktop_packages[@]}"; do
  if [[ $package != "omarchy-keyring" && -z ${in_product[$package]:-} ]]; then
    not_shipped+=("$package")
  fi
done
if (( ${#not_shipped[@]} > 0 )); then
  fail "desktop manifest stays within the product package boundary" "not in omarchy-base.packages or omarchy-other.packages and not the keyring bootstrap: ${not_shipped[*]}"
fi
pass "desktop manifest is a subset of the product package set plus its keyring bootstrap"

duplicates=$(printf '%s\n' "${desktop_packages[@]}" | sort | uniq -d)
if [[ -n $duplicates ]]; then
  fail "desktop manifest lists each package once" "duplicated: $duplicates"
fi
pass "desktop manifest lists each package once"

# Every package must belong to a "# group: <name>" stage marker, the groups
# must be exactly the stages omarchy-dev-setup-desktop knows, and none may be
# empty — the command installs by group, so an orphan or a typo'd group name
# silently drops packages from every stage.
expected_groups="audio capture connectivity core files power"
actual_groups=$(awk '/^# group: /{print $3}' "$ROOT/install/omarchy-desktop.packages" | sort | tr '\n' ' ' | sed 's/ $//')
[[ $actual_groups == "$expected_groups" ]] ||
  fail "manifest groups match the setup stages" "expected: $expected_groups; got: $actual_groups"

orphans=$(awk '
  /^# group: / { seen_group = 1; next }
  { sub(/[[:space:]]*#.*$/, "") }
  NF && !seen_group { print }
' "$ROOT/install/omarchy-desktop.packages")
[[ -z $orphans ]] || fail "every manifest package belongs to a group" "before first group marker: $orphans"

for group in core audio files connectivity capture power; do
  group_count=$(awk -v group="$group" '
    /^# group: / { in_group = ($3 == group); next }
    { sub(/[[:space:]]*#.*$/, "") }
    in_group && NF { count += 1 }
    END { print count + 0 }
  ' "$ROOT/install/omarchy-desktop.packages")
  (( group_count > 0 )) || fail "manifest group '$group' is not empty"
done
pass "manifest packages are grouped into exactly the setup stages"

# Pinned because its absence is masked everywhere but a plain-Arch checkout
# install: the packaged product depends on perl directly, so only the desktop
# manifest stands between the clipboard service and a missing interpreter.
# It must sit in core: the clipboard service is part of the core session.
awk '
  /^# group: / { in_group = ($3 == "core"); next }
  { sub(/[[:space:]]*#.*$/, "") }
  in_group && $0 == "perl" { found = 1 }
  END { exit !found }
' "$ROOT/install/omarchy-desktop.packages" ||
  fail "desktop manifest carries perl in the core group"
pass "desktop manifest carries perl in the core group for the clipboard service"

# The desktop pulls a few signed packages from pkgs.omarchy.org. A plain Arch
# host does not have their signer, so core must bootstrap the product keyring.
awk '
  /^# group: / { in_group = ($3 == "core"); next }
  { sub(/[[:space:]]*#.*$/, "") }
  in_group && $0 == "omarchy-keyring" { found = 1 }
  END { exit !found }
' "$ROOT/install/omarchy-desktop.packages" ||
  fail "desktop manifest carries omarchy-keyring in the core group"
pass "desktop manifest carries the Omarchy package keyring in core"

# The config stage synchronizes Omarchy's selected mode and icon theme to GTK
# applications. Keep the assets behind those settings in the core desktop set
# so a checkout-backed Nautilus has the same appearance as the product.
for package in gnome-themes-extra yaru-icon-theme; do
  awk -v package="$package" '
    /^# group: / { in_group = ($3 == "core"); next }
    { sub(/[[:space:]]*#.*$/, "") }
    in_group && $0 == package { found = 1 }
    END { exit !found }
  ' "$ROOT/install/omarchy-desktop.packages" ||
    fail "desktop manifest carries $package in the core group"
done
pass "desktop manifest carries the GTK and icon themes in core"

# The idle service launches omarchy-screensaver from the core session, and
# that command executes ttfx directly. A checkout-only desktop must not reach
# its first idle cycle with the animation runtime missing.
awk '
  /^# group: / { in_group = ($3 == "core"); next }
  { sub(/[[:space:]]*#.*$/, "") }
  in_group && $0 == "ttfx" { found = 1 }
  END { exit !found }
' "$ROOT/install/omarchy-desktop.packages" ||
  fail "desktop manifest carries ttfx in the core group"
pass "desktop manifest carries ttfx in core for the screensaver"

# The default screenshot action and clipboard image opener both execute
# tensaku-edit, so capture is incomplete on a checkout-only install without it.
awk '
  /^# group: / { in_group = ($3 == "capture"); next }
  { sub(/[[:space:]]*#.*$/, "") }
  in_group && $0 == "tensaku" { found = 1 }
  END { exit !found }
' "$ROOT/install/omarchy-desktop.packages" ||
  fail "desktop manifest carries tensaku in the capture group"
pass "desktop manifest carries tensaku in the capture group for screenshot and clipboard editing"

# Patterns, not names: the point is that no future limine-*, snapper-*, or
# similar companion package can slip in when one gets added to the product.
forbidden_patterns=(
  'btrfs*'
  'docker*'
  'limine*'
  'mkinitcpio*'
  'omarchy'
  'omarchy-dev*'
  'omarchy-settings*'
  'plymouth*'
  'sddm*'
  'snapper*'
  'ufw*'
)

integration_present=()
for package in "${desktop_packages[@]}"; do
  for pattern in "${forbidden_patterns[@]}"; do
    if [[ $package == $pattern ]]; then
      integration_present+=("$package")
      break
    fi
  done
done
if (( ${#integration_present[@]} > 0 )); then
  fail "desktop manifest excludes system-integration packages" "present: ${integration_present[*]}"
fi
pass "desktop manifest excludes boot, storage, and login integration packages"
