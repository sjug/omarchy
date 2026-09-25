echo "Remove automatic project bin directories from PATH"

# Hosts converted from a product install can still carry the ~/Work/.mise.toml
# that put "{{ cwd }}/bin" on PATH. The fix is entirely user-side, so run the
# product migration's logic deliberately. Without mise there is nothing to
# untrust or edit.
omarchy-cmd-present mise || exit 0

bash -euo pipefail "$OMARCHY_PATH/migrations/1789095456.sh"
