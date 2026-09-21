#!/usr/bin/env bash
. "$1/bin/fm-allowance-lib.sh"
tot=0; falsepos=0
for dir in "$HOME"/.claude/projects/*/; do
  newest=""
  for f in "$dir"*.jsonl; do [ -f "$f" ] || continue; if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then newest=$f; fi; done
  [ -n "$newest" ] || continue
  grep -aq '"apiErrorStatus":429' "$newest" || continue
  cwd=$(grep -aom1 '"cwd":"[^"]*"' "$newest" | sed 's/^"cwd":"//; s/"$//'); [ -n "$cwd" ] || continue
  gt=$(tail -n 400 "$newest" | jq -rc 'select(.type=="user" or .type=="assistant") | [.type,(.isApiErrorMessage//false),(.apiErrorStatus//0)]' 2>/dev/null | tail -1)
  case "$gt" in *'"assistant",true,429'*) continue ;; esac
  tot=$((tot+1))
  if fm_allowance_record_parked claude "$cwd" >/dev/null 2>&1; then falsepos=$((falsepos+1)); echo "FALSE-PARK $newest"; fi
done
echo "transcripts-with-resolved-429-in-history=$tot false-parks=$falsepos"
