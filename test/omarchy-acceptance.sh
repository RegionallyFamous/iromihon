#!/bin/bash

set -Eeuo pipefail

# shellcheck source=/dev/null
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

FIXTURE="$ROOT/test/acceptance.d/fixtures/plugin"
PLUGIN_ID=$(jq -er '.id' "$FIXTURE/manifest.json")
[[ $PLUGIN_ID =~ ^[a-z0-9][a-z0-9._-]*$ && $PLUGIN_ID != *".."* ]] || fail "Iromihon plugin id is safe"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
LAYER_NAMESPACE="iromihon"
QMLLINT_BIN=$(command -v qmllint || true)
: "${QMLLINT_BIN:=/usr/lib/qt6/bin/qmllint}"
SOURCE_URL="https://github.com/RegionallyFamous/omarchy-chaos-themes.git"
SOURCE_ID="omarchy-chaos-themes-$(printf '%s' "$SOURCE_URL" | sha256sum | cut -c1-12)"
SOURCE_ORIGIN="$HOME/.cache/iromihon-acceptance-origin"
SOURCE_PATH="$HOME/.local/share/omarchy/theme-sources/$SOURCE_ID"
SOURCE_STATE="$HOME/.local/state/omarchy/theme-sources/$SOURCE_ID"
THEMES_DIR="$HOME/.config/omarchy/themes"
LAUNCHER="$HOME/.local/share/applications/$PLUGIN_ID.desktop"

screen_lacks() {
  ! screen_contains "$1"
}

plugin_absent() {
  ! omarchy plugin list --json | jq -e --arg id "$PLUGIN_ID" 'any(.[]; .id == $id)'
}

install_test_source() {
  rm -rf "$SOURCE_ORIGIN" "$SOURCE_PATH" "$SOURCE_STATE"
  mkdir -p "$SOURCE_ORIGIN"
  cp -a "$FIXTURE/test/fixtures/source/." "$SOURCE_ORIGIN/"
  git init -q -b main "$SOURCE_ORIGIN"
  git -C "$SOURCE_ORIGIN" config user.name IromihonAcceptance
  git -C "$SOURCE_ORIGIN" config user.email iromihon@example.invalid
  git -C "$SOURCE_ORIGIN" add -A
  git -C "$SOURCE_ORIGIN" commit -q -m "Acceptance collection"
  mkdir -p "$(dirname "$SOURCE_PATH")"
  git clone -q --no-local "$SOURCE_ORIGIN" "$SOURCE_PATH"
  git -C "$SOURCE_PATH" remote set-url origin "$SOURCE_URL"
}

cleanup_iromihon() {
  omarchy-shell shell hide "$PLUGIN_ID" >/dev/null 2>&1 || true
  if [[ -e $PLUGIN_DIR ]]; then
    omarchy plugin remove "$PLUGIN_ID" --yes >/dev/null 2>&1 || {
      rm -rf "$PLUGIN_DIR"
      omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
    }
  fi
  rm -f "$LAUNCHER"
  rm -f "$THEMES_DIR/xerox-riot" "$THEMES_DIR/cable-rat-king" "$THEMES_DIR/safety-third" "$THEMES_DIR/channel-zero"
  rm -rf "$SOURCE_PATH" "$SOURCE_STATE" "$SOURCE_ORIGIN"
}
trap cleanup_iromihon EXIT

collect_shell_diagnostics() {
  {
    echo "==> omarchy-shell ping"
    omarchy-shell shell ping 2>&1 || true
    echo "==> quickshell instances"
    quickshell list -p "$OMARCHY_PATH/shell" --any-display 2>&1 || true
    echo "==> quickshell log"
    quickshell --no-color log -p "$OMARCHY_PATH/shell" --any-display --tail 240 2>&1 || true
    echo "==> omarchy-shell journal"
    journalctl -t omarchy-shell -n 240 --no-pager --quiet 2>&1 || true
  } >"$ARTIFACTS/iromihon-shell-diagnostics.log"
}

handle_unexpected_error() {
  local status=$?
  local line="$1"
  local command="$2"

  trap - ERR
  collect_shell_diagnostics
  {
    printf '\n==> unexpected test command failure\n'
    printf 'line=%s status=%s command=%s\n' "$line" "$status" "$command"
  } >>"$ARTIFACTS/iromihon-shell-diagnostics.log"
  screenshot "failure-iromihon-unexpected-command"
  printf 'not ok - Iromihon guest acceptance stopped unexpectedly\n' >&2
  exit "$status"
}
trap 'handle_unexpected_error "$LINENO" "$BASH_COMMAND"' ERR

[[ ! -e $PLUGIN_DIR ]] || fail "Iromihon is absent before installation"
[[ -x $QMLLINT_BIN ]] || fail "the Quattro guest provides qmllint"
if ! "$QMLLINT_BIN" -I "$OMARCHY_PATH/shell" "$FIXTURE/Iromihon.qml" "$FIXTURE/Service.qml" >"$ARTIFACTS/iromihon-qmllint.log" 2>&1; then
  fail "Iromihon passes qmllint" "$(<"$ARTIFACTS/iromihon-qmllint.log")"
fi
pass "Iromihon passes qmllint"
"$OMARCHY_PATH/bin/omarchy-plugin-validate" "$FIXTURE" || fail "Iromihon passes the host validator"
pass "Iromihon passes the host validator"

