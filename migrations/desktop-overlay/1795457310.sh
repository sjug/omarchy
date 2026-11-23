echo "Draw the app icons as an icon set in the current theme's colors"

# Desktop-only counterpart of product migrations 1794484010.sh and
# 1794644424.sh.

# Icon templates of the user's own moved from ~/.config/omarchy/themed/icons to
# the set they redraw.
old_templates="$HOME/.config/omarchy/themed/icons"
if [[ -d $old_templates ]]; then
  mkdir -p "$HOME/.config/omarchy/icons/papercraft"
  find "$old_templates" -maxdepth 1 -name '*.svg.tpl' -exec mv -n -t "$HOME/.config/omarchy/icons/papercraft" {} +
  rmdir "$old_templates" 2>/dev/null || true
fi

# A theme the user removed can't be refreshed; its icons come with the next
# theme they pick.
theme=$(cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null || true)
if [[ -n $theme && ( -d $OMARCHY_PATH/themes/$theme || -d $HOME/.config/omarchy/themes/$theme ) ]]; then
  omarchy-theme-refresh
fi
omarchy-theme-set-icons || true
