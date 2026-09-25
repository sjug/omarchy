echo "Enable OWE desktop video backgrounds and lock feed"

# owe and owe-lockfeed come from the desktop manifest's core group, installed
# by the overlay package transaction before migrations run.
if [[ ! -f /usr/share/owe/10-owe-sync ]]; then
  echo "OWE is not installed; run 'omarchy overlay setup packages core' and retry." >&2
  exit 1
fi

omarchy-hook-install theme-set /usr/share/owe/10-owe-sync

systemctl --user daemon-reload >/dev/null 2>&1 || true
if ! systemctl --user enable owed.service; then
  wants_dir="$HOME/.config/systemd/user/graphical-session.target.wants"
  mkdir -p "$wants_dir"
  ln -sfn /usr/lib/systemd/user/owed.service "$wants_dir/owed.service"
fi

# A TTY update enables the next graphical login without starting a renderer
# against a missing Wayland session.
if systemctl --user is-active --quiet graphical-session.target; then
  systemctl --user start owed.service
fi
