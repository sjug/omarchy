#!/bin/bash

set -euo pipefail

# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
checkout="$test_tmp/checkout"
call_log="$test_tmp/calls.log"
git_log="$test_tmp/git.log"
timeout_log="$test_tmp/timeout.log"
script_log="$test_tmp/script.log"
lock_log="$test_tmp/lock.log"
state_dir="$test_tmp/migration-state"
test_home="$test_tmp/home with spaces"
mkdir -p "$stub_bin" "$checkout/bin"
mkdir -p "$test_home/.local/share/fonts" "$checkout/default/fonts/omarchy"
mkdir -p "$state_dir"
touch "$state_dir/.baseline-established"

write_log_stub() {
  local command="$1"
  cat >"$stub_bin/$command" <<'SH'
#!/bin/bash
printf '%s' "${0##*/}" >>"$TEST_CALL_LOG"
for arg in "$@"; do printf '\t%s' "$arg" >>"$TEST_CALL_LOG"; done
printf '\n' >>"$TEST_CALL_LOG"
if [[ ${0##*/} == "omarchy-overlay-setup" && ${TEST_FAILING_STEP:-} == "artifact-preflight" && ${1:-} == "artifacts" && ${2:-} == "--check" ]]; then
  exit 1
fi
[[ ${TEST_FAILING_STEP:-} != "${0##*/}" ]] || exit 1
SH
  chmod +x "$stub_bin/$command"
}

for command in \
  install \
  fc-cache \
  omarchy-installation-type \
  omarchy-update-requires-free-space \
  omarchy-update-confirm \
  omarchy-overlay-setup \
  omarchy-overlay-migrate \
  omarchy-hook \
  omarchy-update-status \
  omarchy-update-restart; do
  write_log_stub "$command"
done

cat >"$stub_bin/script" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_SCRIPT_LOG"
SH
chmod +x "$stub_bin/script"

cat >"$stub_bin/omarchy-update-lock" <<'SH'
#!/bin/bash
if [[ $1 == "held" ]]; then
  [[ ${TEST_LOCK_HELD:-1} == "1" ]]
elif [[ $1 == "run" ]]; then
  printf '%s\n' "$*" >>"$TEST_LOCK_LOG"
else
  exit 1
fi
SH
chmod +x "$stub_bin/omarchy-update-lock"

cat >"$stub_bin/timeout" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_TIMEOUT_LOG"
exec /usr/bin/timeout "$@"
SH
chmod +x "$stub_bin/timeout"

cat >"$stub_bin/omarchy-installation-type" <<'SH'
#!/bin/bash
printf '%s' "${0##*/}" >>"$TEST_CALL_LOG"
for arg in "$@"; do printf '\t%s' "$arg" >>"$TEST_CALL_LOG"; done
printf '\n' >>"$TEST_CALL_LOG"
echo desktop_overlay
SH
chmod +x "$stub_bin/omarchy-installation-type"

cat >"$stub_bin/omarchy-overlay-stages" <<'SH'
#!/bin/bash
printf '%s\n' core link config audio files connectivity capture power lock session-entry display-manager
SH
chmod +x "$stub_bin/omarchy-overlay-stages"

for forbidden in omarchy-snapshot omarchy-update-dev omarchy-update-stay-awake omarchy-update-keyring omarchy-update-system-pkgs omarchy-migrate omarchy-update-aur-pkgs omarchy-update-mise omarchy-update-orphan-pkgs omarchy-update-analyze-logs; do
  cat >"$stub_bin/$forbidden" <<'SH'
#!/bin/bash
echo "forbidden overlay update command: ${0##*/}" >&2
exit 97
SH
  chmod +x "$stub_bin/$forbidden"
done

cat >"$stub_bin/git" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_GIT_LOG"
[[ $1 == "-C" ]] || exit 1
shift 2
case "$1" in
  status)
    [[ ${TEST_GIT_STATE:-clean} != "dirty" ]] || echo ' M changed-file'
    ;;
  symbolic-ref)
    [[ ${TEST_GIT_STATE:-clean} != "detached" ]] || exit 1
    echo quattro
    ;;
  rev-parse)
    case "$2" in
      --is-inside-work-tree) echo true ;;
      --abbrev-ref)
        [[ ${TEST_GIT_STATE:-clean} != "no-upstream" ]] || exit 1
        echo origin/quattro
        ;;
      HEAD) echo new-head ;;
      *) exit 1 ;;
    esac
    ;;
  fetch)
    [[ ${GIT_TERMINAL_PROMPT:-} == "0" && ${GIT_SSH_COMMAND:-} == "${TEST_EXPECT_SSH_COMMAND-ssh -o BatchMode=yes}" ]]
    ;;
  config)
    if [[ $3 == "core.sshCommand" && -n ${TEST_CORE_SSH_COMMAND:-} ]]; then
      echo "$TEST_CORE_SSH_COMMAND"
    else
      exit 1
    fi
    ;;
  rev-list)
    case "${TEST_GIT_STATE:-clean}" in
      behind) echo '0 1' ;;
      ahead) echo '1 0' ;;
      divergent) echo '1 1' ;;
      *) echo '0 0' ;;
    esac
    ;;
  show)
    [[ $2 == "origin/quattro:bin/omarchy-update" ]] || exit 1
    [[ ${TEST_UPSTREAM_DISPATCH:-1} != "missing" ]] || exit 128
    echo '#!/bin/bash'
    if [[ ${TEST_UPSTREAM_DISPATCH:-1} == "1" ]]; then
      echo '# Desktop-overlay update dispatch is supported.'
    fi
    ;;
  merge)
    [[ $2 == "--ff-only" && $3 == "origin/quattro" ]]
    ;;
  merge-base)
    exit 0
    ;;
  diff)
    if [[ ${@: -1} == "default/fonts/omarchy/omarchy.ttf" ]]; then
      if [[ ${TEST_ICON_FONT_CHANGE:-none} == "modified" || ${TEST_ICON_FONT_CHANGE:-none} == "deleted" ]]; then
        echo default/fonts/omarchy/omarchy.ttf
      fi
    elif [[ ${TEST_CHANGED_CONFIGS:-0} == 1 && $* == *"--diff-filter=D"* ]]; then
      echo config/retired.conf
    elif [[ ${TEST_CHANGED_CONFIGS:-0} == 1 ]]; then
      printf '%s\n' config/hypr/hyprland.lua config/foot/foot.ini
    fi
    ;;
  *)
    exit 1
    ;;
