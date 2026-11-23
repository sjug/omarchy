echo "Open Slack with its own launcher again, now that Slack theme sync is gone"

# Desktop-only counterpart of product migration 1794642577.sh. Keep its
# completion independent from the product migration ledger.

# Theme sync replaced Slack's launcher with one that runs omarchy-launch-slack,
# which no longer exists. Slack 4.53 refuses the debugging pipe it relied on.
override="$HOME/.local/share/applications/slack.desktop"
if [[ -f $override ]] && grep -qE '^Exec=omarchy-launch-slack( |$)' "$override"; then
  if [[ -f $override.before-omarchy ]]; then
    mv "$override.before-omarchy" "$override"
  else
    rm "$override"
  fi
  update-desktop-database "${override%/*}"
fi
rm -rf "$HOME/.local/state/omarchy/slack"
