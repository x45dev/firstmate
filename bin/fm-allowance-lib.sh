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
# epoch second, and that is what bounds the verdict in time. A refusal record is
# evidence about the moment it was written; without a bound it goes on asserting
# "parked" for as long as the transcript holds it, which is what left
# bin/fm-crew-state.sh reporting a resumed, visibly working worker as parked long
# after its reset. So the structural arm stops claiming anything once the
# worker's own transcript has been written at or after that recorded reset: a
# still-parked worker writes nothing more, so a transcript that crossed its own
# reset is a worker that took a turn.
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

# _fm_allowance_record_path: the transcript <harness> writes for <worktree>, for
# the adapters whose store firstmate can locate. Split out from the verdict below
# because the time bound has to stat the same file the verdict read.
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

# fm_allowance_record_superseded: 0 when the refusal record is HISTORY rather
# than current state - the worker's own transcript has been written at or after
# the reset that same record names, which only a worker that took a turn can do.
#
# This is the time bound the header describes, and it is a conjunction of two
# things the vendor writes independently: the absolute reset inside the refusal
# record, and the mtime of the file the harness appends to. A worker still
# sitting at its limit prompt writes nothing more, so its transcript cannot cross
# its own reset however long it sits there; a resumed worker crosses it on its
# first turn. Neither half is a rendered string, and neither can be satisfied by
# the refusal record itself, which is written while its own reset is still in the
# future.
#
# A build that recorded no reset has no bound and reports 1 - not superseded -
# so the verdict there is exactly what it was before this bound existed.
fm_allowance_record_superseded() {  # <harness> <worktree>
  local harness=${1:-} wt=${2:-} reset record mtime
  reset=$(fm_allowance_record_reset_epoch "$harness" "$wt") || return 1
  record=$(_fm_allowance_record_path "$harness" "$wt") || return 1
  mtime=$(_fm_allowance_mtime "$record") || return 1
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  [ "$mtime" -ge "$reset" ]
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
# A structural verdict the time bound reports superseded is dropped rather than
# returned, and the pane arm is still consulted below it: the transcript has
# moved past its own reset, so it is no longer evidence about now, while a pane
# still rendering the notice is. That is the whole of the fix for a worker being
# reported parked while it is visibly working.
fm_allowance_park_detail() {  # <harness> <worktree> [pane-tail]
  local harness=${1:-} wt=${2:-} tail=${3-} detail
  fm_allowance_harness_verified "$harness" || return 1
  if detail=$(fm_allowance_record_parked "$harness" "$wt"); then
    if ! fm_allowance_record_superseded "$harness" "$wt"; then
      printf 'session-record %s' "${detail:-provider refused the turn on the account allowance}"
      return 0
    fi
  fi
  [ -n "$tail" ] || return 1
  if detail=$(printf '%s' "$tail" | fm_allowance_pane_parked "$harness"); then
    printf 'pane %s' "$detail"
    return 0
  fi
  return 1
}
