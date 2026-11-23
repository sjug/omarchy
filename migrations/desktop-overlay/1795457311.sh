echo "Add Terminal and Browser to the app launcher"

# Desktop-only counterpart of product migration 1794495065.sh. Keep its
# completion independent from the product migration ledger.

# Only these two, so apps the user removed from the launcher stay removed.
mkdir -p ~/.local/share/applications
cp "$OMARCHY_PATH/applications/omarchy-terminal.desktop" "$OMARCHY_PATH/applications/omarchy-browser.desktop" ~/.local/share/applications/
update-desktop-database ~/.local/share/applications
omarchy-theme-set-icons || true
