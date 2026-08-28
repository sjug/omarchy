#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

main_qml="$ROOT/default/sddm/omarchy/Main.qml"
session_entry="$ROOT/default/wayland-sessions/omarchy.desktop"
session_name=$(sed -n 's/^Name=//p' "$session_entry")

if [[ -z $session_name ]] || ! grep -Fq "if (name === \"$session_name\")" "$main_qml"; then
  fail "SDDM prefers the shipped Omarchy session by its exact display name"
fi
pass "SDDM prefers the shipped Omarchy session by its exact display name"

exact_match_line=$(grep -Fn "if (name === \"$session_name\")" "$main_qml" | cut -d: -f1)
uwsm_fallback_line=$(grep -Fn 'name.toLowerCase().indexOf("uwsm")' "$main_qml" | cut -d: -f1)
if (( exact_match_line >= uwsm_fallback_line )); then
  fail "SDDM checks the generic UWSM fallback before the Omarchy session"
fi
pass "SDDM falls back to another UWSM session only after checking Omarchy"

if ! grep -Fq 'onTextChanged: if (text.length > 0) root.loginFailed = false' "$main_qml"; then
  fail "SDDM preserves failed-login feedback while clearing the password programmatically"
fi
pass "SDDM preserves failed-login feedback until the user types again"
