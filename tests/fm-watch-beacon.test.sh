#!/usr/bin/env bash
# Tests for the watcher liveness beacon's freshness across one poll cycle.
#
# The guard grace that every beacon reader derives (fm_poll_derived_grace) is
# sized for a beacon that ages at most one poll cadence between touches. A poll
# cycle's own body is serial and unbounded in aggregate - each registered state
# check may burn FM_CHECK_TIMEOUT, the signal scan lingers FM_SIGNAL_GRACE, and
# every live window is captured in turn - so a beacon touched only at the top of
# the cycle can age far past that grace while the watcher is working normally.
# These cases pin the beacon's age against the work the cycle actually does.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-beacon)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

# register_stalling_check <home> <id> <seconds>
# A registered custom check that sleeps past its timeout and prints nothing, so
# the sweep spends the full FM_CHECK_TIMEOUT on it and wakes nobody.
register_stalling_check() {
  local home=$1 id=$2 seconds=$3
  cat > "$home/state/$id.check.sh" <<SH
#!/usr/bin/env bash
sleep $seconds
SH
  chmod 0700 "$home/state/$id.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" "$id" >/dev/null \
    || fail "could not register stalling check $id"
}

# max_beacon_age <beacon> <pidfile> <deadline-epoch>
# Sample the beacon's age until the watched process exits or the deadline
# passes, and print the largest age observed. A beacon that does not exist yet
# is not counted: the watcher creates it on its first cycle.
max_beacon_age() {
  local beacon=$1 pidfile=$2 deadline=$3 worst=0 now mtime age pid
  while :; do
    now=$(date +%s)
    [ "$now" -lt "$deadline" ] || break
    pid=$(cat "$pidfile" 2>/dev/null || true)
    [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && break
    if mtime=$(stat -c %Y "$beacon" 2>/dev/null || stat -f %m "$beacon" 2>/dev/null); then
      age=$((now - mtime))
      [ "$age" -le "$worst" ] || worst=$age
    fi
    sleep 0.2
  done
  printf '%s\n' "$worst"
}

# beacon_budget <longest-bounded-operation-seconds>
# The legitimate worst age is the longest single bounded operation plus one
# poll cadence (FM_POLL=1), plus one second for the integer-second mtime. Add
# three seconds of scheduler slack for a loaded machine. The unfixed watcher
# measured 9-10s, which is more than twice this budget.
beacon_budget() {
  printf '%s\n' $(( $1 + 1 + 1 + 3 ))
}

test_beacon_stays_fresh_across_a_slow_check_sweep() {
  local home beacon pidfile worst budget i
  home=$(make_home slow-checks)
  beacon="$home/state/.last-watcher-beat"
  pidfile="$home/checkpoint.pid"

  # Four checks that each burn the whole two-second timeout: one sweep is eight
  # seconds of serial work inside a single poll cycle.
  for i in 1 2 3 4; do
    register_stalling_check "$home" "stall$i" 30
  done

  (
    FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 \
      FM_CHECK_TIMEOUT=2 "$CHECKPOINT" --seconds 20 >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$pidfile"
    wait
  ) &
  worst=$(max_beacon_age "$beacon" "$pidfile" "$(( $(date +%s) + 20 ))")
  wait 2>/dev/null || true

  assert_present "$beacon" "watcher never created its liveness beacon"
  # One bounded check plus the poll cadence is the whole legitimate window; the
  # sweep's four checks must not accumulate into the beacon's age.
  budget=$(beacon_budget 2)
  [ "$worst" -le "$budget" ] \
    || fail "beacon aged ${worst}s during a slow check sweep (budget ${budget}s): a working watcher reads as dead to its own guard"
  pass "beacon stays fresh through a check sweep longer than the guard grace"
}

test_beacon_stays_fresh_across_the_signal_grace_linger() {
  local home beacon pidfile worst budget
  home=$(make_home signal-linger)
  beacon="$home/state/.last-watcher-beat"
  pidfile="$home/checkpoint.pid"

  (
    sleep 2
    printf 'working: synthetic signal\n' > "$home/state/demo.status"
  ) &

  (
    FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=8 FM_CHECK_INTERVAL=999999 \
      "$CHECKPOINT" --seconds 20 >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$pidfile"
    wait
  ) &
  worst=$(max_beacon_age "$beacon" "$pidfile" "$(( $(date +%s) + 20 ))")
  wait 2>/dev/null || true

  assert_present "$beacon" "watcher never created its liveness beacon"
  budget=$(beacon_budget 1)
  [ "$worst" -le "$budget" ] \
    || fail "beacon aged ${worst}s across the signal-grace linger (budget ${budget}s): a working watcher reads as dead to its own guard"
  pass "beacon stays fresh across the signal-coalescing linger"
}

test_beacon_stays_fresh_across_a_slow_check_sweep
test_beacon_stays_fresh_across_the_signal_grace_linger
