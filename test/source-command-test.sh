#!/bin/bash

set -euo pipefail

PLUGIN_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
COMMAND="$PLUGIN_ROOT/scripts/source-command"
PUBLIC_URL="https://github.com/RegionallyFamous/omarchy-chaos-themes.git"
TEST_ROOT=$(mktemp -d)
ORIGINAL_PATH="$PATH"
IROMIHON_REAL_GIT=$(command -v git)

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$*"
}

commit_origin() {
  git -C "$IROMIHON_TEST_ORIGIN" add -A
  git -C "$IROMIHON_TEST_ORIGIN" commit -q -m "$1"
}

mkdir -p "$TEST_ROOT/origin" "$TEST_ROOT/fake-bin"
cp -a "$PLUGIN_ROOT/test/fixtures/source/." "$TEST_ROOT/origin/"
git init -q -b main "$TEST_ROOT/origin"
git -C "$TEST_ROOT/origin" config user.name IromihonTest
git -C "$TEST_ROOT/origin" config user.email iromihon@example.invalid
export IROMIHON_TEST_ORIGIN="$TEST_ROOT/origin"
commit_origin "Initial collection"

cat >"$TEST_ROOT/fake-bin/git" <<'GIT_WRAPPER'
#!/bin/bash

set -euo pipefail

arguments=("$@")
clone=false
destination=""
for index in "${!arguments[@]}"; do
  if [[ ${arguments[$index]} == "clone" ]]; then
    clone=true
  elif [[ ${arguments[$index]} == "https://github.com/RegionallyFamous/omarchy-chaos-themes.git" ]]; then
    arguments[$index]="$IROMIHON_TEST_ORIGIN"
  fi
done

if [[ $clone == "true" ]]; then
  [[ ${IROMIHON_TEST_GIT_FAIL:-0} != "1" ]] || exit 17
  if [[ ${IROMIHON_TEST_GIT_HANG:-0} == "1" ]]; then
    trap '' TERM
    (
      trap '' TERM
      while true; do sleep 1; done
    ) &
    printf '%s\n' "$!" >"$IROMIHON_TEST_GIT_CHILD_PID"
    wait
  fi
  destination="${arguments[${#arguments[@]} - 1]}"
  "$IROMIHON_REAL_GIT" "${arguments[@]}"
  "$IROMIHON_REAL_GIT" -C "$destination" remote set-url origin "https://github.com/RegionallyFamous/omarchy-chaos-themes.git"
  exit 0
fi

exec "$IROMIHON_REAL_GIT" "${arguments[@]}"
GIT_WRAPPER

cat >"$TEST_ROOT/fake-bin/omarchy" <<'OMARCHY_WRAPPER'
#!/bin/bash

set -euo pipefail

if [[ ${1:-} == "theme" && ${2:-} == "set" && -n ${3:-} ]]; then
  printf '%s\n' "$3" >"$IROMIHON_TEST_APPLIED"
  exit 0
elif [[ ${1:-} == "theme" && ${2:-} == "source" && ${3:-} == "inspect" && -n ${IROMIHON_NATIVE_MARKER:-} ]]; then
  printf 'delegated\n' >"$IROMIHON_NATIVE_MARKER"
  printf '{"native":true}\n'
  exit 0
fi
exit 2
OMARCHY_WRAPPER

chmod 755 "$TEST_ROOT/fake-bin/git" "$TEST_ROOT/fake-bin/omarchy"
export PATH="$TEST_ROOT/fake-bin:$ORIGINAL_PATH"
export HOME="$TEST_ROOT/home"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_RUNTIME_DIR="$TEST_ROOT/runtime"
export IROMIHON_FORCE_EMBEDDED=1
export IROMIHON_REAL_GIT
export IROMIHON_TEST_APPLIED="$TEST_ROOT/applied"
mkdir -p "$HOME" "$XDG_RUNTIME_DIR"

