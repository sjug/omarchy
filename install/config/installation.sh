installation_conf="${OMARCHY_INSTALLATION_CONF_PATH:-/etc/omarchy/installation.conf}"

install -d -m 0755 "$(dirname "$installation_conf")"
printf 'OMARCHY_INSTALLATION=product\n' >"$installation_conf"
chmod 0644 "$installation_conf"