esac
SH
chmod +x "$stub_bin/git"

cat >"$checkout/bin/omarchy-update" <<'SH'
#!/bin/bash
# Desktop-overlay update dispatch is supported.
printf 'reexec\tmarker=%s\told=%s\targs=%s\n' \
  "${OMARCHY_OVERLAY_UPDATE_REEXECUTED:-}" \
  "${OMARCHY_OVERLAY_UPDATE_OLD_HEAD:-}" \
  "$*" >>"$TEST_CALL_LOG"
SH
chmod +x "$checkout/bin/omarchy-update"

run_overlay_update() {
  : >"$call_log"
  : >"$git_log"
  : >"$timeout_log"
  : >"$script_log"
  : >"$lock_log"
  HOME="$test_home" \
    OMARCHY_PATH="$checkout" \
    TEST_CALL_LOG="$call_log" \
    TEST_GIT_LOG="$git_log" \
    TEST_TIMEOUT_LOG="$timeout_log" \
    TEST_SCRIPT_LOG="$script_log" \
    TEST_LOCK_LOG="$lock_log" \
    TEST_LOCK_HELD="${TEST_LOCK_HELD:-1}" \
    TEST_GIT_STATE="${TEST_GIT_STATE:-clean}" \
    TEST_CHANGED_CONFIGS="${TEST_CHANGED_CONFIGS:-0}" \
    TEST_ICON_FONT_CHANGE="${TEST_ICON_FONT_CHANGE:-none}" \
    TEST_UPSTREAM_DISPATCH="${TEST_UPSTREAM_DISPATCH:-1}" \
    TEST_FAILING_STEP="${TEST_FAILING_STEP:-}" \
    OMARCHY_UPDATE_LOGGED=1 \
    OMARCHY_OVERLAY_MIGRATION_STATE="$state_dir" \
    PATH="$stub_bin:$PATH" \
    "$ROOT/bin/omarchy-update-overlay" "$@"
}

