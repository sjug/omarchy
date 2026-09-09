#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
git_log="$test_tmp/git.log"
checkupdates_log="$test_tmp/checkupdates.log"
mkdir -p "$stub_bin"

cat >"$stub_bin/checkupdates" <<'SH'
#!/bin/bash
echo called >>"$TEST_CHECKUPDATES_LOG"
case "${TEST_CHECKUPDATES:-updates}" in
  updates)
    printf 'linux 6.1-1 -> 6.1-2\nomarchy 4.0.0-1 -> 4.0.1-1\nomarchy-settings 4.0.0-1 -> 4.0.1-1\nomarchy-dev 4.1.0-1 -> 4.1.1-1\nomarchy-settings-dev 4.1.0-1 -> 4.1.1-1\n'
    exit 0
    ;;
  none)
    exit 2
    ;;
  fail)
    echo "check failed" >&2
    exit 1
    ;;
esac
SH
chmod +x "$stub_bin/checkupdates"

cat >"$stub_bin/pacman" <<'SH'
#!/bin/bash
case "$1" in
  -Qq)
    case "${TEST_INSTALLED_PACKAGE:-omarchy}" in
      omarchy)
        [[ $2 == "omarchy" ]]; exit $?
        ;;
      omarchy-dev)
        [[ $2 == "omarchy-dev" ]]; exit $?
        ;;
      both)
        [[ $2 == "omarchy" || $2 == "omarchy-dev" ]]; exit $?
        ;;
      none)
        exit 1
        ;;
    esac
    ;;
esac
exit 0
SH
chmod +x "$stub_bin/pacman"

cat >"$stub_bin/omarchy-installation-type" <<'SH'
#!/bin/bash
echo "${TEST_INSTALLATION_TYPE:-product}"
SH
chmod +x "$stub_bin/omarchy-installation-type"

cat >"$stub_bin/omarchy-overlay-stages" <<'SH'
#!/bin/bash
echo core
SH
chmod +x "$stub_bin/omarchy-overlay-stages"

cat >"$stub_bin/git" <<'SH'
#!/bin/bash

printf '%s\n' "$*" >>"$TEST_GIT_LOG"

[[ $1 == "-C" ]] || exit 1
shift 2

case "$1" in
  fetch)
    [[ ${TEST_GIT_FETCH:-ok} == "ok" ]]
    ;;
  status)
    [[ ${TEST_GIT_STATE:-clean} != "dirty" ]] || echo ' M changed-file'
    if [[ ${TEST_GIT_STATE:-clean} == "untracked" && $* == *"--untracked-files=normal"* ]]; then
      echo '?? stray-file'
    fi
    ;;
  symbolic-ref)
    [[ ${TEST_GIT_STATE:-clean} != "detached" ]] || exit 1
    echo quattro
    ;;
  rev-parse)
    case "$2" in
      --is-inside-work-tree)
        [[ ${TEST_GIT_CHECKOUT:-yes} == "yes" ]] || exit 1
        echo true
        ;;
      --abbrev-ref)
        [[ ${TEST_GIT_UPSTREAM:-origin/quattro} != "none" ]] || exit 1
        echo "${TEST_GIT_UPSTREAM:-origin/quattro}"
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  rev-list)
    if [[ $* == *"HEAD.."* ]]; then
      echo "${TEST_GIT_BEHIND:-0}"
    else
      echo "${TEST_GIT_AHEAD:-0}"
    fi
    ;;
  *)
    exit 1
    ;;
esac
SH
chmod +x "$stub_bin/git"

run_checker() {
  OMARCHY_PATH="${TEST_OMARCHY_PATH:-/usr/share/omarchy}" \
    TEST_GIT_LOG="$git_log" \
    TEST_CHECKUPDATES_LOG="$checkupdates_log" \
    TEST_GIT_STATE="${TEST_GIT_STATE:-clean}" \
    PATH="$stub_bin:$PATH" \
    "$ROOT/bin/omarchy-update-available"
}

capture_checker() {
  local stdout_file="$1"
  local stderr_file="$2"
  shift 2

  set +e
  (
    local assignment
    for assignment in "$@"; do
      export "${assignment?}"
    done
    run_checker
  ) >"$stdout_file" 2>"$stderr_file"
  local status=$?
  set -e
  return "$status"
}

stdout="$test_tmp/stdout"
stderr="$test_tmp/stderr"

if capture_checker "$stdout" "$stderr" TEST_CHECKUPDATES=updates TEST_INSTALLED_PACKAGE=omarchy; then
  status=0