if "$COMMAND" inspect "$IROMIHON_TEST_ORIGIN" --json >"$TEST_ROOT/rejected.out" 2>"$TEST_ROOT/rejected.err"; then
  fail "non-GitHub repositories are rejected"
fi
[[ ! -s $TEST_ROOT/rejected.out ]] || fail "rejected input emits no partial JSON"
pass "only public GitHub repositories enter the engine"

inspect_json=$("$COMMAND" inspect "$PUBLIC_URL" --json)
source_id=$(jq -er '.source.id' <<<"$inspect_json")
source_path=$(jq -er '.source.path' <<<"$inspect_json")
jq -e '.schemaVersion == 1 and (.themes | length) == 4 and all(.themes[]; .installed == false)' <<<"$inspect_json" >/dev/null
[[ -d $source_path/.git ]] || fail "collection is cloned into the source registry"
[[ ! -e $HOME/.config/omarchy/themes/xerox-riot ]] || fail "inspect does not install a child"
pass "inspect clones once and installs no children"

selection_file="$XDG_STATE_HOME/omarchy/iromihon/selection.json"
empty_restore=$("$COMMAND" restore --json)
jq -e '.schemaVersion == 1 and .selection == null' <<<"$empty_restore" >/dev/null
"$COMMAND" remember "$PUBLIC_URL" xerox-riot
[[ -f $selection_file && ! -L $selection_file ]] || fail "selection is saved as a regular file"
[[ $(stat -c '%a' "$selection_file") == "600" ]] || fail "selection state is not owner-only"
restore_json=$("$COMMAND" restore --json)
jq -e '.selection as $selection | $selection == {url: "https://github.com/RegionallyFamous/omarchy-chaos-themes.git", slug: "xerox-riot"} and any(.themes[]; .slug == $selection.slug)' <<<"$restore_json" >/dev/null
pass "the exact collection child survives a fresh process"

multibyte_padding=$(printf 'é%.0s' {1..128})
boundary_json=$(jq -cn --arg url "$PUBLIC_URL" --arg slug xerox-riot --arg padding "$multibyte_padding" \
  '{schemaVersion: 1, url: $url, slug: $slug, padding: $padding}')
boundary_bytes=$(printf '%s' "$boundary_json" | wc -c)
(( boundary_bytes < 2048 )) || fail "selection boundary fixture is unexpectedly large"
leading_bytes=$((2048 - boundary_bytes))
head -c "$leading_bytes" /dev/zero | tr '\0' ' ' >"$selection_file"
printf '%s' "$boundary_json" >>"$selection_file"
selection_size=$(wc -c <"$selection_file")
(( selection_size == 2048 )) || fail "selection boundary fixture is not exact"
"$COMMAND" restore --json >"$TEST_ROOT/selection-exact.json"
jq -e '.selection.slug == "xerox-riot"' "$TEST_ROOT/selection-exact.json" >/dev/null
printf 'x' >>"$selection_file"
if "$COMMAND" restore --json >"$TEST_ROOT/selection-oversized.out" 2>"$TEST_ROOT/selection-oversized.err"; then
  fail "one byte over the selection ceiling is accepted"
fi
[[ ! -s $TEST_ROOT/selection-oversized.out ]] || fail "an oversized selection emits partial JSON"
pass "selection state enforces its byte ceiling, including multibyte content"

printf '{' >"$selection_file"
if "$COMMAND" restore --json >"$TEST_ROOT/selection-malformed.out" 2>"$TEST_ROOT/selection-malformed.err"; then
  fail "malformed selection state is accepted"
fi
[[ ! -s $TEST_ROOT/selection-malformed.out ]] || fail "malformed selection state emits partial JSON"
"$COMMAND" remember "$PUBLIC_URL" xerox-riot
mv "$selection_file" "$TEST_ROOT/selection-target.json"
ln -s "$TEST_ROOT/selection-target.json" "$selection_file"
if "$COMMAND" restore --json >"$TEST_ROOT/selection-symlink.out" 2>"$TEST_ROOT/selection-symlink.err"; then
  fail "symbolic-link selection state is accepted"
