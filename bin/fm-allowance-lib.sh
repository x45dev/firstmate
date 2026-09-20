# shellcheck shell=bash
# fm-allowance-lib.sh - the ONE owner of allowance-park detection.
#
# The condition: a worker whose harness refused the turn because the ACCOUNT ran
# out of provider allowance, printed its own "you've hit your limit, come back
# after the reset" notice, and is now sitting at an idle prompt waiting for a
# keystroke. The process is alive, the endpoint is alive, and the pane renders
# normally, so every liveness probe firstmate owns reads healthy. The 2026-08-17
# incident is the cost of that gap: two crewmates parked seconds after launch,
# their reset passed at 08:30, and nothing resumed or surfaced them until an
# unrelated wedge timer happened to fire on one of the two panes hours later.
#
# This is deliberately NOT part of the semantic busy-state contract in
# bin/fm-busy-lib.sh, and it must not be folded into it. That contract answers
# "is this worker mid-turn", it forbids rendered text as a state source, and it
# resolves every ambiguity to unknown-never-idle so a rendered string can never
# SUPPRESS stale detection. This library answers a different question - "did the
# harness itself say it stopped, and why" - and it can only ever ADD a wake or
# name a cause. A false negative here costs what the incident cost; a false
# positive costs one labelled notification. The two failure modes are not
# symmetric, which is why the two contracts stay separate and why this one is
# allowed to read rendered output at all.
#
# Two independent signals, either of which alone carries a positive verdict, so
# no single vendor string is load-bearing (the harness-dependent-check rule in
# .agents/skills/firstmate-coding-guidelines):
#
#   session-record  The harness's own durable session transcript records the
#                   refusal in machine-readable fields the UI does not control.
#                   Structural, and the preferred signal.
#   pane            The rendered notice, matched against a per-harness signature
#                   in the tail of the captured pane. The fallback, for a worker
#                   whose transcript firstmate cannot locate (a relocated store,
#                   a remote endpoint) or a harness that reworded its records.
#
# Per-harness support is a gate, not a default: an adapter with no verified
# signature reports "not parked" and firstmate's behaviour for it is exactly what
# it was before this library existed. Adding one means observing a REAL refusal
# from that harness and recording the evidence in docs/verification/supervision.md,
# the same discipline the standalone-Kimi busy gate follows. Guessing a signature
# would buy a false wedge alarm, which is the one thing this must not add.
#
# The refusal record also carries the reset it is waiting on, as an absolute
# epoch second, and that is what a park episode is identified and bounded by. The
# notice text recurs byte for byte every window ("resets 8:30am (UTC)"), so it
# cannot tell this park from the next; the reset instant can, and
# fm_allowance_record_reset_epoch is where every caller reads it. The verdict is
# bounded in time by the same field: a refusal record is evidence about the moment
# it was written, and without a bound it went on asserting "parked" long after the
# worker had been resumed, which is what left bin/fm-crew-state.sh reporting a
# visibly working worker as parked. So the structural arm stops claiming anything
# once the newest record in the transcript that carries its own timestamp is at or
# after that recorded reset.
#
# The bound reads record timestamps and not the file's mtime, because the file is
# written for reasons other than a turn: session metadata (last-prompt, cost-state,
# file-history-snapshot, bridge-session) is appended with no timestamp, and a
# measured share of refusal-terminated transcripts were touched after their own
# reset by writes of that kind (docs/verification/supervision.md holds the count
# and the command). One live park (Claude Code 2.1.278, 2026-09-20) took none of
# them across its reset, but that is one park, so nothing here relies on a parked
# worker's file staying still.
#
# The two arms are not equals about a refusal the transcript says is over. A
# refusal in its tail that has been superseded, or that later conversation
# followed, is an episode the worker already left, and the pane may not reassert
# THAT episode: a notice still rendered near the prompt after a resume is
# scrollback. What the pane may not do is claim a park the transcript has already
# ruled out; it may still report a different one. So the pane is suppressed only
# when both hold - the over refusal's own recorded reset is already past, and the
# reset clock in the pane's newest notice is the same clock that refusal named.
# Either failing leaves the pane free to speak, because the cost of that is one
# labelled notification and the cost of the opposite is a worker that parked again
# through the pane-only affordance the transcript never records and sits stopped.
# "Either signal alone carries a positive verdict" therefore excludes exactly one
# thing: a pane notice the transcript's own over refusal accounts for. A refusal
# with no recorded reset (Claude Code 2.1.226 and 2.1.227) can never be shown
# over, so its pane notice is not suppressed. docs/verification/supervision.md
# holds the measurement that separates this from suppressing the pane whenever a
# resolved refusal is in view.
#
# Callers: bin/fm-watch.sh (surfaces the park as a named wake instead of letting
# it wait out a wedge timer, and resumes it through bin/fm-allowance-resume-lib.sh
# once the reset has passed) and bin/fm-crew-state.sh (reports it as the crew's
# current state, so recovery reads the cause rather than "harness busy").
#
# Sourcing: set -u and set -e safe.

