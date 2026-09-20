#!/usr/bin/env bash
# tests/fm-allowance-park.test.sh - detection of a worker parked on the ACCOUNT
# allowance (bin/fm-allowance-lib.sh) and the two callers that act on it:
# bin/fm-watch.sh, which must surface the park as a named wake, and
# bin/fm-crew-state.sh, which must report it as the crew's current state.
#
# The defect these pin: a refused turn leaves the process alive, the endpoint
# alive, and the pane rendering normally, so every liveness probe firstmate owns
# reads healthy and nothing fires. On 2026-08-17 two crewmates parked seconds
# after launch and were found hours after their reset had already passed, by a
# wedge alarm that had nothing to do with the cause.
#
# The verdict is harness-dependent - both signals come from something the vendor
# emits - so this portable half pins the classifier logic with no harness
# installed, and the opt-in live half in
# tests/fm-allowance-park-live-e2e.test.sh proves the transcript store is still
# where firstmate looks for a REAL worker. Neither replaces the other: a stub can
# only confirm the assumption already written into the stub, and a live guard
# cannot run in CI.
#
# Both signals are driven apart deliberately in the cases below, because a
# two-signal check whose signals are never separated is indistinguishable from a
# one-signal check: each case that asserts the verdict survives losing a signal
# first asserts that the signal really is absent.
#
# The same file also pins what supervision DOES about a park, because detecting
# one and leaving it stopped is most of the original defect: on 2026-09-11 five
# workers parked at once and the wake told its reader to press Enter, which
# submits nothing into the empty composer an ENDED turn leaves behind; on
# 2026-09-20 three sat stopped overnight past their reset until a person messaged
# each one by hand. So the resume cases below assert a steering record rather
# than a keystroke, exactly once per park, and never while the provider still
# reports the allowance spent - a message sent into a spent allowance is consumed
# for nothing and the worker parks again on the same turn.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-allowance-lib.sh"
# The resume rides the ordinary steering-inbox plane, so the record format is
# read back through its own owner rather than re-derived here.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"

# The provider read is cached per home for FM_ALLOWANCE_QUOTA_TTL seconds so a
# fleet of parked workers costs one subprocess rather than one each. The resume
# cases below flip the provider's answer between watcher runs to prove which gate
# is holding a message back, so that cache is disabled for the whole file.
export FM_ALLOWANCE_QUOTA_TTL=0

WATCH="$ROOT/bin/fm-watch.sh"
CREW_STATE="$ROOT/bin/fm-crew-state.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-allowance-park-tests)

reap() { fm_test_stop "$1" "${2:-watcher}"; }

# The rendered notice exactly as the 2026-08-17 incident's panes carried it,
# including the resume affordance that never reaches the transcript.
PARKED_PANE_LINE="You've hit your session limit · resets 8:30am (UTC) · Press Enter to continue after reset"

# set_mtime <epoch> <path>
# Portable mtime stamping: BSD date takes -r, GNU date takes -d @<epoch>.
set_mtime() {  # <epoch> <path>
  local epoch=$1 path=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$path"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$path"
  fi
}

# write_transcript <file> <cwd> <parked|resumed> [reset-epoch|none]
# A Claude Code session transcript whose LAST conversational record is either the
# refusal itself (parked) or an ordinary reply that landed after it (resumed).
# The refusal record carries the vendor's own machine-readable error fields; the
# trailing non-conversational record is there because a real transcript has one,
# and the fold must skip it rather than stop at it.
#
# <reset-epoch> is the absolute reset the vendor records beside those fields,
# defaulting to an hour out - the shape of a park that has only just happened,
# where the transcript cannot yet have crossed its own reset. `none` writes the
# null quotaLimits older Claude Code builds wrote instead, which is what a
# transcript with no recorded reset at all looks like.
write_transcript() {  # <file> <cwd> <mode> [reset-epoch|none]
  local file=$1 cwd=$2 mode=$3 reset=${4:-} quota
  [ -n "$reset" ] || reset=$(( $(date -u +%s) + 3600 ))
  if [ "$reset" = none ]; then
    quota='"quotaLimits":null'
  else
    quota=$(printf '"quotaLimits":{"status":"rejected","resetsAt":%s,"rateLimitType":"five_hour"}' "$reset")
  fi
  {
    printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"go"}}\n' "$cwd"
    printf '{"type":"assistant","cwd":"%s","message":{"role":"assistant","content":[{"type":"text","text":"working on it"}]}}\n' "$cwd"
    printf '{"type":"assistant","cwd":"%s","message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"You'"'"'ve hit your session limit · resets 8:30am (UTC)"}]},%s,"error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429}\n' "$cwd" "$quota"
    if [ "$mode" = resumed ]; then
      printf '{"type":"assistant","cwd":"%s","message":{"role":"assistant","content":[{"type":"text","text":"resumed after the reset"}]}}\n' "$cwd"
    fi
    printf '{"type":"last-prompt","lastPrompt":"go"}\n'
  } > "$file"
}

