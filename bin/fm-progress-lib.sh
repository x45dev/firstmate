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
#   content  a rendered line OUTSIDE that region that the previous capture did
#            not hold anywhere
#
# A dead process moves none of the three. A live worker moves the footer, since
# a running harness redraws its own status line, and one making forward progress
# also moves the token counter. That separation is what lets one primitive
# answer both questions from one sample pair:
#
#   advanced  the token counter moved while rendered in both samples - forward
#             progress, so not a wedge
#   alive     the footer or a new body line moved - the process is running but
#             shows no measured progress
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
# Only the token counter reads as progress, and content never does. On claude
# 2.1.278 a hung foreground command's body moves on most polls - the running
# tool's header bullet blinks and its timer changes shape at each minute - while
# its token count stays static, so body content cannot tell a hung call from
# progress. A counter that appears or disappears between samples is not progress
# either: a turn starting or ending must not latch an advance. Content movement
# still proves the process is alive, which is why it reads `alive`.
#
# The content counter is a set comparison and not a digest of the body. The
# footer is a fixed count of lines from the bottom, so a line that appears or
# expires inside it slides every line above it across the boundary, and a digest
# of "everything above the footer" then changes though no rendered text moved. A
# line that merely changed side is not new output; only a body line that appeared
# nowhere in the previous capture, footer included, is. That models no harness's
# notation, and it is why the record carries one short digest per line of the
# previous capture rather than one digest of the whole.
#
# Sample record: state/<id>.progress-sample - exactly one line, replaced whole:
#
#   v1 ts=<epoch> verdict=<v> footer=<digest|-> tokens=<digest|-> lines=<digest.digest...> advanced_ts=<epoch|->
#
# A record written without the lines field has no comparable prior, so it reads
# unknown and is replaced; it can never read advanced.
#
# advanced_ts is the last time the pair read `advanced`, carried forward across
# every later observation that did not. It exists because the wedge question is
# asked about a whole quiet window while one observation only ever describes the
# gap between two polls: a worker rendering more slowly than the poll interval
# reads `alive` on most individual pairs and `advanced` on a few, and reading
# only the last pair turns that steady progress into a coin flip. A record
# written before this field existed carries none, which reads as no advance on
# record and defers nothing - the safe direction.
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

# The longest a measured advance keeps answering the wedge question after the
# movement itself stops. A wedge is asked about one quiet window, so the answer
# may not outlive that window: past this bound an advance is history rather than
# evidence, and a pane that moved once and then froze escalates like any other.
# It matches bin/fm-watch.sh's STALE_ESCALATE_SECS by default for exactly that
# reason - the latch covers the window being judged and not one second more.
# Zero disables the latch, leaving only the immediately preceding sample pair,
# which is the behaviour every caller had before the latch existed.
FM_PROGRESS_LATCH_MAX_SECS=${FM_PROGRESS_LATCH_MAX_SECS:-240}
case "$FM_PROGRESS_LATCH_MAX_SECS" in ''|*[!0-9]*) FM_PROGRESS_LATCH_MAX_SECS=240 ;; esac

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

# One digest per non-blank line of <tail>, top to bottom and dot-joined, or `-`
# when there is none. Trailing whitespace is not part of a line, so a redraw that
# only re-pads a row moves nothing. Byte-wise (C locale) so every awk hashes the
# same text the same way.
_fm_progress_line_digests() {  # <tail>
  printf '%s\n' "$1" | LC_ALL=C awk '
    BEGIN { for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i }
    /[^[:space:]]/ {
      sub(/[[:space:]]+$/, "")
      h = 5381
      n = length($0)
      for (i = 1; i <= n; i++) h = (h * 33 + ord[substr($0, i, 1)]) % 4294967296
      out = out (out == "" ? "" : ".") sprintf("%08x", h)
    }
    END { print (out == "" ? "-" : out) }'
}