fi
[[ ! -s $TEST_ROOT/selection-symlink.out ]] || fail "symbolic-link selection state emits partial JSON"
"$COMMAND" forget
[[ -f $TEST_ROOT/selection-target.json ]] || fail "forget followed a symbolic-link selection target"
empty_restore=$("$COMMAND" restore --json)
jq -e '.selection == null' <<<"$empty_restore" >/dev/null
pass "malformed state fails closed and explicit forget clears only Iromihon state"

install_json=$("$COMMAND" install "$source_id" cable-rat-king --json)
jq -e '.action == {type: "install", theme: "cable-rat-king", applied: false}' <<<"$install_json" >/dev/null
[[ -L $HOME/.config/omarchy/themes/cable-rat-king ]] || fail "selected child is linked into the native theme directory"
[[ ! -e $HOME/.config/omarchy/themes/xerox-riot ]] || fail "a sibling is not installed implicitly"
pass "install exposes only the selected native child"

"$COMMAND" install "$source_id" xerox-riot --apply --json >"$TEST_ROOT/applied.json"
grep -Fxq xerox-riot "$IROMIHON_TEST_APPLIED" || fail "apply delegates to Omarchy's normal theme setter"
jq -e '.action.applied == true and any(.themes[]; .slug == "xerox-riot" and .installed)' "$TEST_ROOT/applied.json" >/dev/null
pass "install-and-apply uses Omarchy's native activation path"

mkdir -p "$HOME/.config/omarchy/themes/safety-third"
printf 'mine\n' >"$HOME/.config/omarchy/themes/safety-third/owner"
if "$COMMAND" install "$source_id" safety-third --json >"$TEST_ROOT/conflict.out" 2>"$TEST_ROOT/conflict.err"; then
  fail "a user-owned name collision is accepted"
fi
[[ ! -s $TEST_ROOT/conflict.out ]] || fail "a name collision emits partial JSON"
grep -Fxq mine "$HOME/.config/omarchy/themes/safety-third/owner" || fail "a user-owned collision was replaced"
rm -rf "$HOME/.config/omarchy/themes/safety-third"
pass "name collisions fail closed without replacing user themes"

mkdir -p "$IROMIHON_TEST_ORIGIN/themes/new-static"
cp "$IROMIHON_TEST_ORIGIN/themes/xerox-riot/colors.toml" "$IROMIHON_TEST_ORIGIN/themes/new-static/colors.toml"
cp "$IROMIHON_TEST_ORIGIN/themes/xerox-riot/preview.jpg" "$IROMIHON_TEST_ORIGIN/themes/new-static/preview.jpg"
commit_origin "Add uninstalled child"
update_json=$("$COMMAND" update "$source_id" --json)
jq -e '(.themes | length) == 5 and any(.themes[]; .slug == "new-static" and .installed == false)' <<<"$update_json" >/dev/null
[[ ! -e $HOME/.config/omarchy/themes/new-static ]] || fail "new upstream child entered the native selector"
pass "updates keep new upstream children out of the native picker"

palette="$IROMIHON_TEST_ORIGIN/themes/xerox-riot/colors.toml"
palette_bytes=$(stat -c%s "$palette")
padding=$((128 * 1024 - palette_bytes))
head -c "$padding" /dev/zero | tr '\0' '#' >>"$palette"
commit_origin "Reach exact palette ceiling"
"$COMMAND" update "$source_id" --json >"$TEST_ROOT/exact.json"
jq -e '.action.type == "update"' "$TEST_ROOT/exact.json" >/dev/null
stable_commit=$(jq -er '.source.commit' "$TEST_ROOT/exact.json")
pass "the exact palette byte ceiling is accepted"

