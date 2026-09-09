#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

# Invoke the real helper with shell-function privilege stubs. Signals target
# only the helper and its simulated sudo command, never the test runner.
cat >"$test_tmp/runner" <<'SH'
#!/bin/bash
set -euo pipefail

source "$ROOT/install/helpers/runtime-link.sh"
mode=$1
run_dir=$2
export TMPDIR="$run_dir/tmp"
trap 'printf "caller exit\n" >>"$run_dir/caller-exit"' EXIT
trap ':' ERR
if [[ $mode == "success" ]]; then
  trap ':' HUP INT TERM
fi
trap -p EXIT ERR HUP INT TERM >"$run_dir/traps-before"

visudo() {
  helper_pid=$BASHPID
  if [[ $mode == "invalid-sudoers" ]]; then
    return 1
  fi
}

sudo() {
  local operation=$1
  shift
  case "$mode:$operation" in
    tee-failure:tee|install-failure:install) return 1 ;;
    interrupt-tee:tee|interrupt-install:install)
      kill -INT "$BASHPID" "$helper_pid"
      return 130
      ;;
    terminate-tee:tee|terminate-install:install)
      kill -TERM "$BASHPID" "$helper_pid"
      return 143
      ;;
    hangup-tee:tee|hangup-install:install)
      kill -HUP "$BASHPID" "$helper_pid"
      return 129
      ;;
  esac
  case "$operation" in
    tee) tee "$@" ;;
    install) cp "${@: -2:1}" "${@: -1}" ;;
    *) return 1 ;;
  esac
}

omarchy_write_runtime_link /tmp/fixture-checkout 1 "$run_dir/runtime.conf" "$run_dir/sudoers"
trap -p EXIT ERR HUP INT TERM >"$run_dir/traps-after"
SH

for mode in success invalid-sudoers tee-failure install-failure interrupt-tee interrupt-install terminate-tee terminate-install hangup-tee hangup-install; do
  run_dir="$test_tmp/$mode"
  mkdir -p "$run_dir/tmp"
  result=0
  setsid --wait bash "$test_tmp/runner" "$mode" "$run_dir" >"$run_dir/out" 2>"$run_dir/err" || result=$?
  case "$mode" in
    success) expected=0 ;;
    interrupt-*) expected=130 ;;
    terminate-*) expected=143 ;;
    hangup-*) expected=129 ;;
    *) expected=1 ;;
  esac
  (( result == expected )) || fail "$mode has exit $result instead of $expected" "$(<"$run_dir/err")"
  [[ -z $(find "$run_dir/tmp" -mindepth 1 -print -quit) ]] || fail "$mode leaked its staged sudoers file"
  [[ $(<"$run_dir/caller-exit") == "caller exit" ]] || fail "$mode replaced or duplicated the caller's EXIT trap"
  if [[ $mode == "success" ]]; then
    cmp -s "$run_dir/traps-before" "$run_dir/traps-after" || fail "runtime writer changed caller traps"
    [[ -s $run_dir/runtime.conf && -s $run_dir/sudoers ]] || fail "runtime writer did not install the fixture files"
  fi
  pass "runtime link cleans up after $mode and preserves the caller's traps"
done
