SNAPPER_CONFIG_PATH="${OMARCHY_SNAPPER_CONFIG_PATH:-/etc/snapper/configs/root}"
SNAPPER_CONF_PATH="${OMARCHY_SNAPPER_CONF_PATH:-/etc/conf.d/snapper}"
SNAPPER_BACKEND="${OMARCHY_SNAPPER_BACKEND:-}"

if [[ -z $SNAPPER_BACKEND && -f /etc/omarchy/storage.conf ]]; then
  SNAPPER_BACKEND=$(awk -F= '$1 == "OMARCHY_STORAGE_BACKEND" { print $2 }' /etc/omarchy/storage.conf)
fi

if [[ -z $SNAPPER_BACKEND && $(findmnt -no FSTYPE /) == "xfs" ]]; then
  root_source=$(findmnt -no SOURCE /)
  if lvs "$root_source" >/dev/null 2>&1; then
    SNAPPER_BACKEND="lvm_xfs"
  fi
fi

if [[ $SNAPPER_BACKEND == "lvm_xfs" ]]; then
  snapper_fstype="lvm(xfs)"
  default_template="${OMARCHY_PATH:-/usr/share/omarchy}/default/snapper/root-lvm-xfs"
else
  snapper_fstype="btrfs"
  default_template="${OMARCHY_PATH:-/usr/share/omarchy}/default/snapper/root"
fi
template="${OMARCHY_SNAPPER_TEMPLATE:-$default_template}"

echo "Configuring Omarchy Snapper snapshot retention"

if [[ ! -f $SNAPPER_CONFIG_PATH ]]; then
  mkdir -p "$(dirname "$SNAPPER_CONFIG_PATH")"

  if [[ ${OMARCHY_SNAPPER_CONFIGURE_TEST:-0} == "1" ]]; then
    : >"$SNAPPER_CONFIG_PATH"
  else
    snapper --no-dbus -c root create-config --fstype="$snapper_fstype" / >/dev/null 2>&1 ||
      snapper -c root create-config --fstype="$snapper_fstype" / >/dev/null
  fi
fi

install -m 0644 "$template" "$SNAPPER_CONFIG_PATH"

mkdir -p "$(dirname "$SNAPPER_CONF_PATH")"
printf '%s\n' 'SNAPPER_CONFIGS="root"' >"$SNAPPER_CONF_PATH"
chmod 0644 "$SNAPPER_CONF_PATH"

systemctl disable --now snapper-timeline.timer >/dev/null 2>&1 || true
if [[ $SNAPPER_BACKEND == "lvm_xfs" ]]; then
  systemctl disable --now limine-snapper-sync.service limine-snapper-sync.path >/dev/null 2>&1 || true
  systemctl enable --now snapper-cleanup.timer >/dev/null 2>&1 || true
else
  systemctl enable --now snapper-cleanup.timer limine-snapper-sync.service >/dev/null 2>&1 || true
fi
