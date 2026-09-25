echo "Point the image viewer at Omasnap"

# Omasnap belongs to the desktop manifest's capture group. Only recorded stages
# are reconciled by the overlay package transaction, so an overlay that never
# adopted capture keeps its current image editor untouched. An unreadable
# ledger is a failure, not an absent stage.
stages=$(omarchy-overlay-stages)
grep -qx capture <<<"$stages" || exit 0

if ! command -v omasnap >/dev/null; then
  echo "Omasnap is not installed; run 'omarchy overlay setup packages capture' and retry." >&2
  exit 1
fi

# The old source installer left a NoDisplay entry that overrides the packaged
# launcher. A hidden entry cannot be told apart from one the user hid on
# purpose, so move it aside instead of deleting it; a visible launcher the user
# placed there is left alone.
launcher="$HOME/.local/share/applications/omasnap.desktop"
if [[ -f $launcher ]] && grep -qx 'NoDisplay=true' "$launcher"; then
  backup="$launcher.bak.$(date +%s)"
  mv "$launcher" "$backup"
  echo "Moved the hidden Omasnap launcher override aside so the packaged launcher shows: $backup"
fi

imv_config="$HOME/.config/imv/config"
if [[ -f $imv_config ]]; then
  sed -i --follow-symlinks \
    -e 's/^# Edit the current image in Tensaku and quit the viewer$/# Edit the current image in Omasnap and quit the viewer/' \
    -e 's/^# Edit the current image in Satty and quit the viewer$/# Edit the current image in Omasnap and quit the viewer/' \
    -e 's|^<Ctrl+e> = exec tensaku-edit "$imv_current_file" & ; quit$|<Ctrl+e> = exec omasnap "$imv_current_file" \& ; quit|' \
    -e 's|^<Ctrl+e> = exec satty --filename "$imv_current_file" & ; quit$|<Ctrl+e> = exec omasnap "$imv_current_file" \& ; quit|' \
    "$imv_config"
fi

# Removals stay advisory on an overlay.
if omarchy-pkg-present satty || omarchy-pkg-present tensaku; then
  echo "Omasnap replaces satty and tensaku; remove them when convenient with: omarchy-pkg-drop satty tensaku"
fi