# make_store <dir> <worktree> <parked|resumed|none> [reset-epoch|none] [mtime-epoch]
# A CLAUDE_CONFIG_DIR-shaped transcript store for <worktree>, using the same
# directory mangling Claude Code derives from the session's working directory.
# "none" builds the store with no transcript in it at all, which is how a case
# takes the structural signal away without also taking the store away.
#
# <mtime-epoch> stamps the transcript, because the time bound compares that mtime
# against the recorded reset and a fixture written just now is always "after"
# anything in the past.
make_store() {  # <dir> <worktree> <mode> [reset-epoch|none] [mtime-epoch]
  local base=$1 wt=$2 mode=$3 reset=${4:-} mtime=${5:-} mangled dir
  mangled=$(printf '%s' "$wt" | tr '/.' '--')
  dir="$base/projects/$mangled"
  mkdir -p "$dir"
  if [ "$mode" != none ]; then
    write_transcript "$dir/session.jsonl" "$wt" "$mode" "$reset"
    [ -z "$mtime" ] || set_mtime "$mtime" "$dir/session.jsonl"
  fi
  printf '%s\n' "$dir"
}

# --- the verdict itself ------------------------------------------------------

test_pane_signal_reads_the_rendered_notice() {
  local dir out
  dir="$TMP_ROOT/pane-signal"; mkdir -p "$dir"
  out=$(printf 'building the thing\n%s\n' "$PARKED_PANE_LINE" | fm_allowance_pane_parked claude) \
    || fail "the rendered limit notice was not read as a park"
  case "$out" in
    *"hit your session limit"*) ;;
    *) fail "the pane verdict did not carry the notice: $out" ;;
  esac
  # An ordinary working pane, including one whose footer talks about limits in
  # passing, must not park: this check may only ever ADD a wake, and a false
  # positive here is a second source of false wedge alarms.
  ! printf 'Running tests (esc to interrupt)\ncontext left until auto-compact: 31%%\n' \
    | fm_allowance_pane_parked claude \
    || fail "ordinary working output was read as parked"
  ! printf 'ok\n' | fm_allowance_pane_parked claude \
    || fail "an unremarkable pane was read as parked"
  pass "the pane signal reads the rendered notice and leaves ordinary output alone"
}

test_pane_signal_is_bounded_to_the_prompt_region() {
  local i body=''
  # The same notice quoted in DISPLAYED CONTENT - a file being read, a grep hit,
  # this very test - scrolls out of the region a harness redraws around its own
  # prompt. Without the bound, any worker that so much as greps for the string
  # parks itself.
  body="$PARKED_PANE_LINE"$'\n'
  for i in $(seq 1 "$((FM_ALLOWANCE_PANE_TAIL_LINES + 5))"); do
    body="$body""line $i of ordinary output"$'\n'
  done
  ! printf '%s' "$body" | fm_allowance_pane_parked claude \
    || fail "a limit notice scrolled far above the prompt still matched"
  pass "the pane signal is bounded to the tail, so quoted content cannot park a worker"
}

test_record_signal_is_current_state_not_history() {
  local dir wt out
  dir="$TMP_ROOT/record-signal"; wt="$dir/wt"; mkdir -p "$wt"
  write_transcript "$dir/parked.jsonl" "$wt" parked
  write_transcript "$dir/resumed.jsonl" "$wt" resumed
  out=$(_fm_allowance_record_parked "$dir/parked.jsonl") \
    || fail "a transcript ending on the refusal was not read as parked"
  case "$out" in
    *"hit your session limit"*) ;;
    *) fail "the record verdict did not carry the notice: $out" ;;
  esac
  # The same refusal, with the worker back at work after it. Reading the file for
  # the refusal ANYWHERE would report this one parked forever.
  ! _fm_allowance_record_parked "$dir/resumed.jsonl" \
    || fail "a transcript that resumed after its refusal was still read as parked"
  pass "the record signal reports the last conversational record, not any refusal in history"
}

