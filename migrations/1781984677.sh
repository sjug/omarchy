echo "Normalize Snapper snapshot services"

OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"
snapper_config_script=/usr/share/omarchy/install/config/snapper.sh
if [[ ! -f $snapper_config_script ]]; then
  snapper_config_script="$OMARCHY_PATH/install/config/snapper.sh"
fi

as_root() {
  if (( EUID == 0 )); then
    "$@"
  else
    sudo "$@"
  fi
}

unit_enabled() {
  systemctl is-enabled --quiet "$1" >/dev/null 2>&1
}

unit_active() {
  systemctl is-active --quiet "$1" >/dev/null 2>&1
}

needs_repair=0
storage_backend=""

if [[ -f /etc/omarchy/storage.conf ]]; then
  storage_backend=$(awk -F= '$1 == "OMARCHY_STORAGE_BACKEND" { print $2 }' /etc/omarchy/storage.conf)
fi
if [[ -z $storage_backend ]] && grep -Fqx 'FSTYPE="lvm(xfs)"' /etc/snapper/configs/root 2>/dev/null; then
  storage_backend="lvm_xfs"
fi

[[ -f /etc/snapper/configs/root ]] || needs_repair=1

if ! unit_enabled snapper-cleanup.timer || ! unit_active snapper-cleanup.timer; then
  needs_repair=1
fi

if [[ $storage_backend == "lvm_xfs" ]]; then
  if unit_enabled limine-snapper-sync.service || unit_active limine-snapper-sync.service; then
    needs_repair=1
  fi
else
  if ! unit_enabled limine-snapper-sync.service || ! unit_active limine-snapper-sync.service; then
    needs_repair=1
  fi
fi

(( needs_repair )) || exit 0

as_root env OMARCHY_PATH="$OMARCHY_PATH" bash -euo pipefail "$snapper_config_script"
