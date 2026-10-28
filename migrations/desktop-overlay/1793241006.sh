echo "Keep the input-method service inert where fcitx5 is absent"

# Only replace the unmodified unit shipped by the previous overlay sync.
unit="$HOME/.config/systemd/user/omarchy-fcitx5.service"
if [[ -f $unit && ! -L $unit ]] && [[ $(sha256sum <"$unit") == "5340eec63b9ff51668f74d0e78e05e24c94cc765c6eb1a66cf34fd0831ae11a3  -" ]]; then
  install -m644 "$OMARCHY_PATH/default/systemd/user/omarchy-fcitx5.service" "$unit"
  systemctl --user daemon-reload
fi
