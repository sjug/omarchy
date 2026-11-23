echo "Open documents in Papers where it replaced Evince"

# Desktop-only counterpart of product migration 1794165002.sh. The overlay
# neither installs Papers nor removes Evince, so a personal association only
# moves where Papers is there to open the files.
omarchy-pkg-present papers || exit 0

user_mimeapps="$HOME/.config/mimeapps.list"
if [[ -f $user_mimeapps ]] && grep -q "org.gnome.Evince.desktop" "$user_mimeapps"; then
  sed --follow-symlinks -i 's/org\.gnome\.Evince\.desktop/org.gnome.Papers.desktop/g' "$user_mimeapps"
fi