# How many non-blank rendered lines from the END of a pane capture may carry the
# notice. Bounded to the region a harness redraws around its own prompt, so a
# limit message quoted in displayed CONTENT - a file being read, a grep result,
# this very file - scrolls out of scope instead of matching. The watcher adds the
# stronger guard: the pane arm runs only on a pane that has already been
# byte-identical across consecutive polls.
FM_ALLOWANCE_PANE_TAIL_LINES=${FM_ALLOWANCE_PANE_TAIL_LINES:-15}

# How many trailing session-record lines the transcript read folds. The refusal is
# the last conversational record by construction (the turn ended on it), so this
# only has to clear the handful of non-conversational records a harness appends
# afterwards. Bounded so a long-running crew's transcript costs a fixed read
# rather than one that grows with the session.
FM_ALLOWANCE_RECORD_TAIL_LINES=${FM_ALLOWANCE_RECORD_TAIL_LINES:-200}

# fm_allowance_harness_verified: 0 when <harness> has a signature verified against
# a real refusal. Everything else is unsupported and never parks.
fm_allowance_harness_verified() {  # <harness>
  case "${1:-}" in
    claude*) return 0 ;;
    *) return 1 ;;
  esac
}

# fm_allowance_pane_signature: the verified rendered signature for <harness>, as
# one extended regular expression.
#
# claude: the limit word is a class rather than a literal because both quota
# windows render the same shape ("You've hit your session limit" and "You've hit
# your weekly limit"), with an optional trailing " · progress saved". The
# apostrophe is matched as any single character because a terminal may render it
# as ASCII ' or as a typographic quote depending on font and locale, and the
# separator is deliberately not matched at all for the same reason. The alternate
# arm is the pane-only resume affordance ("Press Enter to continue after reset"),
# which never reaches the transcript, so losing either arm to a vendor reword
# still leaves the other standing. docs/verification/supervision.md owns the
# evidence and the refresh command.
fm_allowance_pane_signature() {  # <harness>
  case "${1:-}" in
    claude*)
      printf '%s' "You.?ve hit your (session|weekly|usage) limit|Press Enter to continue after reset"
      ;;
    *) return 1 ;;
  esac
}

# fm_allowance_pane_parked: consume a pane capture on stdin; print the matched
# notice and return 0 when <harness>'s rendered signature appears in the tail.
fm_allowance_pane_parked() {  # <harness>
  local harness=${1:-} signature hit
  signature=$(fm_allowance_pane_signature "$harness") || return 1
  hit=$(grep -v '^[[:space:]]*$' \
    | tail -n "$FM_ALLOWANCE_PANE_TAIL_LINES" \
    | grep -aEm1 "$signature") || return 1
  [ -n "$hit" ] || return 1
  # Rendered output arrives with whatever padding and box drawing the harness laid
  # out around it; the wake reason is read by a human, so trim it back to the
  # notice itself.
  printf '%s' "$hit" | sed -e 's/^[^[:alnum:]]*//' -e 's/[[:space:]]*$//'
}