else
  status=$?
fi
[[ $status -eq 0 ]] || fail "update checker exits successfully when omarchy update is available"
grep -q '^omarchy ' "$stdout" || fail "update checker prints omarchy updates"
! grep -q '^omarchy-settings ' "$stdout" || fail "update checker ignores omarchy-settings updates"
! grep -q '^linux ' "$stdout" || fail "update checker ignores non-Omarchy package updates"
! grep -q '^omarchy-dev ' "$stdout" || fail "update checker ignores omarchy-dev when omarchy is installed"
pass "update checker detects installed omarchy package updates"

if capture_checker "$stdout" "$stderr" TEST_CHECKUPDATES=updates TEST_INSTALLED_PACKAGE=omarchy-dev; then
  status=0
else
  status=$?
fi
[[ $status -eq 0 ]] || fail "update checker exits successfully when omarchy-dev update is available"
grep -q '^omarchy-dev ' "$stdout" || fail "update checker prints omarchy-dev updates"
! grep -q '^omarchy-settings-dev ' "$stdout" || fail "update checker ignores omarchy-settings-dev updates"
! grep -q '^omarchy ' "$stdout" || fail "update checker ignores omarchy when omarchy-dev is installed"
pass "update checker detects installed omarchy-dev package updates"

if capture_checker "$stdout" "$stderr" TEST_CHECKUPDATES=updates TEST_INSTALLED_PACKAGE=both; then
  status=0
else
  status=$?
fi
[[ $status -eq 0 ]] || fail "update checker prefers omarchy-dev when both packages are installed"
grep -q '^omarchy-dev ' "$stdout" || fail "update checker prints omarchy-dev when both packages are installed"
! grep -q '^omarchy ' "$stdout" || fail "update checker ignores omarchy when omarchy-dev is installed"
pass "update checker prefers omarchy-dev over omarchy"

if capture_checker "$stdout" "$stderr" TEST_CHECKUPDATES=updates TEST_INSTALLED_PACKAGE=none; then
  status=0
else
  status=$?
fi
[[ $status -eq 1 ]] || fail "update checker exits non-zero when no Omarchy package is installed"
[[ ! -s $stderr ]] || fail "update checker is quiet when no Omarchy package is installed"
pass "update checker ignores systems without omarchy or omarchy-dev installed"

if capture_checker "$stdout" "$stderr" TEST_CHECKUPDATES=none TEST_INSTALLED_PACKAGE=omarchy; then
  status=0
else
  status=$?
fi
[[ $status -eq 1 ]] || fail "update checker exits non-zero when no updates are available"
grep -q '^Omarchy is up to date$' "$stdout" || fail "update checker prints up-to-date message"
pass "update checker reports up-to-date Omarchy packages"

: >"$git_log"
: >"$checkupdates_log"
if capture_checker "$stdout" "$stderr" \
  TEST_CHECKUPDATES=none \
  TEST_INSTALLED_PACKAGE=none \
  TEST_INSTALLATION_TYPE=desktop_overlay \
  TEST_OMARCHY_PATH="$test_tmp/checkout" \
  TEST_GIT_BEHIND=2; then
  status=0
else
  status=$?
fi
(( status == 0 )) || fail "update checker exits successfully when overlay commits are available"
grep -Fx 'omarchy-desktop-overlay 2 new commits on origin/quattro' "$stdout" >/dev/null ||
  fail "update checker reports available overlay commits" "$(cat "$stdout")"
grep -Fx -- "-C $test_tmp/checkout fetch --quiet" "$git_log" >/dev/null ||
  fail "update checker fetches the overlay checkout upstream" "$(cat "$git_log")"
[[ ! -s $checkupdates_log ]] || fail "desktop-overlay indicator does not inspect product package updates" "$(<"$checkupdates_log")"
pass "update checker detects new commits in the overlay checkout"

if capture_checker "$stdout" "$stderr" \
  TEST_CHECKUPDATES=none \
  TEST_INSTALLED_PACKAGE=none \
  TEST_INSTALLATION_TYPE=desktop_overlay \
  TEST_OMARCHY_PATH="$test_tmp/checkout" \
  TEST_GIT_BEHIND=0; then
  status=0
else
  status=$?
fi
(( status == 1 )) || fail "update checker exits non-zero when the overlay checkout is current"
grep -q '^Omarchy is up to date$' "$stdout" || fail "update checker reports a current overlay checkout"
pass "update checker ignores a current overlay checkout"

