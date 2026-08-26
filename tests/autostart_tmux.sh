#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d /tmp/olwb-autostart.XXXXXX)
session="olwb-autostart-$$"
micro_bin=${MICRO_BIN:-micro}

cleanup() {
  tmux kill-session -t "$session" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/config/plug" "$tmp/data"
ln -s "$root" "$tmp/config/plug/olwb"
touch "$tmp/NOTES.md"

run_case() {
  local target=${1:-}
  local command="env XDG_DATA_HOME='$tmp/data' OLWB_AUTOSTART=1 '$micro_bin' -config-dir '$tmp/config'"
  if [[ -n "$target" ]]; then command="$command '$target'"; fi
  tmux new-session -d -s "$session" -x 90 -y 30 "$command"

  local pane=""
  for _ in {1..30}; do
    pane=$(tmux capture-pane -t "$session" -p)
    if grep -q "olwb — one line with benefits" <<<"$pane"; then break; fi
    sleep 0.1
  done
  grep -q "olwb — one line with benefits" <<<"$pane"
  grep -q "Liner:" <<<"$pane"
  tmux kill-session -t "$session"
}

run_case
run_case "$tmp/NOTES.md"
echo "autostart tmux: no-file and file launch passed"