# _fm_allowance_claude_project_dir: where Claude Code keeps the transcripts for a
# worktree. Claude derives the directory name from the session's working directory
# by replacing `/` and `.` with `-`. CLAUDE_CONFIG_DIR relocates the whole tree
# when set, and bin/fm-spawn.sh forwards firstmate's own resolved store onto the
# crewmate launch, so a caller running in firstmate's environment resolves the
# same store the crewmate writes. A mangling this does not reproduce simply yields
# a directory that does not exist, and the pane signal covers that case - it never
# yields another worktree's transcript, because the caller below re-checks the
# recorded `cwd` before trusting what it reads.
_fm_allowance_claude_project_dir() {  # <worktree>
  local wt=${1:-} base mangled
  [ -n "$wt" ] || return 1
  base=${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}
  mangled=${wt//\//-}
  mangled=${mangled//./-}
  printf '%s/projects/%s' "$base" "$mangled"
}

# _fm_allowance_claude_record: the transcript to read for <worktree> - the most
# recently modified one in that worktree's project directory, which is the live
# session (a parked session stops being written the moment it parks, so a
# relaunch's newer file always outranks it). Prints nothing and fails when the
# directory is absent, holds no transcript yet, or records a different worktree.
#
# The listing is deliberately a plain glob rather than a find/ls pipeline: `find
# -exec ls -t {} +` batches its arguments once a directory grows large enough, and
# each batch is sorted separately, so the first line stops being the newest file.
_fm_allowance_claude_record() {  # <worktree>
  local wt=${1:-} dir f newest='' cwd
  dir=$(_fm_allowance_claude_project_dir "$wt") || return 1
  [ -d "$dir" ] || return 1
  # A session subdirectory (Claude writes `<session>/tool-results/` before the
  # transcript itself exists) must not be mistaken for a record, hence -f.
  for f in "$dir"/*.jsonl; do
    [ -f "$f" ] || continue
    if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then newest=$f; fi
  done
  [ -n "$newest" ] || return 1
  # Confirm the transcript is this worktree's before believing anything in it. The
  # session may have cd'd into a subdirectory, so the worktree is a prefix, not an
  # equality.
  cwd=$(grep -aom1 '"cwd":"[^"]*"' "$newest" 2>/dev/null | sed 's/^"cwd":"//; s/"$//')
  [ -n "$cwd" ] || return 1
  case "$cwd" in
    "$wt"|"$wt"/*) ;;
    *) return 1 ;;
  esac
  printf '%s' "$newest"
}

# _fm_allowance_record_parked: fold the tail of a session transcript and report
# whether its LAST conversational record is a provider refusal.
#
# The fields are the harness's own machine-readable error reporting, not its UI: a
# refused turn is written as an assistant record carrying isApiErrorMessage with an
# HTTP 429 status. Taking the LAST conversational record - and only user/assistant
# records count, so session metadata appended after parking is skipped - is what
# makes this current-state rather than history: a crew that hit the limit and was
# resumed has a later ordinary record, and reports not parked.
_fm_allowance_record_parked() {  # <file>
  local f=${1:-}
  [ -f "$f" ] || return 1
  tail -n "$FM_ALLOWANCE_RECORD_TAIL_LINES" "$f" 2>/dev/null | awk '
    /"type"[ ]*:[ ]*"(user|assistant)"/ {
      parked = 0
      detail = ""
      if ($0 ~ /"isApiErrorMessage"[ ]*:[ ]*true/ && $0 ~ /"apiErrorStatus"[ ]*:[ ]*429/) {
        parked = 1
        if (match($0, /"text"[ ]*:[ ]*"[^"]*"/)) {
          detail = substr($0, RSTART, RLENGTH)
          sub(/^"text"[ ]*:[ ]*"/, "", detail)
          sub(/"$/, "", detail)
        }
      }
    }
    END {
      if (!parked) exit 1
      print detail
    }
  '
}

# _fm_allowance_record_resumed: the last provider refusal in the tail of a session
# transcript that a later conversational record followed - the worker took a turn
# after being refused - as "<reset-epoch>|<notice>", the reset empty when the build
# recorded none. Fails when the tail holds no such refusal.
_fm_allowance_record_resumed() {  # <file>
  local f=${1:-}
  [ -f "$f" ] || return 1
  tail -n "$FM_ALLOWANCE_RECORD_TAIL_LINES" "$f" 2>/dev/null | awk '
    /"type"[ ]*:[ ]*"(user|assistant)"/ {
      refused = ($0 ~ /"isApiErrorMessage"[ ]*:[ ]*true/ && $0 ~ /"apiErrorStatus"[ ]*:[ ]*429/)
      if (refused) {
        seen = 1
        reset = ""
        notice = ""
        if (match($0, /"resetsAt"[ ]*:[ ]*[0-9]+/)) {
          reset = substr($0, RSTART, RLENGTH)
          sub(/^"resetsAt"[ ]*:[ ]*/, "", reset)
        }
        if (match($0, /"text"[ ]*:[ ]*"[^"]*"/)) {
          notice = substr($0, RSTART, RLENGTH)
          sub(/^"text"[ ]*:[ ]*"/, "", notice)
          sub(/"$/, "", notice)
        }
      }
      last = refused
    }
    END {
      if (!seen || last) exit 1
      print reset "|" notice
    }
  '
}

