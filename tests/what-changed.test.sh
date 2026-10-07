#!/usr/bin/env bash
# Runs bin/what-changed over a fixture pacman log, a fake ~/.config and a fake
# plugin reflog, and checks the merged timeline. Needs jq.
#
#   tests/what-changed.test.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
bin=$here/../bin/what-changed
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0

check() {
  if [[ $2 == "$3" ]]; then
    echo "PASS  $1"
    pass=$((pass + 1))
  else
    printf 'FAIL  %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"
    fail=$((fail + 1))
  fi
}

# Fake config tree: one real edit, noise that must be skipped, one old file.
cfg=$tmp/config
mkdir -p "$cfg/hypr" "$cfg/Code/User" "$cfg/foo/Cache" "$cfg/SomeElectronApp" "$cfg/omarchy/plugins/acme.demo/.git/logs"
echo x >"$cfg/hypr/bindings.lua"
echo x >"$cfg/Code/User/settings.json"
echo x >"$cfg/foo/Cache/blob"
echo x >"$cfg/foo/app-state"
echo x >"$cfg/SomeElectronApp/Cookies"
echo x >"$cfg/SomeElectronApp/Preferences"
echo x >"$cfg/old.conf"
touch -d '2026-09-01 10:00' "$cfg/old.conf"
touch -d '2026-10-05 12:00' "$cfg/hypr/bindings.lua"
z=0000000000000000000000000000000000000000
a=1111111111111111111111111111111111111111
printf '%s %s Someone <s@example.invalid> 1791100000 +0200\tclone: from https://example.invalid/demo.git\n' "$z" "$a" >"$cfg/omarchy/plugins/acme.demo/.git/logs/HEAD"
printf '%s %s Someone <s@example.invalid> 1700000000 +0200\tclone: from https://example.invalid/demo.git\n' "$z" "$a" >>"$cfg/omarchy/plugins/acme.demo/.git/logs/HEAD"

since=$(date -d '2026-09-30T00:00:00+0200' +%s)
out=$(WHAT_CHANGED_PACMAN_LOG=$here/fixture-pacman.log WHAT_CHANGED_CONFIG_DIR=$cfg OMARCHY_PATH=/usr/share/omarchy \
  "$bin" --since "$since" --json)

jq -e . >/dev/null <<<"$out" || {
  echo "FAIL  output is not JSON"
  echo "$out"
  exit 1
}

pkg() { jq -c "[.[] | select(.kind == \"package\")] | sort_by(.ts) | .[$1] | $2" <<<"$out"; }

check "packages: transactions inside the window only" "$(jq '[.[] | select(.kind == "package")] | length' <<<"$out")" 7
check "upgrade transaction keeps its command" "$(pkg 0 .command)" '"pacman -Syu"'
check "upgrade summary counts" "$(pkg 0 .summary)" '"2 upgraded, 1 installed"'
check "upgrade old -> new" "$(pkg 0 '.items[0]')" '{"op":"upgraded","name":"linux","from":"6.16.1-1","to":"6.16.2-1"}'
check "install has no from" "$(pkg 0 '.items[2]')" '{"op":"installed","name":"new-dep","from":"","to":"2.0-1"}'
check "remove" "$(pkg 1 '[.summary, .items[0].op, .items[0].to]')" '["1 removed","removed","0.9-3"]'
check "downgrade" "$(pkg 2 '[.summary, .items[0].from, .items[0].to]')" '["1 downgraded","25.0.2-1","25.0.1-1"]'
check "transaction cut off by a new one is interrupted" "$(pkg 3 '[.status, .summary, .command]')" '["interrupted","1 upgraded (interrupted)","pacman -Syu"]'
check "quotes and backslashes in the command survive" "$(pkg 4 '[.status, .command]')" '["completed","pacman -S rescue \"quoted\\pkg\""]'
check "failed transaction is interrupted" "$(pkg 5 '[.status, .summary]')" '["interrupted","no packages changed (interrupted)"]'
check "log ending mid-transaction is unfinished" "$(pkg 6 '[.status, .command, .items[0].op]')" '["unfinished","","reinstalled"]'
check "UTC offsets are applied" "$(pkg 5 .ts)" "$(date -d '2026-10-05T07:00:01+0000' +%s)"
check "omarchy upgrade becomes its own entry" "$(jq -c '[.[] | select(.kind == "omarchy") | .summary]' <<<"$out")" '["Omarchy 3.1.0-1 -> 3.2.0-1"]'
check "config: only the real edit" "$(jq -c '[.[] | select(.kind == "config") | .summary]' <<<"$out")" '["hypr/bindings.lua"]'
check "config entry carries the full path" "$(jq -r '.[] | select(.kind == "config") | .path' <<<"$out")" "$cfg/hypr/bindings.lua"
check "plugin clone inside the window is an install" "$(jq -c '[.[] | select(.kind == "plugin") | .summary]' <<<"$out")" '["acme.demo installed"]'
check "newest first" "$(jq '[.[].ts] == ([.[].ts] | sort | reverse)' <<<"$out")" true

empty=$(WHAT_CHANGED_PACMAN_LOG=/nonexistent WHAT_CHANGED_CONFIG_DIR=$tmp/none "$bin" --days 1 --json)
check "missing sources give an empty list" "$empty" "[]"

echo "$pass passed, $fail failed"
((fail == 0))
