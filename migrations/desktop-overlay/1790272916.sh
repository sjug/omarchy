echo "Install Elsewhen, the world clock plugin"

# The elsewhen package is in the desktop manifest's core group. Its plugin
# lands under /usr/share/omarchy/shell/plugins even though the overlay runs
# the shell from a checkout, so link it into the user plugin directory.
packaged_plugin="/usr/share/omarchy/shell/plugins/omacom.elsewhen"
user_plugin="$HOME/.config/omarchy/plugins/omacom.elsewhen"

if [[ ! -d $packaged_plugin ]]; then
  echo "Elsewhen is not installed; run 'omarchy overlay setup packages core' and retry." >&2
  exit 1
fi

# The package moved from plugins/ to shell/plugins/ once, stranding a link made
# to the old path. A link the user made elsewhere is left alone.
if [[ -L $user_plugin && ! -e $user_plugin && $(readlink "$user_plugin") == /usr/share/omarchy/* ]]; then
  ln -sfn "$packaged_plugin" "$user_plugin"
fi

if [[ ! -e $user_plugin && ! -L $user_plugin ]]; then
  mkdir -p "${user_plugin%/*}"
  ln -s "$packaged_plugin" "$user_plugin"
fi

# Best-effort: an update whose shell cannot be asked still finishes, and the
# overlay update restarts the shell once the migrations are through.
omarchy-shell -q shell rescanPlugins
omarchy-bar put omacom.elsewhen --before omarchy.clock
