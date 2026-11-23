echo "Open folders in Files where it replaced Nautilus"

# Desktop-only counterpart of product migration 1794330979.sh. The overlay
# neither installs Files nor removes Nautilus, so personal associations and a
# dock pin only move where Files is there to take them.
omarchy-pkg-present folio || exit 0

user_mimeapps="$HOME/.config/mimeapps.list"
if [[ -f $user_mimeapps ]] && grep -q "org.gnome.Nautilus.desktop" "$user_mimeapps"; then
  sed --follow-symlinks -i 's/org\.gnome\.Nautilus\.desktop/folio.desktop/g' "$user_mimeapps"
fi

shell_json="$HOME/.config/omarchy/shell.json"
if [[ -f $shell_json ]] && grep -q '"org.gnome.Nautilus"' "$shell_json"; then
  sed --follow-symlinks -i 's/"org\.gnome\.Nautilus"/"folio"/' "$shell_json"
fi
