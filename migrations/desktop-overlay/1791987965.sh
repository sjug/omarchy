echo "Put Elsewhen, the world clock, on the bar as omarchy.elsewhen"

# Elsewhen now ships in the checkout's shell tree as omarchy.elsewhen, so no
# package is involved. Mirrors the configuration half of
# migrations/1790528634.sh, then migrations/1790042972.sh.
config_file="$HOME/.config/omarchy/shell.json"

# Desktop defaults seeded earlier name the widget omacom.elsewhen, which the
# shell no longer registers. Rename it in place, keeping its settings.
if [[ -s $config_file ]] && grep -q 'omacom\.elsewhen' "$config_file"; then
  tmp=$(mktemp "$config_file.XXXXXX")
  jq '
    def rename:
      if . == "omacom.elsewhen" then "omarchy.elsewhen"
      elif type == "object" and .id == "omacom.elsewhen" then .id = "omarchy.elsewhen"
      end;

    if (.bar.layout | type) == "object" then .bar.layout |= map_values(if type == "array" then map(rename) end) end
    | if (.bar.centerAnchor | type) == "string" then .bar.centerAnchor |= rename end
    | if (.plugins | type) == "array" then .plugins |= map(rename) end
    | if (.disabledPlugins | type) == "array" then .disabledPlugins |= map(rename) end
  ' "$config_file" >"$tmp"
  mv "$tmp" "$config_file"
fi
rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/omacom-elsewhen"

# Ask the running shell to find the in-tree plugin, then place it. Both steps
# are best-effort for a shell that is not running: the update still finishes.
omarchy-shell -q shell rescanPlugins

# A world clock already on the bar stays where it is, and one the user
# disabled stays off: putting it would enable it again.
if [[ -s $config_file ]] && jq -e '([.bar.layout[]?[]? | if type == "object" then .id else . end] | index("omarchy.elsewhen")) or ((.disabledPlugins // []) | index("omarchy.elsewhen"))' "$config_file" >/dev/null 2>&1; then
  echo "Elsewhen is already on the bar or turned off"
else
  omarchy-bar put omarchy.elsewhen --after omarchy.clock
fi