test_record_signal_stops_claiming_once_the_transcript_crossed_its_reset() {
  local dir wt now store out
  dir="$TMP_ROOT/record-bound"; wt="$dir/wt"; mkdir -p "$wt"
  now=$(date -u +%s)

  # Still parked, an hour past its reset: the transcript froze when the turn was
  # refused and has not been written since, which is what a worker sitting at its
  # limit prompt looks like however long it sits there.
  store=$(make_store "$dir/still" "$wt" parked "$(( now - 3600 ))" "$(( now - 7200 ))")
  [ -f "$store/session.jsonl" ] || fail "the still-parked fixture has no transcript"
  out=$(CLAUDE_CONFIG_DIR="$dir/still" fm_allowance_park_detail claude "$wt" '') \
    || fail "a worker still frozen at its limit prompt past its reset was not read as parked"
  case "$out" in
    "session-record "*) ;;
    *) fail "expected the structural source to carry the still-parked verdict, got: $out" ;;
  esac

  # The same refusal, the same reset, and a transcript that has been written
  # since that reset - which only a worker that took a turn can do. The fold is
  # deliberately asserted first: it still reads the refusal as the last
  # conversational record, so the ONLY thing that changed the verdict is the time
  # bound, and this case cannot go vacuous by the fold quietly answering instead.
  store=$(make_store "$dir/moved" "$wt" parked "$(( now - 3600 ))" "$now")
  _fm_allowance_record_parked "$store/session.jsonl" >/dev/null \
    || fail "the moved fixture's last conversational record is not the refusal, so the bound is not what this case tests"
  ! CLAUDE_CONFIG_DIR="$dir/moved" fm_allowance_park_detail claude "$wt" '' \
    || fail "a transcript written since its own recorded reset was still asserted parked"

  # A build that recorded no reset has no bound, and must behave exactly as it
  # did before the bound existed rather than losing the verdict to it.
  store=$(make_store "$dir/unrecorded" "$wt" parked none "$now")
  ! _fm_allowance_record_reset "$store/session.jsonl" >/dev/null 2>&1 \
    || fail "the unrecorded fixture still carries a reset, so it proves nothing"
  CLAUDE_CONFIG_DIR="$dir/unrecorded" fm_allowance_park_detail claude "$wt" '' >/dev/null \
    || fail "a refusal record with no recorded reset lost its verdict to the time bound"

  pass "the record signal stops claiming a park once the transcript crossed its own recorded reset"
}

test_crew_state_stops_claiming_a_park_the_worker_has_worked_past() {
  local dir wt state now out
  dir="$TMP_ROOT/crew-state-bound"; wt="$dir/wt"; state="$dir/state"
  mkdir -p "$wt" "$state"
  now=$(date -u +%s)
  # The defect this pins: the same transcript reported `parked · source:
  # allowance` after the reset had passed AND after the worker was resumed and
  # was visibly working, so only a pane peek could tell stopped from running.
  make_store "$dir/store" "$wt" parked "$(( now - 3600 ))" "$now" >/dev/null
  printf 'window=test:fm-worked-past\nkind=ship\nharness=claude\nworktree=%s\n' "$wt" > "$state/worked-past.meta"
  out=$(CLAUDE_CONFIG_DIR="$dir/store" FM_STATE_OVERRIDE="$state" "$CREW_STATE" worked-past) \
    || fail "fm-crew-state.sh failed on a worker that worked past its reset"
  case "$out" in
    *"source: allowance"*) fail "a worker whose transcript moved past its reset was still reported parked: $out" ;;
  esac
  pass "fm-crew-state.sh stops asserting an allowance park once the worker has taken a turn since the reset"
}

test_unsupported_harness_never_parks() {
  local dir wt store
  dir="$TMP_ROOT/unsupported"; wt="$dir/wt"; mkdir -p "$wt"
  store=$(make_store "$dir/store" "$wt" parked)
  [ -f "$store/session.jsonl" ] || fail "fixture store was not built"
  # Per-harness support is a gate, not a default. An adapter with no verified
  # signature must behave exactly as it did before this check existed, even when
  # a transcript and a pane are sitting right there saying "parked".
  ! CLAUDE_CONFIG_DIR="$dir/store" fm_allowance_park_detail codex "$wt" "$PARKED_PANE_LINE" \
    || fail "an unverified harness parked on another harness's signature"
  ! CLAUDE_CONFIG_DIR="$dir/store" fm_allowance_park_detail '' "$wt" "$PARKED_PANE_LINE" \
    || fail "a task with no recorded harness parked"
  pass "a harness with no verified signature never parks"
}

test_either_signal_alone_carries_the_verdict() {
  local dir wt store out
  dir="$TMP_ROOT/divergence"; wt="$dir/wt"; mkdir -p "$wt"

  # Signal A alone: the transcript records the refusal, the pane shows ordinary
  # work. First prove the pane really is silent, so the surviving verdict cannot
  # be the pane's.
  store=$(make_store "$dir/record-only" "$wt" parked)
  [ -f "$store/session.jsonl" ] || fail "record-only fixture has no transcript"
  ! printf 'Running tests (esc to interrupt)\n' | fm_allowance_pane_parked claude \
    || fail "the record-only case's pane was not actually silent"
  out=$(CLAUDE_CONFIG_DIR="$dir/record-only" fm_allowance_park_detail claude "$wt" 'Running tests (esc to interrupt)') \
    || fail "the transcript signal alone did not carry the verdict"
  case "$out" in
    "session-record "*) ;;
    *) fail "expected the structural source to be named, got: $out" ;;
  esac

  # Signal B alone: the store holds no transcript, the pane shows the notice.
  # First prove the transcript really is missing, so the surviving verdict cannot
  # be the transcript's.
  make_store "$dir/pane-only" "$wt" none >/dev/null
  ! CLAUDE_CONFIG_DIR="$dir/pane-only" fm_allowance_record_parked claude "$wt" \
    || fail "the pane-only case still had a usable transcript"
  out=$(CLAUDE_CONFIG_DIR="$dir/pane-only" fm_allowance_park_detail claude "$wt" "$PARKED_PANE_LINE") \
    || fail "the pane signal alone did not carry the verdict"
  case "$out" in
    "pane "*) ;;
    *) fail "expected the rendered source to be named, got: $out" ;;
  esac

  # Neither signal: not parked, and the store exists so this is a real negative
  # rather than a missing fixture.
  ! CLAUDE_CONFIG_DIR="$dir/pane-only" fm_allowance_park_detail claude "$wt" 'Running tests (esc to interrupt)' \
    || fail "a worker with neither signal was read as parked"
  pass "either signal alone carries the verdict, and losing both clears it"
}