# The hidden binary remains directly routable, so it must establish the same
# transcript and update lock as the public dispatcher before doing any work.
: >"$script_log"
OMARCHY_PATH="$checkout" \
  TEST_SCRIPT_LOG="$script_log" \
  TEST_CALL_LOG="$call_log" \
  PATH="$stub_bin:$PATH" \
  "$ROOT/bin/omarchy-update-overlay" -y
grep -q -- "-qefc .*omarchy-update-overlay.*-y. /tmp/omarchy-update.log" "$script_log" ||
  fail "direct overlay update does not enter the shared transcript" "$(<"$script_log")"

: >"$lock_log"
OMARCHY_PATH="$checkout" \
  TEST_LOCK_LOG="$lock_log" \
  TEST_LOCK_HELD=0 \
  OMARCHY_UPDATE_LOGGED=1 \
  PATH="$stub_bin:$PATH" \
  "$ROOT/bin/omarchy-update-overlay" -y
grep -q "^run $ROOT/bin/omarchy-update-overlay -y$" "$lock_log" ||
  fail "direct overlay update does not enter the shared update lock" "$(<"$lock_log")"
pass "direct overlay entry acquires the shared transcript and update lock"

OMARCHY_OVERLAY_UPDATE_REEXECUTED=1 \
  OMARCHY_OVERLAY_UPDATE_OLD_HEAD=old-head \
  TEST_CHANGED_CONFIGS=1 \
  run_overlay_update -y >"$test_tmp/out"

expected=$'omarchy-installation-type\nomarchy-overlay-setup\tartifacts\t--check\tlock\tdisplay-manager\nomarchy-overlay-setup\tpackages\tcore\taudio\tfiles\tconnectivity\tcapture\tpower\tdisplay-manager\nomarchy-overlay-setup\tartifacts\tlock\tdisplay-manager\nomarchy-overlay-migrate\nomarchy-hook\tpost-update\nomarchy-update-status\nomarchy-update-restart'
[[ $(<"$call_log") == "$expected" ]] || fail "overlay update runs only its agreed stage-aware sequence" "$(<"$call_log")"
grep -q 'omarchy refresh config hypr/hyprland.lua' "$test_tmp/out" || fail "changed Hyprland config gets a manual refresh command" "$(<"$test_tmp/out")"
grep -q 'omarchy refresh config foot/foot.ini' "$test_tmp/out" || fail "changed Foot config gets a manual refresh command" "$(<"$test_tmp/out")"
grep -q 'config/retired.conf' "$test_tmp/out" || fail "removed defaults are reported without an invalid refresh command" "$(<"$test_tmp/out")"
if grep -q 'omarchy refresh config retired.conf' "$test_tmp/out"; then
  fail "a removed default gets an unusable refresh command" "$(<"$test_tmp/out")"
fi
pass "overlay update reconciles packages and static system artifacts without overwriting user preferences"

if TEST_FAILING_STEP=artifact-preflight run_overlay_update -y >"$test_tmp/preflight.out" 2>"$test_tmp/preflight.err"; then
  fail "a failed artifact preflight passes for a successful update"
fi
if grep -q $'^omarchy-overlay-setup\tpackages' "$call_log"; then
  fail "a failed artifact preflight reaches the package transaction" "$(<"$call_log")"
fi
if grep -q $'^omarchy-update-confirm$' "$call_log" || grep -q ' fetch$' "$git_log"; then
  fail "a failed host artifact preflight runs after confirmation or checkout fetch" "calls:\n$(<"$call_log")\ngit:\n$(<"$git_log")"
fi
pass "host artifact preconditions run before confirmation, checkout mutation, or packages"

if ! TEST_FAILING_STEP=omarchy-update-confirm run_overlay_update >"$test_tmp/decline.out" 2>"$test_tmp/decline.err"; then
  fail "declining an overlay update is reported as an update failure"
fi
grep -q $'^omarchy-overlay-setup\tartifacts\t--check' "$call_log" ||
  fail "confirmation runs before host artifact validation" "$(<"$call_log")"
if grep -q ' fetch$' "$git_log" || grep -q $'^omarchy-overlay-setup\tpackages' "$call_log"; then
  fail "a declined update fetches or changes packages" "calls:\n$(<"$call_log")\ngit:\n$(<"$git_log")"
