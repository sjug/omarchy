echo "Add launchers for the coding agents, harnesses and local models already set up"

# Desktop-only counterpart of product migrations 1794763180.sh, 1794931275.sh
# and 1794839007.sh. A launcher already in place stays as it is.
applications="$HOME/.local/share/applications"

for provider in claude codex grok; do
  entry="omarchy-agent-$provider.desktop"
  [[ -f $applications/$entry ]] && continue
  if omarchy-agent-account-state list "$provider" 2>/dev/null | jq -e '.[0].accounts | any(.signedIn)' >/dev/null 2>&1; then
    mkdir -p "$applications"
    install -m 644 "$OMARCHY_PATH/default/applications/$entry" "$applications/$entry"
  fi
done

for entry in "$OMARCHY_PATH"/default/applications/omarchy-agent-*.desktop; do
  name=${entry##*/}
  agent=${name#omarchy-agent-}
  agent=${agent%.desktop}
  [[ -f $applications/$name ]] && continue
  if omarchy-default-agent --installed "$agent" 2>/dev/null; then
    omarchy-agent-launcher "$agent"
  fi
done
update-desktop-database "$applications" 2>/dev/null || true

if omarchy-cmd-present omarchy-local-ai; then
  omarchy-models-launchers
fi

# Drawing the icon set links the launchers' icons in right away.
omarchy-theme-set-icons || true