test_transcript_must_belong_to_this_worktree() {
  local dir wt other store
  dir="$TMP_ROOT/wrong-worktree"; wt="$dir/wt"; other="$dir/other"; mkdir -p "$wt" "$other"
  store=$(make_store "$dir/store" "$wt" none)
  # A transcript sitting in this worktree's store but recording a DIFFERENT
  # working directory is not evidence about this worker.
  write_transcript "$store/session.jsonl" "$other" parked
  ! CLAUDE_CONFIG_DIR="$dir/store" fm_allowance_record_parked claude "$wt" \
    || fail "a transcript recording another worktree was trusted"
  pass "a transcript is trusted only when it records this worktree"
}

# --- fm-crew-state.sh: the park is reported as the cause ---------------------

test_crew_state_reports_the_park_over_a_busy_verdict() {
  local dir wt state out
  dir="$TMP_ROOT/crew-state"; wt="$dir/wt"; state="$dir/state"
  mkdir -p "$wt" "$state"
  make_store "$dir/store" "$wt" parked >/dev/null
  printf 'window=test:fm-parked\nkind=ship\nharness=claude\nworktree=%s\n' "$wt" > "$state/parked.meta"
  out=$(CLAUDE_CONFIG_DIR="$dir/store" FM_STATE_OVERRIDE="$state" "$CREW_STATE" parked) \
    || fail "fm-crew-state.sh failed on a parked crew"
  case "$out" in
    "state: parked"*"source: allowance"*) ;;
    *) fail "a parked crew was not reported as parked on the allowance: $out" ;;
  esac
  case "$out" in
    *"hit your session limit"*) ;;
    *) fail "the reported state did not name the cause: $out" ;;
  esac
  pass "fm-crew-state.sh reports an allowance park as the crew's current state"
}

test_crew_state_leaves_an_unparked_crew_alone() {
  local dir wt state out
  dir="$TMP_ROOT/crew-state-clean"; wt="$dir/wt"; state="$dir/state"
  mkdir -p "$wt" "$state"
  make_store "$dir/store" "$wt" resumed >/dev/null
  printf 'window=test:fm-live\nkind=ship\nharness=claude\nworktree=%s\n' "$wt" > "$state/live.meta"
  printf 'working: still going\n' > "$state/live.status"
  out=$(CLAUDE_CONFIG_DIR="$dir/store" FM_STATE_OVERRIDE="$state" "$CREW_STATE" live) \
    || fail "fm-crew-state.sh failed on a working crew"
  case "$out" in
    *"source: allowance"*) fail "a crew that resumed after its refusal was reported as parked: $out" ;;
  esac
  pass "fm-crew-state.sh leaves a crew that is not parked to the sources below"
}

# --- fm-watch.sh: the park surfaces as a named wake --------------------------

# build_parked_case <name> <transcript-mode> <pane-text>
# Build a one-window fixture for a real watcher run and set CASE_* for the
# caller. The crew is fixed PROVABLY WORKING by launch_case_watcher below: that
# is the whole point of these cases, because the park is exactly the condition
# every existing liveness read calls healthy.
build_parked_case() {  # <name> <mode> <pane-text> [reset-epoch|none] [mtime-epoch]
  local name=$1 mode=$2 pane=$3 reset=${4:-} mtime=${5:-} key
  CASE_DIR=$(make_case "$name")
  CASE_STATE="$CASE_DIR/state"
  CASE_CAPTURE="$CASE_DIR/pane.txt"
  CASE_WINDOW="test:fm-$name"
  CASE_WT="$CASE_DIR/wt"
  mkdir -p "$CASE_WT"
  make_store "$CASE_DIR/store" "$CASE_WT" "$mode" "$reset" "$mtime" >/dev/null
  printf '%s\n' "$pane" > "$CASE_CAPTURE"
  printf 'window=%s\nkind=ship\nharness=claude\nworktree=%s\n' \
    "$CASE_WINDOW" "$CASE_WT" > "$CASE_STATE/$name.meta"
  # A settled pane: the watcher trusts the rendered arm only once the capture has
  # been byte-identical across consecutive polls, so prime the hash it will match.
  key=$(printf '%s' "$CASE_WINDOW" | tr ':/.' '___')
  CASE_KEY=$key
  printf '%s' "$(hash_text "$pane")" > "$CASE_STATE/.hash-$key"
  printf '1\n' > "$CASE_STATE/.count-$key"
}