fi
pass "declining after successful preflight exits cleanly without fetching"

grep -Fx -- "-C $checkout status --porcelain --untracked-files=no" "$git_log" >/dev/null ||
  fail "overlay updater inspects untracked checkout files" "$(<"$git_log")"
TEST_GIT_STATE=untracked run_overlay_update -y >/dev/null
grep -q $'^omarchy-overlay-setup\tpackages' "$call_log" ||
  fail "an untracked checkout file freezes overlay updates" "$(<"$call_log")"
pass "untracked checkout files do not block overlay updates"

TEST_GIT_STATE=ahead run_overlay_update -y >/dev/null
grep -Fx -- "-C $checkout fetch" "$git_log" >/dev/null || fail "overlay update fetches the configured upstream" "$(<"$git_log")"
grep -Fx '30 git -C '"$checkout"' fetch' "$timeout_log" >/dev/null ||
  fail "overlay update bounds its noninteractive fetch" "$(<"$timeout_log")"
if grep -q " merge " "$git_log"; then
  fail "a locally-ahead overlay checkout is unnecessarily merged" "$(<"$git_log")"
fi
grep -q $'^omarchy-overlay-setup\tpackages' "$call_log" || fail "a locally-ahead checkout still reconciles its stages" "$(<"$call_log")"
pass "locally-ahead overlay branches remain supported"

GIT_SSH_COMMAND='ssh -F /custom/config' TEST_EXPECT_SSH_COMMAND='ssh -F /custom/config -o BatchMode=yes' run_overlay_update -y >/dev/null
TEST_CORE_SSH_COMMAND='ssh -i /custom/key' TEST_EXPECT_SSH_COMMAND='ssh -i /custom/key -o BatchMode=yes' run_overlay_update -y >/dev/null
GIT_SSH_VARIANT=plink GIT_SSH_COMMAND='plink -batch' TEST_EXPECT_SSH_COMMAND='plink -batch' run_overlay_update -y >/dev/null
GIT_SSH=/custom/ssh-wrapper TEST_EXPECT_SSH_COMMAND='' run_overlay_update -y >/dev/null
pass "fetch retains configured OpenSSH options and leaves alternate SSH transports intact"

TEST_FAILING_STEP=omarchy-update-status run_overlay_update -y >"$test_tmp/status-failure.out" 2>"$test_tmp/status-failure.err" ||
  fail "an indicator refresh failure turns a completed overlay package update into a failed update"
grep -q $'^omarchy-update-restart$' "$call_log" ||
  fail "an indicator refresh failure skips overlay restart checks" "$(<"$call_log")"
grep -q 'continuing to restart checks' "$test_tmp/status-failure.err" ||
  fail "an overlay indicator failure is not reported as a non-blocking warning" "$(<"$test_tmp/status-failure.err")"
pass "overlay update preserves completed work and restart checks when indicator refresh fails"

TEST_GIT_STATE=behind run_overlay_update -y >/dev/null
grep -Fx -- "-C $checkout merge --ff-only origin/quattro" "$git_log" >/dev/null || fail "behind overlay checkout is fast-forwarded" "$(<"$git_log")"
grep -Fx $'reexec\tmarker=1\told=new-head\targs=-y' "$call_log" >/dev/null ||
  fail "updated checkout is re-executed exactly once with its old revision" "$(<"$call_log")"
if grep -q $'^omarchy-overlay-setup\tpackages' "$call_log" ||
  grep -q $'^omarchy-overlay-setup\tartifacts\t\(lock\|display-manager\|session-entry\)' "$call_log"; then
  fail "the pre-update process continues into artifact or package writes after re-exec" "$(<"$call_log")"
fi
pass "a checkout fast-forward re-executes the updater from the new revision once"

if TEST_GIT_STATE=behind TEST_UPSTREAM_DISPATCH=0 run_overlay_update -y >"$test_tmp/no-dispatch.out" 2>"$test_tmp/no-dispatch.err"; then
  fail "overlay updater re-executes a checkout without overlay dispatch"
fi
grep -q 'refusing to fast-forward into the product update path' "$test_tmp/no-dispatch.err" ||
  fail "missing re-exec protocol marker has no safe explanation" "$(<"$test_tmp/no-dispatch.err")"