printf 'x' >>"$palette"
commit_origin "Exceed palette ceiling"
if "$COMMAND" update "$source_id" --json >"$TEST_ROOT/oversized.out" 2>"$TEST_ROOT/oversized.err"; then
  fail "one byte over the palette ceiling is rejected"
fi
[[ ! -s $TEST_ROOT/oversized.out ]] || fail "an oversized update emits no partial JSON"
[[ $(git -C "$source_path" rev-parse HEAD) == "$stable_commit" ]] || fail "a rejected update replaced the installed source"
pass "oversized updates roll back without partial output"

detach_json=$("$COMMAND" detach "$source_id" cable-rat-king --json)
jq -e '.action == {type: "detach", theme: "cable-rat-king"}' <<<"$detach_json" >/dev/null
[[ ! -e $HOME/.config/omarchy/themes/cable-rat-king ]] || fail "detached child remains in the native selector"
[[ -d $source_path/.git ]] || fail "detaching a child removed the shared source"
pass "detach removes one child while retaining the collection"

second_home="$TEST_ROOT/clone-failure-home"
mkdir -p "$second_home"
export HOME="$second_home"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export IROMIHON_TEST_GIT_FAIL=1
if "$COMMAND" inspect "$PUBLIC_URL" --json >"$TEST_ROOT/clone-failure.out" 2>"$TEST_ROOT/clone-failure.err"; then
  fail "clone failure is reported"
fi
[[ ! -s $TEST_ROOT/clone-failure.out ]] || fail "clone failure emits partial JSON"
pass "child-process failure is bounded and produces no partial data"

third_home="$TEST_ROOT/interruption-home"
mkdir -p "$third_home"
export HOME="$third_home"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export IROMIHON_TEST_GIT_FAIL=0
export IROMIHON_TEST_GIT_HANG=1
export IROMIHON_TEST_GIT_CHILD_PID="$TEST_ROOT/hanging-child.pid"
"$COMMAND" inspect "$PUBLIC_URL" --json >"$TEST_ROOT/interrupted.out" 2>"$TEST_ROOT/interrupted.err" &
operation_pid=$!
for (( attempt = 0; attempt < 100; attempt++ )); do
  [[ -s $IROMIHON_TEST_GIT_CHILD_PID ]] && break
  sleep 0.05
done
[[ -s $IROMIHON_TEST_GIT_CHILD_PID ]] || fail "hanging clone child did not start"
clone_child_pid=$(<"$IROMIHON_TEST_GIT_CHILD_PID")
kill -TERM "$operation_pid"
if wait "$operation_pid"; then
  fail "interrupted source operation returned success"
fi
for (( attempt = 0; attempt < 100; attempt++ )); do
  if ! kill -0 "$clone_child_pid" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
if kill -0 "$clone_child_pid" 2>/dev/null; then
  fail "interrupted clone left a descendant running"
fi
[[ ! -s $TEST_ROOT/interrupted.out ]] || fail "interrupted clone emits partial JSON"
pass "caller cancellation tears down the clone process group"

cat >"$TEST_ROOT/fake-bin/omarchy-theme-source-inspect" <<'NATIVE_MARKER'
#!/bin/bash
exit 0
NATIVE_MARKER
chmod 755 "$TEST_ROOT/fake-bin/omarchy-theme-source-inspect"
unset IROMIHON_FORCE_EMBEDDED IROMIHON_TEST_GIT_FAIL IROMIHON_TEST_GIT_HANG
export IROMIHON_NATIVE_MARKER="$TEST_ROOT/native-delegated"
native_json=$("$COMMAND" inspect "$PUBLIC_URL" --json)
jq -e '.native == true' <<<"$native_json" >/dev/null
grep -Fxq delegated "$IROMIHON_NATIVE_MARKER" || fail "future native source command was not preferred"
pass "a compatible future core source command is preferred automatically"

printf 'Iromihon embedded source tests passed\n'