# Run a real watcher over the built fixture, writing to <out> and setting
# CASE_PID. Backgrounded from the caller's own shell (never a command
# substitution) so wait_for_exit can actually reap it.
launch_case_watcher() {  # <out>
  CASE_OUT=$1
  PATH="$CASE_DIR/fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$CASE_WINDOW" \
    FM_FAKE_TMUX_CAPTURE="$CASE_CAPTURE" CLAUDE_CONFIG_DIR="$CASE_DIR/store" \
    FM_CREW_STATE_BIN="$CASE_DIR/fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_STATE_OVERRIDE="$CASE_STATE" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$CASE_OUT" &
  CASE_PID=$!
}

test_watcher_surfaces_a_park_it_would_otherwise_call_healthy() {
  local drain_out
  # Both signals present, which is the incident's own shape.
  build_parked_case allowance-both parked "$PARKED_PANE_LINE"
  launch_case_watcher "$CASE_DIR/watch.out"
  drain_out="$CASE_DIR/drain.out"
  wait_for_exit "$CASE_PID" 100 \
    || { reap "$CASE_PID"; fail "the watcher never surfaced a parked worker: $(cat "$CASE_OUT")"; }
  grep -Fq "parked on the account allowance" "$CASE_OUT" \
    || fail "the wake did not name the allowance as the cause: $(cat "$CASE_OUT")"
  grep -Fq "steering message" "$CASE_OUT" \
    || fail "the wake did not name the recovery: $(cat "$CASE_OUT")"
  # The wording this replaced sent an operator down the keystroke path on
  # 2026-09-11, where Enter reported success for five parked workers and moved
  # none of them, so the wake must not offer it as the recovery again.
  ! grep -Fq "single Enter" "$CASE_OUT" \
    || fail "the wake still tells its reader to press Enter: $(cat "$CASE_OUT")"
  grep -Fq "$CASE_WINDOW" "$CASE_OUT" \
    || fail "the wake did not name the window: $(cat "$CASE_OUT")"
  FM_STATE_OVERRIDE="$CASE_STATE" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "draining the allowance wake failed"
  grep -Fq "parked on the account allowance" "$drain_out" \
    || fail "the allowance wake was not queued durably: $(cat "$drain_out")"
  pass "a worker parked on the allowance is surfaced as a named wake despite reading as working"
}

test_watcher_surfaces_a_park_from_the_transcript_alone() {
  # The rendered notice is gone - a vendor reword, a harness that never printed
  # it, a capture that lost it - and the transcript alone must still carry it.
  build_parked_case allowance-record parked 'Running tests (esc to interrupt)'
  launch_case_watcher "$CASE_DIR/watch.out"
  wait_for_exit "$CASE_PID" 100 \
    || { reap "$CASE_PID"; fail "the watcher missed a park visible only in the transcript: $(cat "$CASE_OUT")"; }
  grep -Fq "parked on the account allowance" "$CASE_OUT" \
    || fail "the transcript-only park did not surface as an allowance wake: $(cat "$CASE_OUT")"
  grep -Fq "session-record signal" "$CASE_OUT" \
    || fail "the wake did not name the signal it came from: $(cat "$CASE_OUT")"
  pass "a park recorded only in the transcript still surfaces, with the source named"
}

test_watcher_leaves_an_ordinary_worker_alone() {
  build_parked_case allowance-none resumed 'Running tests (esc to interrupt)'
  launch_case_watcher "$CASE_DIR/watch.out"
  # A crew that is provably working on a settled pane is absorbed exactly as it
  # was before this check existed; the point of the case is that detection did
  # not become a second source of false wedge alarms.
  if ! wait_poll_cycle "$CASE_STATE" "$CASE_PID"; then
    reap "$CASE_PID"; fail "the watcher exited for an ordinary working crew: $(cat "$CASE_OUT")"
  fi
  ! grep -Fq "allowance" "$CASE_OUT" \
    || fail "an ordinary working crew was reported parked on the allowance: $(cat "$CASE_OUT")"
  [ ! -e "$CASE_STATE/.allowance-$CASE_KEY" ] \
    || fail "an ordinary working crew left an allowance marker behind"
  reap "$CASE_PID"
  pass "a worker that is not parked is untouched by the allowance check"
}

