echo "Link Omarchy's Pi extensions and start Pi straight at the editor"

# Desktop-only counterpart of product migrations 1795294173.sh, 1795372675.sh
# and 1795376239.sh, for machines that have Pi.
[[ -d $HOME/.pi ]] || omarchy-cmd-present pi || exit 0

"$OMARCHY_PATH/bin/omarchy-agent-pi-defaults"

# A quietStartup of "header" asked for the Omarchy header, which is gone, so
# that value becomes true. A value the user chose stays.
settings=~/.pi/agent/settings.json
if jq -e '.quietStartup == "header"' "$settings" &>/dev/null; then
  target=$(realpath "$settings")
  tmp=$(mktemp "$target.XXXXXX")
  jq '.quietStartup = true' "$target" >"$tmp" && mv "$tmp" "$target"
fi