: >"$git_log"
if capture_checker "$stdout" "$stderr" \
  TEST_CHECKUPDATES=none \
  TEST_INSTALLED_PACKAGE=none \
  TEST_INSTALLATION_TYPE=desktop_overlay \
  TEST_OMARCHY_PATH="$test_tmp/checkout" \
  TEST_GIT_STATE=untracked \
  TEST_GIT_BEHIND=0; then
  status=0
else
  status=$?
fi
(( status == 1 )) || fail "an untracked checkout file freezes update detection" "status: $status\n$(<"$stderr")"
grep -Fx -- "-C $test_tmp/checkout status --porcelain --untracked-files=no" "$git_log" >/dev/null ||
  fail "overlay indicator inspects untracked checkout files" "$(<"$git_log")"
pass "untracked checkout files do not freeze the update indicator"

if env -u OMARCHY_PATH \
  TEST_GIT_LOG="$git_log" \
  TEST_CHECKUPDATES_LOG="$checkupdates_log" \
  TEST_INSTALLATION_TYPE=desktop_overlay \
  PATH="$stub_bin:$PATH" \
  "$ROOT/bin/omarchy-update-available" >"$stdout" 2>"$stderr"; then
  status=0
else
  status=$?
fi
(( status == 2 )) || fail "an unlinked overlay crashes or looks current when OMARCHY_PATH is unset" "status: $status"
grep -q 'not running from its registered checkout' "$stderr" ||
  fail "an unlinked overlay does not explain its missing runtime path" "$(<"$stderr")"
pass "overlay update checks fail cleanly rather than crashing when OMARCHY_PATH is unset"

if capture_checker "$stdout" "$stderr" \
  TEST_CHECKUPDATES=none \
  TEST_INSTALLED_PACKAGE=none \
  TEST_INSTALLATION_TYPE=desktop_overlay \
  TEST_OMARCHY_PATH="$test_tmp/checkout" \
  TEST_GIT_BEHIND=1 \
  TEST_GIT_FETCH=fail; then
  status=0
else
  status=$?
fi
[[ $status -eq 0 ]] || fail "update checker uses cached upstream state when fetch fails"
grep -Fx 'omarchy-desktop-overlay 1 new commit on origin/quattro' "$stdout" >/dev/null ||
  fail "update checker reports cached overlay commits after a fetch failure" "$(cat "$stdout")"
[[ ! -s $stderr ]] || fail "update checker keeps dev fetch failures quiet" "$(cat "$stderr")"
pass "update checker uses cached overlay state when fetching is unavailable"

if capture_checker "$stdout" "$stderr" \
  TEST_CHECKUPDATES=none \
  TEST_INSTALLED_PACKAGE=none \
  TEST_INSTALLATION_TYPE=desktop_overlay \
  TEST_OMARCHY_PATH="$test_tmp/checkout" \
  TEST_GIT_UPSTREAM=none; then
  status=0
else
  status=$?
fi
(( status == 2 )) || fail "overlay indicator does not distinguish a missing upstream from no updates" "status: $status"
grep -q "has no configured upstream" "$stderr" || fail "overlay indicator reports its missing upstream" "$(<"$stderr")"

if capture_checker "$stdout" "$stderr" \
  TEST_CHECKUPDATES=none \
  TEST_INSTALLED_PACKAGE=none \
  TEST_INSTALLATION_TYPE=desktop_overlay \
  TEST_OMARCHY_PATH="$test_tmp/checkout" \
  TEST_GIT_BEHIND=1 \
  TEST_GIT_AHEAD=1; then
  status=0
else
  status=$?
fi
(( status == 2 )) || fail "overlay indicator does not distinguish divergence from available updates" "status: $status"
grep -q "has diverged" "$stderr" || fail "overlay indicator reports divergence" "$(<"$stderr")"

for unsafe_state in dirty detached; do
  if capture_checker "$stdout" "$stderr" \
    TEST_CHECKUPDATES=none \
    TEST_INSTALLED_PACKAGE=none \
    TEST_INSTALLATION_TYPE=desktop_overlay \
    TEST_OMARCHY_PATH="$test_tmp/checkout" \
    TEST_GIT_STATE="$unsafe_state"; then
    status=0
  else
    status=$?
  fi
  (( status == 2 )) || fail "overlay indicator treats $unsafe_state checkout as updatable" "status: $status"
done
pass "overlay indicator fails distinctly for every checkout state the updater refuses"