if grep -q ' merge ' "$git_log"; then
  fail "missing upstream re-exec marker is checked only after the checkout moves" "$(<"$git_log")"
fi
if grep -q $'^reexec\t' "$call_log" || grep -q $'^omarchy-overlay-setup\tpackages' "$call_log"; then
  fail "missing re-exec marker reaches an updater or package transaction" "$(<"$call_log")"
fi
pass "re-exec compatibility is verified before the checkout fast-forwards"

for unsafe_state in dirty detached no-upstream divergent; do
  if TEST_GIT_STATE="$unsafe_state" run_overlay_update -y >"$test_tmp/out" 2>"$test_tmp/err"; then
    fail "unsafe Git state '$unsafe_state' is accepted"
  fi
  if grep -q $'^omarchy-overlay-setup\tpackages' "$call_log" ||
    grep -q $'^omarchy-overlay-setup\tartifacts\t\(lock\|display-manager\|session-entry\)' "$call_log"; then
    fail "unsafe Git state '$unsafe_state' reaches artifact or package writes" "$(<"$call_log")"
  fi
done
pass "dirty, detached, upstream-less, and divergent overlay checkouts fail before system changes"

rm -f "$state_dir/.baseline-established"
if run_overlay_update -y >"$test_tmp/no-baseline.out" 2>"$test_tmp/no-baseline.err"; then
  fail "overlay update accepts missing migration baseline state"
fi
grep -q 'omarchy overlay register --repair core link config audio files connectivity capture power lock session-entry display-manager' "$test_tmp/no-baseline.err" ||
  fail "missing update baseline does not print its exact registration repair" "$(<"$test_tmp/no-baseline.err")"
if grep -q ' fetch$' "$git_log" || grep -q $'^omarchy-overlay-setup\t' "$call_log"; then
  fail "missing migration baseline reaches host preflight, fetch, or system changes" "calls:\n$(<"$call_log")\ngit:\n$(<"$git_log")"
fi
touch "$state_dir/.baseline-established"
pass "missing migration baseline fails after local Git validation but before host or remote changes"

: >"$call_log"
if env -u OMARCHY_PATH \
  TEST_CALL_LOG="$call_log" \
  TEST_GIT_LOG="$git_log" \
  TEST_TIMEOUT_LOG="$timeout_log" \
  TEST_LOCK_LOG="$lock_log" \
  TEST_LOCK_HELD=1 \
  OMARCHY_UPDATE_LOGGED=1 \
  PATH="$stub_bin:$PATH" \
  "$ROOT/bin/omarchy-update-overlay" -y >"$test_tmp/unlinked.out" 2>"$test_tmp/unlinked.err"; then
  fail "overlay updater accepts an unset OMARCHY_PATH"
fi
grep -q 'OMARCHY_PATH is unset' "$test_tmp/unlinked.err" ||
  fail "overlay updater crashes instead of explaining its missing runtime path" "$(<"$test_tmp/unlinked.err")"
if grep -q $'^omarchy-overlay-setup\t' "$call_log"; then
  fail "an unlinked overlay reaches package reconciliation" "$(<"$call_log")"
fi
pass "overlay updater fails cleanly before package work when the link stage is not active"

# The marker in bin/omarchy-update is a compatibility contract, not a stray
# comment: dropping it stalls every enrolled overlay at its current revision.
# Assert it against the real dispatcher, since every case above only ever sees
# the synthetic upstream written by the git stub.
grep -Fqx '# Desktop-overlay update dispatch is supported.' "$ROOT/bin/omarchy-update" ||
  fail "the real dispatcher no longer carries the overlay-dispatch marker that omarchy-update-overlay requires"
grep -Fq 'Desktop-overlay update dispatch is supported.' "$ROOT/bin/omarchy-update-overlay" ||
  fail "the overlay updater no longer checks for the dispatch marker"
pass "the overlay-dispatch marker contract holds between the real dispatcher and the overlay updater"

: >"$call_log"
if TEST_GIT_STATE=behind TEST_UPSTREAM_DISPATCH=missing run_overlay_update -y \
  >"$test_tmp/absent-dispatch.out" 2>"$test_tmp/absent-dispatch.err"; then
  fail "overlay updater fast-forwards when the upstream dispatcher cannot be read"