install_test_source
[[ $(git -C "$SOURCE_PATH" config --get remote.origin.url) == "$SOURCE_URL" ]] || fail "the collection fixture matches the requested public source"
pass "the collection cache is seeded without a core source API"
mkdir -p "$(dirname "$PLUGIN_DIR")"
cp -a "$FIXTURE" "$PLUGIN_DIR"
[[ -x $PLUGIN_DIR/scripts/source-command ]] || fail "the embedded source command is executable after installation"
[[ ! $(command -v omarchy-theme-source-inspect || true) ]] || fail "the pinned guest unexpectedly provides the proposed core source API"
pass "the guest has no core source API, forcing the real embedded engine"
if ! rescan_output=$(omarchy-shell shell rescanPlugins 2>&1); then
  collect_shell_diagnostics
  fail "Iromihon is discovered" "$rescan_output"
fi
wait_until "Iromihon is discovered" 15 \
  bash -c "omarchy plugin list --json | jq -e --arg id '$PLUGIN_ID' 'any(.[]; .id == \$id)'"

omarchy plugin enable "$PLUGIN_ID" >/dev/null
wait_until "Iromihon is enabled" 15 \
  bash -c "omarchy plugin list --json | jq -e --arg id '$PLUGIN_ID' 'any(.[]; .id == \$id and .enabled)'"
wait_until "Iromihon adds its Apps launcher" 15 test -f "$LAUNCHER"

launch_app "gtk-launch '$PLUGIN_ID'"
wait_until "Iromihon opens from Apps" 20 layer_on_screen "$LAYER_NAMESPACE"
wait_until "the Apps launcher opens source entry" 20 screen_contains "One repository"
screenshot "success-iromihon-00-apps-entry"
wtype -k Escape
wait_until "Iromihon closes after the Apps launch" 20 layer_absent "$LAYER_NAMESPACE"

payload=$(jq -cn '{url: "https://github.com/RegionallyFamous/omarchy-chaos-themes.git#xerox-riot"}')
omarchy-shell shell summon "$PLUGIN_ID" "$payload" >/dev/null
wait_until "Iromihon opens through the shell" 20 layer_on_screen "$LAYER_NAMESPACE"
wait_until "Iromihon brand is visible" 20 screen_contains "Iromihon"
wait_until "the deep-linked child is selected" 20 screen_contains "Xerox Riot"
wait_until "the embedded engine registers the shared collection" 20 test -d "$SOURCE_STATE"
screenshot "success-iromihon-01-xerox-riot"

wtype -k Right
wait_until "right arrow browses one sibling" 15 screen_contains "Cable Rat King"
screenshot "success-iromihon-02-cable-rat-king"

wtype -k i
wait_until "install-only keeps Iromihon open" 15 layer_on_screen "$LAYER_NAMESPACE"
wait_until "install-only creates one native child link" 15 test -L "$THEMES_DIR/cable-rat-king"
[[ ! -e $THEMES_DIR/xerox-riot ]] || fail "install-only exposed an unselected sibling"
wait_until "install-only updates the selected child action" 15 screen_contains "Apply theme"
screenshot "success-iromihon-03-installed-only"

wtype -k Return
wait_until "apply closes Iromihon" 20 layer_absent "$LAYER_NAMESPACE"
wait_until "apply invokes Omarchy's normal theme setter" 20 \
  bash -c "grep -Fxq 'cable-rat-king' '$HOME/.local/state/omarchy/current/theme.name'"
wait_until "Iromihon pixels clear after apply" 10 screen_lacks "Cable Rat King"

omarchy-restart-shell
wait_until "the Omarchy shell restarts" 20 omarchy-shell shell ping
wait_until "Iromihon remains enabled after shell restart" 20 \
  bash -c "omarchy plugin list --json | jq -e --arg id '$PLUGIN_ID' 'any(.[]; .id == \$id and .enabled)'"
installed_payload=$(jq -cn '{url: "https://github.com/RegionallyFamous/omarchy-chaos-themes.git#cable-rat-king"}')
omarchy-shell shell summon "$PLUGIN_ID" "$installed_payload" >/dev/null
wait_until "Iromihon opens after shell restart" 20 layer_on_screen "$LAYER_NAMESPACE"
wait_until "Iromihon renders the installed child after shell restart" 20 screen_contains "Cable Rat King"
screenshot "success-iromihon-04-after-shell-restart"

wtype -k d
wait_until "remove detaches only the selected child" 15 test ! -e "$THEMES_DIR/cable-rat-king"
wait_until "remove keeps Iromihon open" 15 layer_on_screen "$LAYER_NAMESPACE"
wait_until "remove restores the selected child's install controls" 15 screen_contains "Install only"
screenshot "success-iromihon-05-detached"

wtype -k g
wait_until "another-source control returns to entry" 15 screen_contains "One repository"
screenshot "success-iromihon-06-source-entry"
wtype -k Escape
wait_until "Escape closes Iromihon" 20 layer_absent "$LAYER_NAMESPACE"

omarchy plugin remove "$PLUGIN_ID" --yes >/dev/null
wait_until "Iromihon is removed from disk" 15 test ! -e "$PLUGIN_DIR"
wait_until "Iromihon is removed from the shell registry" 15 plugin_absent

pass "Iromihon guest acceptance passed"