test_watcher_surfaces_each_park_once() {
  build_parked_case allowance-once parked "$PARKED_PANE_LINE"
  launch_case_watcher "$CASE_DIR/watch.out"
  wait_for_exit "$CASE_PID" 100 \
    || { reap "$CASE_PID"; fail "the watcher never surfaced the first park"; }
  [ -s "$CASE_STATE/.allowance-$CASE_KEY" ] \
    || fail "the surfaced park left no marker, so it would re-wake every poll"
  # Firstmate handles the wake: drain and acknowledge it exactly as a supervision
  # turn does, so the queue is clean before the next watcher runs.
  FM_STATE_OVERRIDE="$CASE_STATE" "$DRAIN" > "$CASE_DIR/drain2.out" 2> "$CASE_DIR/drain2.err" || true
  ack_drain_err "$CASE_STATE" "$CASE_DIR/drain2.err" \
    || fail "could not acknowledge the first allowance wake"
  # The worker is still sitting at its limit prompt, and must not wake firstmate
  # again for the same park. Other wake traffic (a check re-arm, say) may still
  # end this watcher's cycle, so the assertion is about the allowance wake alone,
  # not about the watcher staying alive.
  launch_case_watcher "$CASE_DIR/watch2.out"
  wait_for_exit "$CASE_PID" 60 >/dev/null 2>&1 || true
  reap "$CASE_PID"
  ! grep -Fq "parked on the account allowance" "$CASE_OUT" \
    || fail "the same park woke firstmate twice: $(cat "$CASE_OUT")"
  ! grep -Fq "parked on the account allowance" "$CASE_STATE/.wake-queue" 2>/dev/null \
    || fail "the same park was queued twice: $(cat "$CASE_STATE/.wake-queue")"
  pass "a park surfaces once per episode rather than on every poll"
}

# Pins the pane-only fallback (no locatable/trusted transcript for this
# worktree) specifically, since that is the path where an ordinary worker's
# structural-only probe - the one run ahead of the secondmate skip, with an
# empty tail - used to clear the marker on its own inconclusive failure just
# before the settled-pane call re-detected the same park and re-fired the wake.
# A "parked" fixture never reaches this: its transcript resolves on the first,
# empty-tail probe, so the marker is never at risk of that probe's failure path.
test_watcher_surfaces_a_pane_only_park_once_across_relaunches() {
  build_parked_case allowance-pane-only none "$PARKED_PANE_LINE"
  launch_case_watcher "$CASE_DIR/watch.out"
  wait_for_exit "$CASE_PID" 100 \
    || { reap "$CASE_PID"; fail "the watcher never surfaced the pane-only park"; }
  grep -Fq "parked on the account allowance" "$CASE_OUT" \
    || fail "the pane-only park did not surface as an allowance wake: $(cat "$CASE_OUT")"
  [ -s "$CASE_STATE/.allowance-$CASE_KEY" ] \
    || fail "the surfaced pane-only park left no marker, so it would re-wake every poll"
  # Firstmate handles the wake exactly as in the once-per-episode case above, so
  # the next watcher does not immediately re-announce the prior run's own exit as
  # downtime before ever reaching the stale scan this bug lives in.
  FM_STATE_OVERRIDE="$CASE_STATE" "$DRAIN" > "$CASE_DIR/drain2.out" 2> "$CASE_DIR/drain2.err" || true
  ack_drain_err "$CASE_STATE" "$CASE_DIR/drain2.err" \
    || fail "could not acknowledge the first pane-only allowance wake"
  # The worker is still sitting at its limit prompt with the same unreadable
  # transcript, so relaunching must not wake firstmate again for the same park.
  launch_case_watcher "$CASE_DIR/watch2.out"
  wait_for_exit "$CASE_PID" 60 >/dev/null 2>&1 || true
  reap "$CASE_PID"
  ! grep -Fq "parked on the account allowance" "$CASE_OUT" \
    || fail "the same pane-only park woke firstmate twice: $(cat "$CASE_OUT")"
  ! grep -Fq "parked on the account allowance" "$CASE_STATE/.wake-queue" 2>/dev/null \
    || fail "the same pane-only park was queued twice: $(cat "$CASE_STATE/.wake-queue")"
  pass "a pane-only park surfaces once per episode instead of re-waking on every poll"
}

# --- fm-watch.sh: the park is RESUMED, not just reported ---------------------

# Every resume case shares one account-level question - "is the allowance back" -
# so they share one fake provider whose answer a case flips through a file. The
# verdicts are the two the real report distinguishes: a known scope with headroom
# through its reset, and a known scope the provider itself calls exhausted now.
install_fake_quota() {  # <fakebin> <verdict-file>
  local fakebin=$1 verdict_file=$2
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --version ]; then printf 'quota-axi 0.1.29\n'; exit 0; fi
case "$(cat "${FM_FAKE_QUOTA_VERDICT:-/nonexistent}" 2>/dev/null || true)" in
  ready)
    printf '{"schemaVersion":5,"providers":[{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":64,"runway":{"status":"through_reset"}}]}}]}\n'
    ;;
  spent)
    printf '{"schemaVersion":5,"providers":[{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]}}]}\n'
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/quota-axi"
  export FM_FAKE_QUOTA_VERDICT="$verdict_file"
}

