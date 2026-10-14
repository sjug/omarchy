echo "Apply Omarchy's input-method defaults where fcitx5 runs"

# Mirrors migrations/1791367434.sh without its engine packages, which the
# desktop manifest leaves to the user. The defaults free Ctrl+Space and
# Super+Space, let Left Shift switch, and start the input method inactive.
# They route fcitx5's D-Bus activation through omarchy-fcitx5.service, so they
# apply only where that unit runs fcitx5.
omarchy-cmd-present fcitx5 || exit 0
unit="$HOME/.config/systemd/user/omarchy-fcitx5.service"
if [[ ! -f $unit && ! -f /usr/lib/systemd/user/omarchy-fcitx5.service ]]; then
  echo "fcitx5 does not run through omarchy-fcitx5.service; leaving its configuration alone."
  exit 0
fi

# A user copy of the unit exactly as Omarchy shipped it before gets the current
# one, which tells systemd that fcitx5 is ready once it owns its bus name.
if [[ -f $unit && ! -L $unit ]] && [[ $(sha256sum <"$unit") == "32ed3c8577b8c5d8252f02e7beaf1ac92a79842971a48b8cdcfcd56f9a0931e7  -" ]]; then
  install -m644 "$OMARCHY_PATH/default/systemd/user/omarchy-fcitx5.service" "$unit"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
fi

omarchy-input-method configure --defaults
echo "Add input engines when you need them with: omarchy setup input <engine>"
