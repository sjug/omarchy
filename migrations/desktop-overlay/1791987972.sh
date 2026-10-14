echo "Keep the wallpaper after its theme renumbered its backgrounds"

# Tokyo Night renumbered its backgrounds (1-quattro.webp became 2-quattro.webp)
# with no product migration. A wallpaper picked from the staged theme keeps its
# old name until the next theme refresh re-stages it, and then points at
# nothing. Copy the renamed file into the staged theme and point at it now.
current_dir="$HOME/.local/state/omarchy/current"
link="$current_dir/background"
staged_dir="$current_dir/theme/backgrounds"
[[ -L $link && -s $current_dir/theme.name ]] || exit 0

theme=$(<"$current_dir/theme.name")
[[ $theme =~ ^[[:alnum:]_][[:alnum:].+_-]*$ ]] || exit 0
target=$(readlink "$link")
[[ ${target%/*} == "$staged_dir" ]] || exit 0

name=${target##*/}
[[ $name =~ ^[0-9]+-(.+)$ ]] || exit 0
suffix=${BASH_REMATCH[1]}

official_dir="$OMARCHY_PATH/themes/$theme/backgrounds"
user_dir="$HOME/.config/omarchy/themes/$theme/backgrounds"
[[ ! -e $official_dir/$name && ! -e $user_dir/$name ]] || exit 0

matches=()
for candidate in "$official_dir"/[0-9]*-"$suffix"; do
  [[ -f $candidate && ${candidate##*/} =~ ^[0-9]+-.+$ ]] && matches+=("$candidate")
done
(( ${#matches[@]} == 1 )) || exit 0

renamed="$staged_dir/${matches[0]##*/}"
[[ -f $renamed ]] || cp "${matches[0]}" "$renamed"
ln -sfn "$renamed" "$link"
omarchy-shell -q background set "$renamed"