# The steering records the resume wrote for <task>, newest sequence last.
inbox_records() {  # <state> <task>
  local f
  for f in "$1/$2.inbox"/*.msg; do
    [ -e "$f" ] || continue
    printf '%s\n' "$f"
  done
}

inbox_count() {  # <state> <task>
  inbox_records "$1" "$2" | grep -c . || true
}

# Wait for <task> to accumulate <count> steering records, or give up. The second
# half of a gate case runs a watcher that has already surfaced this park, so it
# never exits on a wake and there is nothing to wait for except the record
# itself.
wait_for_inbox() {  # <state> <task> <count> [limit-ticks]
  local state=$1 task=$2 want=$3 limit=${4:-150} i=0
  while [ "$i" -lt "$limit" ]; do
    [ "$(inbox_count "$state" "$task")" -lt "$want" ] || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# A park that is genuinely over: an hour past its recorded reset, with a
# transcript that has not been written since it froze. This is the overnight
# shape - the worker is stopped, the allowance is back, and before this change
# nothing moved until a person noticed.
build_resumable_case() {  # <name> <verdict>
  local name=$1 verdict=$2 now
  now=$(date -u +%s)
  build_parked_case "$name" parked "$PARKED_PANE_LINE" "$(( now - 3600 ))" "$(( now - 7200 ))"
  printf '%s' "$verdict" > "$CASE_DIR/quota-verdict"
  install_fake_quota "$CASE_DIR/fakebin" "$CASE_DIR/quota-verdict"
}

test_watcher_resumes_a_parked_worker_whose_allowance_is_back() {
  local rec body
  command -v jq >/dev/null 2>&1 \
    || fail "jq is missing, so the provider gate could not be exercised - this is not a pass"
  build_resumable_case allowance-resume ready
  [ "$(inbox_count "$CASE_STATE" allowance-resume)" -eq 0 ] \
    || fail "the fixture already had a steering record, so nothing below proves the resume wrote one"
  launch_case_watcher "$CASE_DIR/watch.out"
  wait_for_exit "$CASE_PID" 100 \
    || { reap "$CASE_PID"; fail "the watcher never surfaced the resumable park: $(cat "$CASE_OUT")"; }

  [ "$(inbox_count "$CASE_STATE" allowance-resume)" -eq 1 ] \
    || fail "a parked worker past its reset was not sent exactly one steering message (found $(inbox_count "$CASE_STATE" allowance-resume))"
  rec=$(inbox_records "$CASE_STATE" allowance-resume | tail -1)
  body=$(fm_task_inbox_body "$rec") || fail "the resume record has no readable body"
  # The turn ENDED, so the composer is empty and a keystroke submits nothing.
  # What the worker gets has to be a message it can act on.
  case "$body" in
    *"allowance"*) ;;
    *) fail "the resume record does not tell the worker what happened: $body" ;;
  esac
  [ "${#body}" -gt 40 ] \
    || fail "the resume is not a message a stopped worker can act on: $body"

  # Same park, same worker, a later watcher: the episode is already resumed and
  # must not collect a second message every poll.
  FM_STATE_OVERRIDE="$CASE_STATE" "$DRAIN" > "$CASE_DIR/drain2.out" 2> "$CASE_DIR/drain2.err" || true
  ack_drain_err "$CASE_STATE" "$CASE_DIR/drain2.err" \
    || fail "could not acknowledge the first allowance wake"
  launch_case_watcher "$CASE_DIR/watch2.out"
  wait_for_exit "$CASE_PID" 60 >/dev/null 2>&1 || true
  reap "$CASE_PID"
  [ "$(inbox_count "$CASE_STATE" allowance-resume)" -eq 1 ] \
    || fail "the same park was resumed more than once (found $(inbox_count "$CASE_STATE" allowance-resume) records)"
  pass "a parked worker past its reset is resumed by a steering message, exactly once per park"
}

test_watcher_never_messages_a_worker_whose_allowance_is_still_spent() {
  command -v jq >/dev/null 2>&1 \
    || fail "jq is missing, so the provider gate could not be exercised - this is not a pass"
  # Everything the resumable case has except the one thing that matters: the
  # provider still reports the account exhausted. A message sent here is consumed
  # for nothing and the worker parks again on the same turn.
  build_resumable_case allowance-spent spent
  launch_case_watcher "$CASE_DIR/watch.out"
  wait_for_exit "$CASE_PID" 100 \
    || { reap "$CASE_PID"; fail "the watcher never surfaced the park: $(cat "$CASE_OUT")"; }
  grep -Fq "parked on the account allowance" "$CASE_OUT" \
    || fail "the park was not surfaced at all, so this case did not reach the resume gate"
  [ "$(inbox_count "$CASE_STATE" allowance-spent)" -eq 0 ] \
    || fail "a worker whose allowance is still spent was messaged anyway"
  [ ! -e "$CASE_STATE/.allowance-resumed-$CASE_KEY" ] \
    || fail "a resume that never fired still recorded itself as spent for this episode"

  # Silence proves nothing on its own - code that resumes no one is also silent.
  # So the same fixture, the same worker and the same watcher are run again with
  # ONLY the provider's answer changed, and the message has to appear. The
  # provider gate is then the only difference between the two halves.
  FM_STATE_OVERRIDE="$CASE_STATE" "$DRAIN" > "$CASE_DIR/drain2.out" 2> "$CASE_DIR/drain2.err" || true
  ack_drain_err "$CASE_STATE" "$CASE_DIR/drain2.err" \
    || fail "could not acknowledge the allowance wake before flipping the provider"
  printf 'ready' > "$CASE_DIR/quota-verdict"
  launch_case_watcher "$CASE_DIR/watch2.out"
  wait_for_inbox "$CASE_STATE" allowance-spent 1 || true
  reap "$CASE_PID"
  [ "$(inbox_count "$CASE_STATE" allowance-spent)" -eq 1 ] \
    || fail "the same worker was still not resumed once the provider reported headroom, so the silence above was not the provider gate"
  pass "a parked worker whose allowance is still spent is not messaged at all, and is the moment it clears"
}

test_watcher_waits_for_the_recorded_reset_before_resuming() {
  local now
  command -v jq >/dev/null 2>&1 \
    || fail "jq is missing, so the provider gate could not be exercised - this is not a pass"
  # A park that has only just happened: its recorded reset is still an hour out.
  # The provider is told to say "ready" precisely so this case cannot pass on the
  # provider gate - the worker's own recorded reset is the only thing holding the
  # message back.
  now=$(date -u +%s)
  build_parked_case allowance-early parked "$PARKED_PANE_LINE" "$(( now + 3600 ))" "$now"
  printf 'ready' > "$CASE_DIR/quota-verdict"
  install_fake_quota "$CASE_DIR/fakebin" "$CASE_DIR/quota-verdict"
  launch_case_watcher "$CASE_DIR/watch.out"
  wait_for_exit "$CASE_PID" 100 \
    || { reap "$CASE_PID"; fail "the watcher never surfaced the fresh park: $(cat "$CASE_OUT")"; }
  [ "$(inbox_count "$CASE_STATE" allowance-early)" -eq 0 ] \
    || fail "a worker was messaged before the reset its own refusal record names"

  # And again with ONLY the recorded reset moved into the past, so the silence
  # above is attributable to that gate rather than to a resume path that never
  # runs in this fixture at all.
  FM_STATE_OVERRIDE="$CASE_STATE" "$DRAIN" > "$CASE_DIR/drain2.out" 2> "$CASE_DIR/drain2.err" || true
  ack_drain_err "$CASE_STATE" "$CASE_DIR/drain2.err" \
    || fail "could not acknowledge the allowance wake before moving the recorded reset"
  make_store "$CASE_DIR/store" "$CASE_WT" parked "$(( now - 3600 ))" "$(( now - 7200 ))" >/dev/null
  launch_case_watcher "$CASE_DIR/watch2.out"
  wait_for_inbox "$CASE_STATE" allowance-early 1 || true
  reap "$CASE_PID"
  [ "$(inbox_count "$CASE_STATE" allowance-early)" -eq 1 ] \
    || fail "the same worker was still not resumed once its recorded reset had passed, so the silence above was not the reset gate"
  pass "a park is not messaged until the reset its own refusal record names has passed"
}

test_pane_signal_reads_the_rendered_notice
test_pane_signal_is_bounded_to_the_prompt_region
test_record_signal_is_current_state_not_history
test_record_signal_stops_claiming_once_the_transcript_crossed_its_reset
test_unsupported_harness_never_parks
test_either_signal_alone_carries_the_verdict
test_transcript_must_belong_to_this_worktree
test_crew_state_reports_the_park_over_a_busy_verdict
test_crew_state_leaves_an_unparked_crew_alone
test_crew_state_stops_claiming_a_park_the_worker_has_worked_past
test_watcher_surfaces_a_park_it_would_otherwise_call_healthy
test_watcher_surfaces_a_park_from_the_transcript_alone
test_watcher_leaves_an_ordinary_worker_alone
test_watcher_surfaces_each_park_once
test_watcher_surfaces_a_pane_only_park_once_across_relaunches
test_watcher_resumes_a_parked_worker_whose_allowance_is_back
test_watcher_never_messages_a_worker_whose_allowance_is_still_spent
test_watcher_waits_for_the_recorded_reset_before_resuming
