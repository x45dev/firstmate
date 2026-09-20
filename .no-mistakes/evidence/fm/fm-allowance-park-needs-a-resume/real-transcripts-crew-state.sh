#!/usr/bin/env bash
# Drives bin/fm-crew-state.sh (real script) against REAL Claude Code transcripts in ~/.claude/projects (read-only).
cd /home/dev/.no-mistakes/worktrees/5480956096ee/01M2Z9JJ7RGWR2C8YJ0HVJ6Z8H
. bin/fm-allowance-lib.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
run() { # file id
  local f=$1 cwd id=$2
  cwd=$(grep -ao '"cwd":"[^"]*"' "$f" | tail -1 | sed 's/"cwd":"//; s/"$//')
  [ -n "$cwd" ] || { echo "no cwd for $f"; return; }
  # The library reads the NEWEST transcript of the worktree's project dir, so give it a dir holding only this one (hard link keeps mtime).
  rm -rf "$T/store"; mkdir -p "$T/state" "$T/store/projects/$(basename "$(dirname "$f")")"
  cp -p "$f" "$T/store/projects/$(basename "$(dirname "$f")")/"
  printf 'window=test:fm-%s\nkind=ship\nharness=claude\nworktree=%s\n' "$id" "$cwd" > "$T/state/$id.meta"
  # a live tmux pane stands in for the worker's endpoint so the reader does not stop at "backend target gone"
  tmux kill-session -t "fm-$id" 2>/dev/null; tmux new-session -d -s "fm-$id" -c /tmp "printf 'idle prompt\\n'; sleep 600"
  sed -i "s|^window=.*|window=fm-$id:0|" "$T/state/$id.meta"
  echo "-- $id ($f)"
  echo "   lib parked?: $(_fm_allowance_record_parked "$f" >/dev/null 2>&1 && echo yes || echo no)  resumed?: $(_fm_allowance_record_resumed "$f" >/dev/null 2>&1 && echo yes || echo no) superseded?: $(_fm_allowance_record_superseded "$f" && echo yes || echo no)  mtime>=reset?: $( r=$(_fm_allowance_record_reset "$f" 2>/dev/null) && [ "$(_fm_allowance_mtime "$f")" -ge "$r" ] && echo yes || echo no)"
  echo "   crew-state: $(CLAUDE_CONFIG_DIR="$T/store" FM_STATE_OVERRIDE="$T/state" timeout 60 bin/fm-crew-state.sh "$id" 2>&1 | head -3)"
  tmux kill-session -t "fm-$id" 2>/dev/null
}
n=0; m=0
for f in ~/.claude/projects/*/*.jsonl; do
  if _fm_allowance_record_parked "$f" >/dev/null 2>&1; then
    r=$(_fm_allowance_record_reset "$f" 2>/dev/null) || continue
    if [ "$(_fm_allowance_mtime "$f")" -ge "$r" ] && [ $n -lt 2 ]; then n=$((n+1)); run "$f" "mtimecross$n"; fi
  elif _fm_allowance_record_resumed "$f" >/dev/null 2>&1 && [ $m -lt 2 ]; then m=$((m+1)); run "$f" "resolved$m"; fi
done
