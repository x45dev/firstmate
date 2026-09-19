#!/usr/bin/env bash
# Behavior tests for tests/lib.sh's shared fixture-tempdir helper
# (fm_test_tmproot / fm_test_cleanup / fm_test_reap_orphans) and its bounded
# process stop (fm_test_stop, and wait_for_exit in tests/wake-helpers.sh).
#
# The near-universal call pattern across this suite is
# `TMP_ROOT=$(fm_test_tmproot prefix)`, which forks a subshell to capture the
# function's stdout. These tests spawn real, separate bash processes that use
# that exact pattern and assert the fixture root is actually gone once the
# owning process's guarded teardown has run - on a normal exit and on a
# terminating signal - plus that a stale marked fixture from a killed prior
# run gets reaped on the next source. Nothing here inspects tests/lib.sh's
# source text; it only observes filesystem state around the real helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/tests/lib.sh"

test_fixture_root_gone_after_normal_exit() {
  local child_out child_dir
  child_out=$(bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-exit)
    printf "%s\n" "$d"
    if [ -d "$d" ]; then printf "mid:present\n"; else printf "mid:missing\n"; fi
  ')
  child_dir=$(printf '%s\n' "$child_out" | sed -n '1p')
  assert_contains "$child_out" "mid:present" \
    "the fixture root was not present while its owning process was still alive"
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived its owning process's normal exit"
  pass "fm_test_tmproot cleans up its fixture root on normal exit"
}

test_fixture_root_gone_after_sigterm() {
  local harness dirfile child_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-sigterm-harness)
  dirfile="$harness/child-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-term)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the child never published its fixture root before the wait timed out"
  child_dir=$(cat "$dirfile")
  assert_present "$child_dir" "the child's fixture root did not exist before it was signaled"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived SIGTERM to its owning process"
  pass "fm_test_tmproot cleans up its fixture root on SIGTERM"
}

test_cleanup_registry_resists_precreation() {
  local harness shared_tmp victim
  harness=$(fm_test_tmproot fm-test-cleanup-registry-harness)
  shared_tmp="$harness/shared-tmp"
  victim="$harness/victim"
  mkdir -p "$shared_tmp" "$victim"

  TMPDIR="$shared_tmp" bash -c '
    printf "%s\n" "$1" > "$TMPDIR/.fm-test-cleanup.$$"
    . "$2"
  ' _ "$victim" "$LIB"

  assert_present "$victim" \
    "a precreated predictable cleanup registry injected an arbitrary deletion target"
  pass "the cleanup registry cannot be injected through path precreation"
}

test_fixture_registration_failure_rolls_back_root() {
  local harness failure_tmp registry_dir output leaked_root
  harness=$(fm_test_tmproot fm-test-cleanup-registration-harness)
  failure_tmp="$harness/tmp"
  registry_dir="$harness/registry-dir"
  mkdir -p "$failure_tmp" "$registry_dir"

  if output=$(TMPDIR="$failure_tmp" FM_TEST_CLEANUP_REGISTRY="$registry_dir" \
    fm_test_tmproot fm-test-cleanup-registration-failure 2>/dev/null); then
    fail "fm_test_tmproot succeeded after its cleanup registry rejected registration"
  fi
  [ -z "$output" ] || fail "fm_test_tmproot published an unregistered fixture root"
  for leaked_root in "$failure_tmp"/fm-test-cleanup-registration-failure.*; do
    [ ! -e "$leaked_root" ] || fail "fm_test_tmproot leaked a root after registration failed"
  done
  pass "failed fixture registration rolls back the new root"
}

test_orphan_sweep_respects_fixture_ownership() {
  local harness dirfile active_dir stale_dir fresh_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-orphan-harness)
  dirfile="$harness/active-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-active)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the active child never published its fixture root before the wait timed out"
  active_dir=$(cat "$dirfile")
  touch -t 202001010000 "$active_dir/.fm-test-fixture"

  stale_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-stale.XXXXXX")
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"
  fresh_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-fresh.XXXXXX")
  : > "$fresh_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
  '

  assert_absent "$stale_dir" \
    "a stale fixture root whose PID was reused by another process was not reaped"
  assert_present "$active_dir" \
    "the orphan reaper removed an old fixture root whose owning process was still alive"
  assert_present "$fresh_dir" \
    "the orphan reaper removed a fresh marked fixture root it does not own yet"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$active_dir" \
    "the active fixture root survived its owning process's teardown"
  rm -rf "$fresh_dir"
  pass "the orphan sweep reaps only old fixtures without a live owner"
}