fi
grep -q 'does not support desktop-overlay update dispatch' "$test_tmp/absent-dispatch.err" ||
  fail "an unreadable upstream dispatcher does not produce the compatibility refusal" \
    "$(<"$test_tmp/absent-dispatch.err")"
if grep -q $'^git\tmerge' "$git_log"; then
  fail "overlay updater merged despite an unreadable upstream dispatcher" "$(<"$git_log")"
fi
pass "an upstream without bin/omarchy-update is refused rather than fast-forwarded"

# The config stage copies this font once; updates must report source changes
# without overwriting the user's copy or rebuilding their font cache.
printf 'new icon font\n' >"$checkout/default/fonts/omarchy/omarchy.ttf"
printf 'custom user font\n' >"$test_home/.local/share/fonts/omarchy.ttf"
OMARCHY_OVERLAY_UPDATE_REEXECUTED=1 OMARCHY_OVERLAY_UPDATE_OLD_HEAD=old-head \
  TEST_ICON_FONT_CHANGE=modified run_overlay_update -y >"$test_tmp/font-changed.out"
grep -Fq 'Omarchy icon font changed' "$test_tmp/font-changed.out" ||
  fail "an icon-font-only update reports its manual refresh" "$(<"$test_tmp/font-changed.out")"
grep -Fxq '  install -Dm644 -- "$OMARCHY_PATH/default/fonts/omarchy/omarchy.ttf" "$HOME/.local/share/fonts/omarchy.ttf"' "$test_tmp/font-changed.out" ||
  fail "font refresh command uses the configured checkout and quotes both paths"
grep -Fxq '  fc-cache -f' "$test_tmp/font-changed.out" || fail "font refresh includes rebuilding the font cache"
grep -Fxq '  omarchy restart shell' "$test_tmp/font-changed.out" || fail "font refresh explains how to load the new glyphs"
[[ $(<"$test_home/.local/share/fonts/omarchy.ttf") == "custom user font" ]] ||
  fail "font reporting overwrites the user's copy"
[[ $(<"$call_log") == "$expected" ]] || fail "font reporting changes the update sequence" "$(<"$call_log")"
grep -Fxq -- "-C $checkout diff --name-only old-head..new-head -- default/fonts/omarchy/omarchy.ttf" "$git_log" ||
  fail "font reporting does not compare the exact source over the applied revision range"
pass "an icon-font-only update prints refresh commands without modifying user assets"

for font_change in none readme; do
  OMARCHY_OVERLAY_UPDATE_REEXECUTED=1 OMARCHY_OVERLAY_UPDATE_OLD_HEAD=old-head \
    TEST_CHANGED_CONFIGS=1 TEST_ICON_FONT_CHANGE="$font_change" \
    run_overlay_update -y >"$test_tmp/font-unchanged.out"
  if grep -Fq 'fc-cache' "$test_tmp/font-unchanged.out"; then
    fail "unrelated config or font documentation changes prompt a font refresh"
  fi
done
TEST_ICON_FONT_CHANGE=modified run_overlay_update -y >"$test_tmp/no-checkout-change.out"
if grep -Fq 'fc-cache' "$test_tmp/no-checkout-change.out"; then
  fail "an update without a checkout revision change prompts a font refresh"
fi
pass "font refresh notices require an applied change to the icon font itself"

rm "$checkout/default/fonts/omarchy/omarchy.ttf"
OMARCHY_OVERLAY_UPDATE_REEXECUTED=1 OMARCHY_OVERLAY_UPDATE_OLD_HEAD=old-head \
  TEST_ICON_FONT_CHANGE=deleted run_overlay_update -y >"$test_tmp/font-removed.out"
grep -Fq 'Omarchy icon font source was removed' "$test_tmp/font-removed.out" ||
  fail "a removed font source gets an actionable review notice"
if grep -Eq '^  (install|fc-cache|omarchy restart shell)' "$test_tmp/font-removed.out"; then
  fail "a removed font source gets an unusable refresh command"
fi
[[ $(<"$test_home/.local/share/fonts/omarchy.ttf") == "custom user font" ]] ||
  fail "a removed font source deletes the user's installed font"
pass "a removed icon font is reported without copying or removing user files"
