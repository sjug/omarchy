# shellcheck shell=bash

omarchy_conf_quote() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//\$/\\\$}
  value=${value//\`/\\\`}
  printf '"%s"' "$value"
}

# A double-quoted sudoers string takes a backslash escape for a literal
# backslash or quote, and nothing else. A checkout path with a space in it is
# already covered by the quotes.
omarchy_sudoers_quote() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '"%s"' "$value"
}

omarchy_write_runtime_link() {
  local target="$1"
  local install_sudo_path="$2"
  local runtime_conf="${3:-/etc/omarchy.conf}"
  local sudoers_file="${4:-/etc/sudoers.d/omarchy-dev-path}"
  local system_secure_path="/usr/local/sbin:/usr/local/bin:/usr/bin"
  local staged_sudoers

  if (( install_sudo_path )); then
    # Parse the sudoers policy before changing either system file. An invalid
    # drop-in can prevent sudo from reading the wheel rule needed to undo it.
    staged_sudoers=$(mktemp)
    {
      printf 'Defaults secure_path='
      omarchy_sudoers_quote "$target/bin:$system_secure_path"
      printf '\n'
    } >"$staged_sudoers"

    if ! visudo -cf "$staged_sudoers" >/dev/null; then
      echo "Error: refusing to install an invalid $sudoers_file for $target" >&2
      rm -f "$staged_sudoers"
      return 1
    fi
  fi

  {
    printf 'export OMARCHY_PATH='
    omarchy_conf_quote "$target"
    printf '\n'
  } | sudo tee "$runtime_conf" >/dev/null

  echo "Pointed Omarchy at $target"
  if (( install_sudo_path )); then
    sudo install -Dm440 -o root -g root "$staged_sudoers" "$sudoers_file"
    rm -f "$staged_sudoers"
    echo "sudo now resolves omarchy-* from $target/bin"
  else
    sudo rm -f "$sudoers_file"
    echo "sudo secure_path does not include the checkout"
  fi
}