test_orphan_sweep_reaps_read_only_package_tree() {
  local stale_dir package_dir
  stale_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-read-only.XXXXXX")
  package_dir="$stale_dir/packages/extension"
  mkdir -p "$package_dir"
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  printf 'installed package\n' > "$package_dir/entrypoint.py"
  chmod -R a-w "$stale_dir/packages"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "$1"
  ' _ "$LIB"

  assert_absent "$stale_dir" \
    "the orphan reaper left a stale fixture containing a read-only package tree"
  pass "the orphan sweep reaps read-only package fixtures"
}

# --- bounded process stop ---------------------------------------------------
#
# The fixtures below stand in for a watcher that loses a TERM. The real loss is
# a bash race (see fm_test_stop in tests/lib.sh) that strikes about one signal
# in a few hundred, far too rarely to assert on, so this fixture swallows its
# first TERM every time and exits on the second. Each case runs in its own child
# bash bounded from outside, because a stop that regresses to one TERM and a bare
# wait never returns, and a hung case must fail here rather than hang the suite.

# shellcheck disable=SC2016 # Expanded by the fixture or case bash that runs it.
STOP_FIXTURE_SWALLOWS_FIRST_TERM='n=0
trap '\''n=$((n + 1)); [ "$n" -lt 2 ] || exit 143'\'' TERM
printf "%s\n" "$$" > "$1"
while :; do sleep 0.1; done'

# shellcheck disable=SC2016 # Expanded by the fixture or case bash that runs it.
STOP_FIXTURE_IGNORES_TERM='trap "" TERM
printf "%s\n" "$$" > "$1"
while :; do sleep 0.1; done'

# The body every case runs: start <fixture> in the background, wait for it to
# arm its trap, then run <stop-command> against its pid and report the outcome.
# shellcheck disable=SC2016 # Expanded by the fixture or case bash that runs it.
STOP_CASE='. "$1"
bash -c "$3" _ "$2" &
pid=$!
tries=0
while [ ! -s "$2" ] && [ "$tries" -lt 100 ]; do sleep 0.05; tries=$((tries + 1)); done
[ -s "$2" ] || { echo "fixture never armed"; exit 3; }
start=$SECONDS
rc=0
eval "$4" || rc=$?
printf "rc=%s elapsed=%s\n" "$rc" "$((SECONDS - start))"
if kill -0 "$pid" 2>/dev/null; then echo fixture=alive; else echo fixture=gone; fi'

# run_stop_case <dir> <library> <fixture> <stop-command>
# Leaves the case's stdout, stderr, and exit status in <dir>/out, <dir>/err, and
# STOP_CASE_RC; STOP_CASE_RC is 124 when the case outran its outer bound.
run_stop_case() {
  local dir=$1 library=$2 fixture=$3 stop=$4 case_pid ticks=0 fixture_pid
  mkdir -p "$dir"
  FM_TEST_STOP_RETERM_SECONDS=1 FM_TEST_STOP_BOUND_SECONDS="${STOP_CASE_BOUND:-10}" \
    FM_TEST_SKIP_ORPHAN_REAP=1 \
    bash -c "$STOP_CASE" _ "$library" "$dir/fixture.pid" "$fixture" "$stop" \
    > "$dir/out" 2> "$dir/err" &
  case_pid=$!
  while kill -0 "$case_pid" 2>/dev/null && [ "$ticks" -lt 150 ]; do
    sleep 0.1
    ticks=$((ticks + 1))
  done
  if kill -0 "$case_pid" 2>/dev/null; then
    kill -KILL "$case_pid" 2>/dev/null || true
    wait "$case_pid" 2>/dev/null || true
    STOP_CASE_RC=124
  else
    STOP_CASE_RC=0
    wait "$case_pid" || STOP_CASE_RC=$?
  fi
  fixture_pid=$(cat "$dir/fixture.pid" 2>/dev/null || true)
  case "$fixture_pid" in
    ''|*[!0-9]*) ;;
    *) kill -KILL "$fixture_pid" 2>/dev/null || true ;;
  esac
}

