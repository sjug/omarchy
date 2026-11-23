echo "Give the Herdr desktop app the same keybindings as the terminal herdr"

# Desktop-only counterpart of product migration 1794068501.sh. Keep its
# completion independent from the product migration ledger.

app_home="${HERDR_APP_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-app}"

# Leave people who never installed the app alone; its installer seeds the keys.
[[ -d $app_home ]] || exit 0

omarchy-refresh-herdr-app
