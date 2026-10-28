echo "Theme the Fcitx candidate window with the current Omarchy theme"

# Desktop-only equivalent of upstream migrations/1792020559.sh.
# Keep overlay completion independent from the product migration stream.
omarchy-pkg-present fcitx5 || exit 0

# Activation selects the theme; the refresh then renders it, since the current
# theme was staged before its template existed.
omarchy-theme-set-fcitx5 --activate
omarchy-theme-refresh
