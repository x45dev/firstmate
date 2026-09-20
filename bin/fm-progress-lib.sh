#!/usr/bin/env bash
# fm-progress-lib.sh - the ONE owner of firstmate's positive movement evidence.
#
# Why this exists: two supervision detectors read the same underlying thing -
# a quiet worker - and infer opposite verdicts from it. The wedge timer reads
# quiet as "possibly hung" and alarms; the semantic busy record reads a turn
# that opened and never closed as "still working" and stays silent. Neither can
# tell which side of the boundary it is on, because absence of signal is not
# evidence in either direction: a live worker on a long silent tool call and a
# worker whose process died both render a still pane and both leave the busy
# marker set.
#
# The discriminating test is positive rather than inferential: sample three
# independent counters TWICE and require MOVEMENT.
#
#   footer   the harness's whole status-line region: its turn timer, spinner,
#            token or context counter, keybind hints - whatever it renders there
#   tokens   the token counter within that region, where its notation is known
#   content  the rendered text OUTSIDE that region
#
# A dead process moves none of the three. A live worker moves the footer, since
# a running harness redraws its own status line, and one making forward progress
# also moves the token counter or the content. That separation is what lets one
# primitive answer both questions from one sample pair:
#
#   advanced  tokens or content moved - forward progress, so not a wedge
#   alive     only the footer moved - the process is running but shows no progress
#   still     none of the three moved - no proof of life at all
#   unknown   no comparable prior sample, so nothing is established yet
#
# `unknown` is deliberately not a verdict in either direction: a caller must
# treat it exactly as it behaved before this library existed, because one
# sample can never answer a question about movement.
#
# Counters are compared, never interpreted: each is a digest, never a parsed
# magnitude, so no locale separator or unit has to be modeled. The liveness
# counter goes further and models NOTHING - it digests the whole footer region
# rather than the timer inside it, because a timer regex that fails to match a
# new adapter's notation reads exactly like a stopped process. Only the progress
# counter knows a notation, and where it fails to match, a live worker degrades
# to `alive` rather than to `still`: the safe direction, since `alive` defers no
# wedge and licenses no claim that a worker is running.
#
# Sample record: state/<id>.progress-sample - exactly one line, replaced whole:
#
#   v1 ts=<epoch> verdict=<v> footer=<digest|-> tokens=<digest|-> content=<digest|->
#
# The verdict is stored beside the counters so the pair is established exactly
# once per poll, by the caller that already holds a capture, and every other
# reader in that poll gets the same answer through the pure fm_progress_verdict
# read. A second observation inside one poll cannot re-anchor the pair: it falls
# under the minimum gap, returns unknown, and leaves the record alone.
#
# bin/fm-teardown.sh removes it with the task's other runtime records.

# The footer region every verified harness renders its turn timer and token
# counter into, in non-blank lines counted from the bottom. The same convention
# bin/fm-watch.sh already uses to keep busy-looking strings in displayed content
# from being read as a busy signature.
FM_PROGRESS_FOOTER_LINES=${FM_PROGRESS_FOOTER_LINES:-6}
case "$FM_PROGRESS_FOOTER_LINES" in ''|*[!0-9]*|0) FM_PROGRESS_FOOTER_LINES=6 ;; esac

# The shortest gap between two samples that can establish stillness. Below it a
# counter that simply had no reason to tick yet would read as a stopped process,
# so the observation returns unknown and KEEPS the older sample as the anchor
# rather than replacing it with one too close to compare against.
FM_PROGRESS_MIN_GAP_SECS=${FM_PROGRESS_MIN_GAP_SECS:-5}
case "$FM_PROGRESS_MIN_GAP_SECS" in ''|*[!0-9]*) FM_PROGRESS_MIN_GAP_SECS=5 ;; esac

# The longest gap across which a prior sample still describes the same quiet
# stretch. Past it the anchor is discarded and re-taken, because a sample from
# an unrelated earlier episode answers nothing about this one.
FM_PROGRESS_MAX_GAP_SECS=${FM_PROGRESS_MAX_GAP_SECS:-1800}
case "$FM_PROGRESS_MAX_GAP_SECS" in ''|*[!0-9]*|0) FM_PROGRESS_MAX_GAP_SECS=1800 ;; esac

fm_progress_sample_path() {  # <state-dir> <id>
  printf '%s/%s.progress-sample' "$1" "$2"
}

fm_progress_sample_clear() {  # <state-dir> <id>
  rm -f "$(fm_progress_sample_path "$1" "$2")"
}

_fm_progress_digest() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

# The footer region of <tail>: its last FM_PROGRESS_FOOTER_LINES non-blank lines.
_fm_progress_footer() {  # <tail>
  printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | tail -n "$FM_PROGRESS_FOOTER_LINES"
}

# Everything ABOVE that footer region: the rendered conversation itself, which
# changes only when the worker actually produced something new.
_fm_progress_body() {  # <tail>
  local total keep
  total=$(printf '%s\n' "$1" | grep -c -v '^[[:space:]]*$' || true)
  case "$total" in ''|*[!0-9]*) total=0 ;; esac
  keep=$(( total - FM_PROGRESS_FOOTER_LINES ))
  [ "$keep" -gt 0 ] || { printf ''; return 0; }
  printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | head -n "$keep"
}

