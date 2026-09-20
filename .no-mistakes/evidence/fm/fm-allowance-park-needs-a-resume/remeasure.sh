. bin/fm-allowance-lib.sh
refused=0 reset=0 mtime_cross=0 stamp_cross=0
for f in ~/.claude/projects/*/*.jsonl; do
  _fm_allowance_record_parked "$f" >/dev/null 2>&1 || continue
  refused=$((refused + 1))
  r=$(_fm_allowance_record_reset "$f" 2>/dev/null) || continue
  reset=$((reset + 1))
  [ "$(_fm_allowance_mtime "$f")" -ge "$r" ] && mtime_cross=$((mtime_cross + 1))
  _fm_allowance_record_superseded "$f" && stamp_cross=$((stamp_cross + 1))
done
echo "last conversational record is the refusal: $refused"
echo "  of those, with a recorded reset:         $reset"
echo "  file mtime at or after that reset:       $mtime_cross"
echo "  newest record timestamp at or after it:  $stamp_cross"
anywhere=0 tail_refusal=0 resumed=0 suppressible=0
now=$(date -u +%s)
for f in ~/.claude/projects/*/*.jsonl; do
  grep -aq '"apiErrorStatus":429' "$f" && anywhere=$((anywhere + 1))
  if _fm_allowance_record_parked "$f" >/dev/null 2>&1; then
    tail_refusal=$((tail_refusal + 1))
  elif over=$(_fm_allowance_record_resumed "$f"); then
    tail_refusal=$((tail_refusal + 1))
    resumed=$((resumed + 1))
    reset=${over%%|*}
    case "$reset" in ''|*[!0-9]*) continue ;; esac
    [ "$reset" -le "$now" ] && _fm_allowance_reset_clock "${over#*|}" >/dev/null && suppressible=$((suppressible + 1))
  fi
done
echo "anywhere=$anywhere tail_refusal=$tail_refusal resumed=$resumed suppressible=$suppressible"