test_stop_outlasts_a_lost_first_term() {
  local harness
  harness=$(fm_test_tmproot fm-test-stop-lost-term)
  # shellcheck disable=SC2016 # Expanded by the fixture or case bash that runs it.
  run_stop_case "$harness/case" "$LIB" "$STOP_FIXTURE_SWALLOWS_FIRST_TERM" \
    'fm_test_stop "$pid" "the fixture"'
  [ "$STOP_CASE_RC" -ne 124 ] \
    || fail "fm_test_stop hung on a process that lost its first TERM"
  [ "$STOP_CASE_RC" -eq 0 ] \
    || fail "fm_test_stop failed a process that exits on its second TERM: $(cat "$harness/case/err")"
  assert_contains "$(cat "$harness/case/out")" "rc=0" \
    "fm_test_stop did not return success once the process stopped"
  assert_contains "$(cat "$harness/case/out")" "fixture=gone" \
    "fm_test_stop returned while the process that lost its first TERM was still running"
  assert_not_contains "$(cat "$harness/case/err")" "not ok" \
    "fm_test_stop reported a failure for a process that stopped within its bound"
  pass "fm_test_stop stops and reaps a process that lost its first TERM"
}

test_wait_for_exit_outlasts_a_lost_first_term() {
  local harness
  harness=$(fm_test_tmproot fm-test-wait-for-exit-lost-term)
  # shellcheck disable=SC2016 # Expanded by the fixture or case bash that runs it.
  run_stop_case "$harness/case" "$ROOT/tests/wake-helpers.sh" "$STOP_FIXTURE_SWALLOWS_FIRST_TERM" \
    'wait_for_exit "$pid" 5'
  [ "$STOP_CASE_RC" -ne 124 ] \
    || fail "wait_for_exit hung past its limit on a process that lost its first TERM"
  assert_contains "$(cat "$harness/case/out")" "rc=124" \
    "wait_for_exit did not report its limit for a process that had to be stopped: $(cat "$harness/case/out")"
  assert_contains "$(cat "$harness/case/out")" "fixture=gone" \
    "wait_for_exit returned while the process that lost its first TERM was still running"
  pass "wait_for_exit stops a process that lost its first TERM instead of waiting on it forever"
}

test_stop_fails_loudly_on_a_process_that_ignores_term() {
  local harness err pid
  harness=$(fm_test_tmproot fm-test-stop-ignored-term)
  # shellcheck disable=SC2016 # Expanded by the fixture or case bash that runs it.
  STOP_CASE_BOUND=1 run_stop_case "$harness/case" "$LIB" "$STOP_FIXTURE_IGNORES_TERM" \
    'fm_test_stop "$pid" "the TERM-ignoring fixture"'
  err=$(cat "$harness/case/err")
  [ "$STOP_CASE_RC" -ne 124 ] \
    || fail "fm_test_stop hung on a process that ignores TERM instead of failing at its bound"
  [ "$STOP_CASE_RC" -eq 1 ] \
    || fail "fm_test_stop did not fail the test when a process outlived its bound (exit $STOP_CASE_RC): $err"
  assert_contains "$err" "not ok - the TERM-ignoring fixture (pid " \
    "fm_test_stop's failure did not name what it was waiting for: $err"
  assert_contains "$err" "did not stop within 1s of TERM: bash -c" \
    "fm_test_stop's failure did not carry the stuck process's command line: $err"
  assert_contains "$err" "outlived TERM for 1s; process tree:" \
    "fm_test_stop did not print the stuck process tree before failing: $err"
  assert_contains "$err" "sleep 0.1" \
    "fm_test_stop's process tree did not include the stuck process's child: $err"
  pid=$(cat "$harness/case/fixture.pid")
  if kill -0 "$pid" 2>/dev/null && [ "$(ps -o stat= -p "$pid" 2>/dev/null | cut -c1)" != Z ]; then
    fail "fm_test_stop failed the test but left the TERM-ignoring process running"
  fi
  pass "fm_test_stop kills a process that ignores TERM at its bound and fails naming it"
}

test_fixture_root_gone_after_normal_exit
test_fixture_root_gone_after_sigterm
test_cleanup_registry_resists_precreation
test_fixture_registration_failure_rolls_back_root
test_orphan_sweep_respects_fixture_ownership
test_orphan_sweep_reaps_read_only_package_tree
test_wait_for_exit_outlasts_a_lost_first_term
test_stop_outlasts_a_lost_first_term
test_stop_fails_loudly_on_a_process_that_ignores_term