# _fm_allowance_reset_clock: the reset clock a notice renders ("resets 8:30am
# (UTC)"), which is the one part of the text that differs between windows. It is
# read to the closing parenthesis and not to a separator, for the same reason the
# pane signature does not match one. Prints nothing when there is none.
_fm_allowance_reset_clock() {  # <text>
  local re='resets [^)]*\)'
  [[ ${1:-} =~ $re ]] || return 1
  printf '%s' "${BASH_REMATCH[0]}"
}

# _fm_allowance_pane_clock: consume a pane capture on stdin; print the reset clock
# of the NEWEST notice in its tail, so an old notice left above a fresh one cannot
# stand in for it.
_fm_allowance_pane_clock() {
  local text
  text=$(grep -v '^[[:space:]]*$' | tail -n "$FM_ALLOWANCE_PANE_TAIL_LINES" \
    | grep -aoE 'resets [^)]*\)' | tail -n 1) || return 1
  [ -n "$text" ] || return 1
  printf '%s' "$text"
}

# _fm_allowance_pane_is_over_episode: 0 when the pane's notice is one the
# transcript has already shown over. <over> is "<reset-epoch>|<notice>" for a
# refusal the worker moved past, empty when there is none. Both halves must hold
# - the refusal's recorded reset is already past, and the pane's newest reset clock
# is the clock that refusal named - and a missing reset or an unreadable clock on
# either side means the pane is NOT shown to be the same episode.
_fm_allowance_pane_is_over_episode() {  # <over> <pane-tail>
  local over=${1:-} tail=${2-} reset notice clock now
  [ -n "$over" ] || return 1
  reset=${over%%|*}
  notice=${over#*|}
  case "$reset" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date -u +%s)
  [ "$reset" -le "$now" ] || return 1
  clock=$(_fm_allowance_reset_clock "$notice") || return 1
  [ "$clock" = "$(printf '%s' "$tail" | _fm_allowance_pane_clock)" ]
}

# _fm_allowance_record_path: the transcript <harness> writes for <worktree>, for
# the adapters whose store firstmate can locate. Split out from the verdicts below
# because the refusal, its reset and the time bound must all read the same file.
_fm_allowance_record_path() {  # <harness> <worktree>
  case "${1:-}" in
    claude*) _fm_allowance_claude_record "${2:-}" ;;
    *) return 1 ;;
  esac
}