# 0 iff the body of the capture whose line digests are <lines> - every line above
# the footer region - holds a line that appears nowhere in <prev-lines>.
_fm_progress_new_body_line() {  # <lines> <prev-lines>
  local -a all
  local keep i=0
  [ "$1" != - ] || return 1
  IFS=. read -r -a all <<< "$1"
  keep=$(( ${#all[@]} - FM_PROGRESS_FOOTER_LINES ))
  while [ "$i" -lt "$keep" ]; do
    case ".$2." in *".${all[$i]}."*) ;; *) return 0 ;; esac
    i=$(( i + 1 ))
  done
  return 1
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

# The three counters of one capture, as `<footer>\t<tokens>\t<lines>`, where the
# third is the line digests the NEXT observation compares its body against.
# A counter the harness does not render is `-`, which compares equal to a later
# `-` and so contributes no movement either way.
fm_progress_counters() {  # <tail>
  local tail=$1 footer footer_digest
  footer=$(_fm_progress_footer "$tail")
  if [ -n "$footer" ]; then footer_digest=$(printf '%s' "$footer" | _fm_progress_digest); else footer_digest=-; fi
  printf '%s\t%s\t%s' \
    "$footer_digest" \
    "$(_fm_progress_tokens_digest "$footer")" \
    "$(_fm_progress_line_digests "$tail")"
}

_fm_progress_field() {  # <record> <key>
  local rest=${1#*" $2="}
  [ "$rest" != "$1" ] || { printf ''; return 1; }
  printf '%s' "${rest%% *}"
}

_fm_progress_write() {  # <path> <epoch> <verdict> <counters> <advanced-ts|->
  local path=$1 now=$2 verdict=$3 counters=$4 advanced=${5:--} footer tokens lines tmp
  footer=${counters%%$'\t'*}
  lines=${counters##*$'\t'}
  tokens=${counters#*$'\t'}; tokens=${tokens%%$'\t'*}
  tmp="$path.tmp.$$"
  printf 'v1 ts=%s verdict=%s footer=%s tokens=%s lines=%s advanced_ts=%s\n' \
    "$now" "$verdict" "$footer" "$tokens" "$lines" "$advanced" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# The epoch of the last measured advance on record, or `-` when there is none.
# Reads as `-` for a record written before the field existed, which is what
# makes the latch add deferral only where an advance was actually observed.
_fm_progress_advanced_ts() {  # <record>
  local stored
  case "$1" in 'v1 ts='*) ;; *) printf '%s' -; return 0 ;; esac
  stored=$(_fm_progress_field "$1" advanced_ts) || stored=''
  case "$stored" in ''|*[!0-9]*) printf '%s' - ;; *) printf '%s' "$stored" ;; esac
}

# The verdict the last completed observation recorded, without sampling: a pure
# read for every consumer in a poll other than the one that took the sample.
# Always one of the four verdicts, so an absent, malformed, pre-verdict, or
# stale record reads unknown and licenses nothing. A record older than the
# maximum gap describes an unrelated episode, the same rule observation applies
# to its own anchor, and a task the watcher no longer samples leaves its last
# verdict on disk indefinitely.
fm_progress_verdict() {  # <state-dir> <id>
  local record stored ts
  record=$(cat "$(fm_progress_sample_path "$1" "$2")" 2>/dev/null || true)
  case "$record" in 'v1 ts='*) ;; *) printf 'unknown'; return 0 ;; esac
  ts=$(_fm_progress_field "$record" ts) || ts=''
  case "$ts" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  [ $(( $(date +%s) - ts )) -le "$FM_PROGRESS_MAX_GAP_SECS" ] || { printf 'unknown'; return 0; }
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
  local state=$1 id=$2 tail=$3 path record now ts gap counters verdict advanced
  local prev_footer prev_tokens prev_lines footer tokens lines
  [ -n "$id" ] || { printf 'unknown'; return 0; }
  # A capture with nothing on it is no observation: a transient blank (a redraw,
  # a pane mid-teardown) must neither read as movement nor become the anchor the
  # next real capture is compared against.
  printf '%s\n' "$tail" | grep -q '[^[:space:]]' || { printf 'unknown'; return 0; }
  path=$(fm_progress_sample_path "$state" "$id")
  now=$(date +%s)
  counters=$(fm_progress_counters "$tail")
  footer=${counters%%$'\t'*}
  lines=${counters##*$'\t'}
  tokens=${counters#*$'\t'}; tokens=${tokens%%$'\t'*}

  record=$(cat "$path" 2>/dev/null || true)
  # Carried forward through every write below, so a stretch of `alive` polls
  # between two advances does not erase the advance that came before them.
  advanced=$(_fm_progress_advanced_ts "$record")
  case "$record" in
    'v1 ts='*) ts=$(_fm_progress_field "$record" ts) || ts='' ;;
    *) ts='' ;;
  esac
  case "$ts" in ''|*[!0-9]*) _fm_progress_write "$path" "$now" unknown "$counters" "$advanced" || true; printf 'unknown'; return 0 ;; esac
  gap=$(( now - ts ))
  if [ "$gap" -lt "$FM_PROGRESS_MIN_GAP_SECS" ]; then
    # Too close to compare. Keep the older anchor, and the verdict it already
    # established, so the NEXT observation has a usable gap rather than
    # restarting the pair on every poll.
    printf 'unknown'
    return 0
  fi
  if [ "$gap" -gt "$FM_PROGRESS_MAX_GAP_SECS" ]; then
    _fm_progress_write "$path" "$now" unknown "$counters" "$advanced" || true
    printf 'unknown'
    return 0
  fi
  prev_footer=$(_fm_progress_field "$record" footer) || prev_footer=''
  prev_tokens=$(_fm_progress_field "$record" tokens) || prev_tokens=''
  prev_lines=$(_fm_progress_field "$record" lines) || prev_lines=''
  if [ -z "$prev_footer" ] || [ -z "$prev_tokens" ] || [ -z "$prev_lines" ]; then
    _fm_progress_write "$path" "$now" unknown "$counters" "$advanced" || true
    printf 'unknown'
    return 0
  fi
  if [ "$tokens" != - ] && [ "$prev_tokens" != - ] && [ "$tokens" != "$prev_tokens" ]; then
    verdict=advanced
  elif [ "$footer" != "$prev_footer" ] || _fm_progress_new_body_line "$lines" "$prev_lines"; then
    verdict=alive
  else
    verdict=still
  fi
  [ "$verdict" != advanced ] || advanced=$now
  _fm_progress_write "$path" "$now" "$verdict" "$counters" "$advanced" || true
  printf '%s' "$verdict"
}

