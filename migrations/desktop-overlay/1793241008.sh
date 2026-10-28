echo "Supply the Omarchy keyboard option in the user XKB include path"

# Product packages install these under /etc/xkb. Checkout-backed desktops
# need the same symbols for Shift+Caps Lock; preserve any custom XKB files.
for xkb_file in rules/evdev symbols/omarchy; do
  xkb_target="$HOME/.config/xkb/$xkb_file"
  if [[ ! -e $xkb_target && ! -L $xkb_target ]]; then
    install -d "${xkb_target%/*}"
    ln -s "$OMARCHY_PATH/etc/xkb/$xkb_file" "$xkb_target"
  fi
done