# fm_allowance_record_parked: the structural signal for <harness> in <worktree>.
# Prints the refusal notice and returns 0 when the harness's own transcript shows
# the crew parked. Only adapters whose transcript firstmate can locate participate;
# the rest fall through to the pane signal.
fm_allowance_record_parked() {  # <harness> <worktree>
  local record
  record=$(_fm_allowance_record_path "${1:-}" "${2:-}") || return 1
  _fm_allowance_record_parked "$record"
}

# _fm_allowance_record_reset: the reset the harness itself recorded, as an epoch
# second, taken from the LAST conversational record and only when that record is
# the refusal - the same "current state, not history" fold as the verdict above.
#
# The refusal record carries the vendor's own machine-readable
# `quotaLimits.resetsAt`, an absolute epoch second, alongside the rateLimitType
# it belongs to. That is strictly better than the clock rendered inside the
# notice ("resets 2:50am (UTC)"), which carries no date at all and so cannot say
# which day a weekly window resets on. Preferring the structural field over the
# rendered one is the same rule the two park signals already follow.
#
# The field is version-gated rather than universal: measured over the local
# store on 2026-09-20, 232 of 245 refusal records carry an integer resetsAt and
# the 13 that do not are a null quotaLimits written by Claude Code 2.1.226 and
# 2.1.227 (docs/verification/supervision.md). An absent field therefore reports
# no reset, and every caller treats that as "no bound", never as zero.
_fm_allowance_record_reset() {  # <file>
  local f=${1:-}
  [ -f "$f" ] || return 1
  tail -n "$FM_ALLOWANCE_RECORD_TAIL_LINES" "$f" 2>/dev/null | awk '
    /"type"[ ]*:[ ]*"(user|assistant)"/ {
      reset = ""
      if ($0 ~ /"isApiErrorMessage"[ ]*:[ ]*true/ && $0 ~ /"apiErrorStatus"[ ]*:[ ]*429/) {
        if (match($0, /"resetsAt"[ ]*:[ ]*[0-9]+/)) {
          reset = substr($0, RSTART, RLENGTH)
          sub(/^"resetsAt"[ ]*:[ ]*/, "", reset)
        }
      }
    }
    END {
      if (reset == "") exit 1
      print reset
    }
  '
}

# fm_allowance_record_reset_epoch: the recorded reset for <harness> in
# <worktree>. Fails when the worker is not parked, its transcript cannot be
# located or trusted, or the harness build wrote no reset.
fm_allowance_record_reset_epoch() {  # <harness> <worktree>
  local record reset
  record=$(_fm_allowance_record_path "${1:-}" "${2:-}") || return 1
  reset=$(_fm_allowance_record_reset "$record") || return 1
  case "$reset" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$reset"
}

# _fm_allowance_epoch_iso: <epoch> as a UTC "YYYY-MM-DDTHH:MM:SS", the leading
# 19 characters of the timestamps a transcript records, so the two compare as
# strings without parsing either. BSD date takes -r, GNU date takes -d @<epoch>,
# and on Linux `date -r` names a FILE, so the two are selected by platform rather
# than chained.
_fm_allowance_epoch_iso() {  # <epoch>
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    /bin/date -u -r "${1:-0}" +%Y-%m-%dT%H:%M:%S 2>/dev/null
  else
    date -u -d "@${1:-0}" +%Y-%m-%dT%H:%M:%S 2>/dev/null
  fi
}

# _fm_allowance_mtime: epoch seconds of a file's mtime, portably. BSD stat takes
# `-f`, GNU stat takes `-c`, and on Linux `stat -f` is filesystem stat and prints
# a partial dump before failing, so the two forms are selected by platform rather
# than chained (the same trap bin/fm-watch.sh documents at its own stat_mtime).
_fm_allowance_mtime() {  # <file>
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    /usr/bin/stat -f %m "${1:-}" 2>/dev/null
  else
    stat -c %Y "${1:-}" 2>/dev/null
  fi
}

