#!/usr/bin/env bash
# For each real claude project dir whose newest transcript ends in a 429 refusal,
# compare the library verdict with an independent jq ground truth.
. "$1/bin/fm-allowance-lib.sh"
. "$1/bin/fm-allowance-resume-lib.sh" 2>/dev/null
now=$(date -u +%s)
tot=0; parked=0; cleared=0; mism=0
for dir in "$HOME"/.claude/projects/*/; do
  newest=""
  for f in "$dir"*.jsonl; do [ -f "$f" ] || continue; if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then newest=$f; fi; done
  [ -n "$newest" ] || continue
  cwd=$(grep -aom1 '"cwd":"[^"]*"' "$newest" | sed 's/^"cwd":"//; s/"$//')
  [ -n "$cwd" ] || continue
  # ground truth: last user/assistant record
  gt=$(tail -n 400 "$newest" | jq -rc 'select(.type=="user" or .type=="assistant") | [.type, (.isApiErrorMessage//false), (.apiErrorStatus//0), (.quotaLimits.resetsAt//0), (.timestamp//"")]' 2>/dev/null | tail -1)
  case "$gt" in *'"assistant",true,429'*) ;; *) continue ;; esac
  tot=$((tot+1))
  reset=$(printf '%s' "$gt" | jq -r '.[3]')
  # newest timestamped record after reset?
  lastts=$(tail -n 400 "$newest" | jq -r 'select(.timestamp!=null) | .timestamp' 2>/dev/null | tail -1)
  lastep=$(date -u -d "$lastts" +%s 2>/dev/null || echo 0)
  if [ "$reset" -gt 0 ] && [ "$lastep" -ge "$reset" ]; then expect=cleared; else expect=parked; fi
  if fm_allowance_record_parked claude "$cwd" >/dev/null 2>&1; then got=parked; else got=cleared; fi
  [ "$got" = parked ] && parked=$((parked+1)) || cleared=$((cleared+1))
  if [ "$got" != "$expect" ]; then mism=$((mism+1)); echo "MISMATCH $cwd expect=$expect got=$got reset=$reset lastts=$lastts"; fi
done
echo "real-transcripts-ending-in-429=$tot lib-parked=$parked lib-cleared=$cleared mismatches-vs-jq=$mism"
