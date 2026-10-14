echo "Keep Voxtype as the dictation backend for existing Voxtype users"

# Dictation keys are now bound only for the backend named in
# ~/.config/omarchy/defaults/dictation, which new installs seed with a cloud
# backend. An overlay that already dictates through Voxtype has no such file,
# so record Voxtype or its keys disappear. Mirrors migrations/1791479273.sh,
# also accepting a voxtype the host installed some other way.
backend_config="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/defaults/dictation"
[[ ! -e $backend_config ]] || exit 0
omarchy-pkg-present voxtype-bin || omarchy-cmd-present voxtype || exit 0

mkdir -p "${backend_config%/*}"
temporary=$(mktemp "$backend_config.XXXXXX")
printf '%s\n' voxtype >"$temporary"
mv -f "$temporary" "$backend_config"

# The bindings read the backend when Hyprland loads its config.
hyprctl reload >/dev/null 2>&1 || true
echo "Keep this choice: do not run 'omarchy refresh config omarchy/defaults/dictation', which would replace Voxtype."