# Seconds since the last measured advance, or `-` when none is on record. A
# pure read, like fm_progress_verdict: it establishes nothing and samples
# nothing, so every consumer in a poll gets the answer the sampling caller
# already recorded.
fm_progress_advanced_age() {  # <state-dir> <id>
  local record stamp
  record=$(cat "$(fm_progress_sample_path "$1" "$2")" 2>/dev/null || true)
  stamp=$(_fm_progress_advanced_ts "$record")
  [ "$stamp" != - ] || { printf '%s' -; return 0; }
  printf '%s' "$(( $(date +%s) - stamp ))"
}

# 0 iff a measured advance is recent enough to still answer the wedge question
# for the window being judged - the latched form of the `advanced` verdict, and
# the one a wedge caller wants. Asking for the verdict of the last sample pair
# alone answers a different and much narrower question: whether the worker
# happened to render something in the final poll interval before the threshold.
# A worker advancing on a cadence slower than the poll reads `alive` on most
# pairs, so that narrower question turns steady measurable progress into a coin
# flip, while this one stays true across the window and goes false a bounded
# time after the movement actually stops.
fm_progress_advancing() {  # <state-dir> <id>
  local age
  [ "$FM_PROGRESS_LATCH_MAX_SECS" -gt 0 ] 2>/dev/null || {
    [ "$(fm_progress_verdict "$1" "$2")" = advanced ]
    return
  }
  age=$(fm_progress_advanced_age "$1" "$2")
  [ "$age" != - ] || return 1
  [ "$age" -le "$FM_PROGRESS_LATCH_MAX_SECS" ]
}