# _fm_allowance_record_written: the timestamp of the newest conversational or
# system record in the transcript tail, as its leading "YYYY-MM-DDTHH:MM:SS".
# Records with no timestamp of their own - the session metadata appended around a
# shutdown - are not a turn and are skipped.
_fm_allowance_record_written() {  # <file>
  local f=${1:-} stamp
  [ -f "$f" ] || return 1
  stamp=$(tail -n "$FM_ALLOWANCE_RECORD_TAIL_LINES" "$f" 2>/dev/null | awk '
    /"type"[ ]*:[ ]*"(user|assistant|system)"/ {
      if (match($0, /"timestamp"[ ]*:[ ]*"[^"]*"/)) {
        stamp = substr($0, RSTART, RLENGTH)
        sub(/^"timestamp"[ ]*:[ ]*"/, "", stamp)
        sub(/"$/, "", stamp)
      }
    }
    END { if (stamp == "") exit 1; print substr(stamp, 1, 19) }
  ') || return 1
  printf '%s' "$stamp"
}

# _fm_allowance_record_superseded: 0 when the refusal record in <file> is HISTORY
# rather than current state - the worker's own transcript has a record written at
# or after the reset that same refusal names, which only a worker that took a turn
# can produce. A worker still sitting at its limit prompt has no new turn, and the
# refusal record itself is written while its own reset is still in the future, so
# a fresh park can never satisfy the bound.
#
# A build that recorded no reset has no bound and reports 1 - not superseded - so
# the verdict there is exactly what it was before this bound existed.
_fm_allowance_record_superseded() {  # <file>
  local f=${1:-} reset written
  reset=$(_fm_allowance_record_reset "$f") || return 1
  case "$reset" in ''|*[!0-9]*) return 1 ;; esac
  written=$(_fm_allowance_record_written "$f") || return 1
  ! [[ "$written" < "$(_fm_allowance_epoch_iso "$reset")" ]]
}

# fm_allowance_park_detail: the single entry point. Prints "<source> <detail>" and
# returns 0 when the crew is parked on the account allowance.
#
# <pane-tail> is the bounded capture the caller has already read for its own
# hashing, so detection adds no extra capture. Passing it empty restricts the check
# to the structural signal, which is what a caller does when it cannot yet vouch
# that the pane is settled.
#
# The structural signal is consulted first because it is the one a vendor cannot
# change by rewording a screen, but either signal alone is a positive verdict: a
# worker whose transcript firstmate cannot find is still detected from its pane,
# and a harness that reworded its notice is still detected from its transcript.
#
# Where the transcript says a refusal is over, the pane does not get to reassert
# that same refusal. One it has superseded, or that later conversation followed, is
# an episode the worker left; the notice still rendered near its prompt is
# scrollback, and asserting it would report a resumed worker as parked. But the
# pane is only shut out of THAT episode. A worker that has since parked again
# through a notice the transcript never recorded shows a different reset clock,
# and is reported. A pane-only park - no transcript, or one that never recorded a
# refusal - is exactly as visible as it was.
fm_allowance_park_detail() {  # <harness> <worktree> [pane-tail]
  local harness=${1:-} wt=${2:-} tail=${3-} detail record over=''
  fm_allowance_harness_verified "$harness" || return 1
  if record=$(_fm_allowance_record_path "$harness" "$wt"); then
    if detail=$(_fm_allowance_record_parked "$record"); then
      if ! _fm_allowance_record_superseded "$record"; then
        printf 'session-record %s' "${detail:-provider refused the turn on the account allowance}"
        return 0
      fi
      over="$(_fm_allowance_record_reset "$record" || true)|$detail"
    else
      over=$(_fm_allowance_record_resumed "$record") || over=''
    fi
  fi
  [ -n "$tail" ] || return 1
  if detail=$(printf '%s' "$tail" | fm_allowance_pane_parked "$harness"); then
    ! _fm_allowance_pane_is_over_episode "$over" "$tail" || return 1
    printf 'pane %s' "$detail"
    return 0
  fi
  return 1
}