# Digest of every token-counter-looking value in <footer>, or `-` when it
# renders none. Covers the labelled form (12.3k tokens, 1,234 tokens) and the
# arrow form every context-window footer uses (^ 1.2k, v 3.4k).
_fm_progress_tokens_digest() {  # <footer>
  local hits
  hits=$(printf '%s\n' "$1" \
    | grep -oE '[0-9][0-9.,]*[[:space:]]*[kKmM]?[[:space:]]*[Tt]okens?|[↑↓⇡⇣][^0-9]{0,4}[0-9][0-9.,]*[[:space:]]*[kKmM]?' \
    | tr -d '[:space:]' || true)
  [ -n "$hits" ] || { printf '%s' -; return 0; }
  printf '%s' "$hits" | _fm_progress_digest
}

# The three counters of one capture, as `<footer>\t<tokens>\t<content>`.
# A counter the harness does not render is `-`, which compares equal to a later
# `-` and so contributes no movement either way.
fm_progress_counters() {  # <tail>
  local tail=$1 footer body content footer_digest
  footer=$(_fm_progress_footer "$tail")
  body=$(_fm_progress_body "$tail")
  if [ -n "$body" ]; then content=$(printf '%s' "$body" | _fm_progress_digest); else content=-; fi
  if [ -n "$footer" ]; then footer_digest=$(printf '%s' "$footer" | _fm_progress_digest); else footer_digest=-; fi
  printf '%s\t%s\t%s' \
    "$footer_digest" \
    "$(_fm_progress_tokens_digest "$footer")" \
    "$content"
}

_fm_progress_field() {  # <record> <key>
  local rest=${1#*" $2="}
  [ "$rest" != "$1" ] || { printf ''; return 1; }
  printf '%s' "${rest%% *}"
}

_fm_progress_write() {  # <path> <epoch> <verdict> <counters>
  local path=$1 now=$2 verdict=$3 counters=$4 footer tokens content tmp
  footer=${counters%%$'\t'*}
  content=${counters##*$'\t'}
  tokens=${counters#*$'\t'}; tokens=${tokens%%$'\t'*}
  tmp="$path.tmp.$$"
  printf 'v1 ts=%s verdict=%s footer=%s tokens=%s content=%s\n' \
    "$now" "$verdict" "$footer" "$tokens" "$content" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# The verdict the last completed observation recorded, without sampling: a pure
# read for every consumer in a poll other than the one that took the sample.
# Always one of the four verdicts, so an absent, malformed, or pre-verdict
# record reads unknown and licenses nothing.
fm_progress_verdict() {  # <state-dir> <id>
  local record stored
  record=$(cat "$(fm_progress_sample_path "$1" "$2")" 2>/dev/null || true)
  case "$record" in 'v1 ts='*) ;; *) printf 'unknown'; return 0 ;; esac
  stored=$(_fm_progress_field "$record" verdict) || stored=''
  case "$stored" in
    advanced|alive|still) printf '%s' "$stored" ;;
    *) printf 'unknown' ;;
  esac
}

# Observe <id>'s three counters against its previous sample and record the new
# one. Prints exactly one of advanced, alive, still, or unknown; see the header
# for what each licenses. Cheap: it reads and replaces one small file and runs
# no backend, no worktree walk, and no pipeline call, so a caller already
# holding a pane capture pays nothing beyond it.
fm_progress_observe() {  # <state-dir> <id> <tail>
  local state=$1 id=$2 tail=$3 path record now ts gap counters verdict
  local prev_footer prev_tokens prev_content footer tokens content
  [ -n "$id" ] || { printf 'unknown'; return 0; }
  path=$(fm_progress_sample_path "$state" "$id")
  now=$(date +%s)
  counters=$(fm_progress_counters "$tail")
  footer=${counters%%$'\t'*}
  content=${counters##*$'\t'}
  tokens=${counters#*$'\t'}; tokens=${tokens%%$'\t'*}

  record=$(cat "$path" 2>/dev/null || true)
  case "$record" in
    'v1 ts='*) ts=$(_fm_progress_field "$record" ts) || ts='' ;;
    *) ts='' ;;
  esac
  case "$ts" in ''|*[!0-9]*) _fm_progress_write "$path" "$now" unknown "$counters" || true; printf 'unknown'; return 0 ;; esac
  gap=$(( now - ts ))
  if [ "$gap" -lt "$FM_PROGRESS_MIN_GAP_SECS" ]; then
    # Too close to compare. Keep the older anchor, and the verdict it already
    # established, so the NEXT observation has a usable gap rather than
    # restarting the pair on every poll.
    printf 'unknown'
    return 0
  fi
  if [ "$gap" -gt "$FM_PROGRESS_MAX_GAP_SECS" ]; then
    _fm_progress_write "$path" "$now" unknown "$counters" || true
    printf 'unknown'
    return 0
  fi
  prev_footer=$(_fm_progress_field "$record" footer) || prev_footer=''
  prev_tokens=$(_fm_progress_field "$record" tokens) || prev_tokens=''
  prev_content=$(_fm_progress_field "$record" content) || prev_content=''
  if [ -z "$prev_footer" ] || [ -z "$prev_tokens" ] || [ -z "$prev_content" ]; then
    _fm_progress_write "$path" "$now" unknown "$counters" || true
    printf 'unknown'
    return 0
  fi
  if [ "$tokens" != "$prev_tokens" ] || [ "$content" != "$prev_content" ]; then
    verdict=advanced
  elif [ "$footer" != "$prev_footer" ]; then
    verdict=alive
  elif [ "$footer$tokens$content" = '---' ] && [ "$prev_footer$prev_tokens$prev_content" = '---' ]; then
    # Neither capture rendered a single counter, so nothing was measured and
    # nothing moving is not evidence. Stillness has to be observed, never
    # inferred from an unreadable surface.
    verdict=unknown
  else
    verdict=still
  fi
  _fm_progress_write "$path" "$now" "$verdict" "$counters" || true
  printf '%s' "$verdict"
}
