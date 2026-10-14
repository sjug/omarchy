echo "Drop named workspaces' saved layouts and save the rest as modes"

# Mirrors migrations/1787679775.sh and migrations/1791698594.sh, in that order.
# A layout saved for a named workspace (a negative id) is applied to workspace 1
# at every login, so it goes. The rest move from plain Hyprland rules to
# workspace modes, which floating and the default layout read. The old toggle
# wrote to ~/.local/state whatever XDG_STATE_HOME said, so both are handled.
removed=0
for state_home in "$HOME/.local/state" "${XDG_STATE_HOME:-}"; do
  [[ -n $state_home ]] || continue
  layouts_dir="$state_home/omarchy/workspace-layouts"
  [[ -d $layouts_dir ]] || continue

  for saved in "$layouts_dir"/-*.lua; do
    if [[ -f $saved ]]; then
      rm -f -- "$saved"
      removed=1
    fi
  done

  for saved in "$layouts_dir"/*.lua; do
    [[ -f $saved ]] || continue
    sed -i --follow-symlinks 's/^hl\.workspace_rule({ workspace = "\([0-9]*\)", layout = "\([a-z]*\)" })$/o.workspace_mode({ workspace = "\1", mode = "\2" })/' "$saved"
  done
done

# Hyprland notices deleted files it required only with autoreload on.
if (( removed )); then
  hyprctl reload >/dev/null 2>&1 || true
fi
