#!/usr/bin/env bash
# tests/fm-progress-lib.test.sh - unit tests for the movement-evidence library
# (bin/fm-progress-lib.sh): the three-counter sample pair that separates a live
# worker on a long quiet step from a process that has stopped moving.
#
# Pure functions over captured text, so no backend, no pane, and no live spawn.
# The pane-triage consequences of each verdict are covered end to end in
# tests/fm-watch-triage.test.sh; what is pinned here is the verdict itself.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-progress-lib.sh"

STATE=$(fm_test_tmproot)/state
mkdir -p "$STATE"

# A capture the size the watcher really takes. The library splits a capture into
# a footer region and the rendered body above it, so a fixture shorter than the
# footer has no body at all - which is a property of the split, not of the pane,
# and would make every content assertion below vacuous.
capture() {  # <line>...
  local i
  for i in 1 2 3 4 5 6 7 8; do printf 'scrollback line %s\n' "$i"; done
  printf '%s\n' "$@"
}

# A capture whose given lines sit in the rendered body rather than the footer
# region, by padding below them. Where the footer is what moves, use capture.
capture_body() {  # <line>...
  local i
  for i in 1 2 3; do printf 'scrollback line %s\n' "$i"; done
  printf '%s\n' "$@"
  for i in 1 2 3 4 5 6; do printf 'chrome line %s\n' "$i"; done
}

# Two samples of one task, far enough apart to compare, with the record's
# timestamp pushed back so the pair is never inside the minimum gap.
observe_pair() {  # <id> <first-capture> <second-capture> [gap-secs]
  local id=$1 first=$2 second=$3 gap=${4:-60} path ts
  fm_progress_sample_clear "$STATE" "$id"
  fm_progress_observe "$STATE" "$id" "$first" > /dev/null
  path=$(fm_progress_sample_path "$STATE" "$id")
  ts=$(( $(date +%s) - gap ))
  [ ! -e "$path" ] || sed -i "s/ ts=[0-9]*/ ts=$ts/" "$path"
  fm_progress_observe "$STATE" "$id" "$second"
}

# Age the advance on record without touching anything else, so the ceiling can
# be tested at a real boundary rather than by waiting out a real one.
age_advance() {  # <id> <secs>
  local path stamp
  path=$(fm_progress_sample_path "$STATE" "$1")
  stamp=$(( $(date +%s) - $2 ))
  sed -i "s/ advanced_ts=[0-9]*/ advanced_ts=$stamp/" "$path"
}

# Age the ANCHOR, so the next observation clears the minimum gap and actually
# compares rather than reporting unknown and leaving the record alone.
age_anchor() {  # <id> <secs>
  local path stamp
  path=$(fm_progress_sample_path "$STATE" "$1")
  stamp=$(( $(date +%s) - $2 ))
  sed -i "s/ ts=[0-9]*/ ts=$stamp/" "$path"
}

# --- a first sample establishes nothing -------------------------------------

fm_progress_sample_clear "$STATE" first
[ "$(fm_progress_observe "$STATE" first 'Working... (12s)')" = unknown ] \
  || fail "one sample must never answer a question about movement"
pass "a first sample reports unknown: movement needs a pair"

[ "$(fm_progress_observe "$STATE" absent-id '')" = unknown ] \
  || fail "an empty capture with no prior sample must report unknown"
[ "$(fm_progress_observe "$STATE" '' 'Working... (12s)')" = unknown ] \
  || fail "an empty task id must report unknown rather than reading a stray path"
pass "an empty capture and an empty id both report unknown"

# --- the dead process: nothing moves ----------------------------------------

DEAD=$(capture 'esc to interrupt' '  Analysing the failure' 'Working... (41s) | 12.4k tokens')
[ "$(observe_pair dead "$DEAD" "$DEAD")" = still ] \
  || fail "two identical captures must report still: no counter moved"
pass "an unchanged pane reports still - the only verdict that admits a wedge"

# --- the live worker on a long quiet step: only the clock moves -------------

QUIET_A=$(capture 'esc to interrupt' '  Analysing the failure' 'Working... (41s) | 12.4k tokens')
QUIET_B=$(capture 'esc to interrupt' '  Analysing the failure' 'Working... (101s) | 12.4k tokens')
[ "$(observe_pair quiet "$QUIET_A" "$QUIET_B")" = alive ] \
  || fail "a moving turn timer alone must report alive, never advanced"
pass "a ticking turn timer alone reports alive: proof of life, not of progress"

# --- forward progress: the token counter moves ------------------------------

TOK_A=$(capture 'esc to interrupt' '  Analysing the failure' 'Working... (41s) | 12.4k tokens')
TOK_B=$(capture 'esc to interrupt' '  Analysing the failure' 'Working... (101s) | 18.9k tokens')
[ "$(observe_pair tokens "$TOK_A" "$TOK_B")" = advanced ] \
  || fail "a moving token counter must report advanced"
[ "$(fm_progress_advanced_age "$STATE" tokens)" != - ] \
  || fail "a moving token counter must record the advance"
pass "a moving token counter reports advanced and records the advance"

# --- new rendered content is proof of life, not of progress ------------------

BODY_A=$(capture_body '  Reading the watcher' '  Analysing the failure')
BODY_B=$(capture_body '  Reading the watcher' '  Analysing the failure' '  Found the wedge timer')
[ "$(observe_pair body "$BODY_A" "$BODY_B")" = alive ] \
  || fail "new rendered content with a frozen footer must report alive, never advanced or still"
[ "$(fm_progress_advanced_age "$STATE" body)" = - ] \
  || fail "new rendered content latched an advance"
pass "new rendered content reports alive even when the whole footer is frozen"

# The captain's measured case: an analysis pass advancing 39 -> 60 of 99 past the
# one-hour bound. Its measurable progress is the token count moving, which is what
# the pass reads as advanced through.
PASS_A=$(capture '  [39/99] analysing' 'Working... (3601s) | 10.1k tokens')
PASS_B=$(capture '  [60/99] analysing' 'Working... (3661s) | 14.8k tokens')
[ "$(observe_pair analysis "$PASS_A" "$PASS_B")" = advanced ] \
  || fail "a counting analysis pass past the turn bound must report advanced"
pass "an analysis pass whose token count climbs reports advanced past the one-hour bound"

# --- a hung foreground command is never progress ------------------------------

# The job the one-hour bound exists to catch. On claude 2.1.278 the pane of a
# turn blocked on one foreground command moves on most polls - the footer spinner
# glyph cycles, the footer and body timers tick, the running tool's header bullet
# blinks, and the body timer changes shape at each minute - while the token count
# stays static.
fmt_secs() {  # <secs>
  if [ "$1" -lt 60 ]; then printf '%ss' "$1"; else printf '%sm %ss' "$(( $1 / 60 ))" "$(( $1 % 60 ))"; fi
}

hung_pane() {  # <secs> <glyph> <bullet> [tokens]
  local i
  for i in 1 2 3 4 5 6 7 8; do printf 'scrollback line %s\n' "$i"; done
  printf '%s Reading any waiting inbox messages · %s\n' "$3" "$(fmt_secs "$1")"
  printf '  ⎿ $ timeout 330 tail -f /dev/null (%s)\n\n' "$(fmt_secs "$1")"
  printf '%s Boondoggling… (%s · ↓ %s tokens)\n' "$2" "$(fmt_secs "$1")" "${4:-391}"
  printf '%s\n' '--------' '> ' '--------' 'permissions line'
}

# The watcher pins no locale, so the same series is observed under the UTF-8
# locale and the C locale, where a multibyte character is several bytes and a
# pattern that treats it as one is what would read the ticking timer as a
# token count.
check_hung_series() {  # <locale> <id>
  local loc=$1 id=$2 secs verdict advanced=0 moved=0
  local -a bullets=('●' ' ') glyphs=('✢' '✻' '✶' '✳')
  fm_progress_sample_clear "$STATE" "$id"
  LC_ALL=$loc fm_progress_observe "$STATE" "$id" "$(hung_pane 19 '✢' '●')" > /dev/null
  for secs in 24 30 41 47 53 59 61 67 73 79 85 91 97 103; do
    age_anchor "$id" 60
    verdict=$(LC_ALL=$loc fm_progress_observe "$STATE" "$id" \
      "$(hung_pane "$secs" "${glyphs[$(( secs % 4 ))]}" "${bullets[$(( secs % 2 ))]}")")
    [ "$verdict" != advanced ] || advanced=1
    [ "$verdict" != alive ] || moved=$(( moved + 1 ))
  done
  [ "$advanced" -eq 0 ] \
    || fail "a hung foreground command with a static token count read advanced under $loc"
  [ "$moved" -gt 0 ] \
    || fail "the hung pane never read alive under $loc, so the fixture proved nothing"
  [ "$(fm_progress_advanced_age "$STATE" "$id")" = - ] \
    || fail "a hung foreground command latched an advance under $loc"
  age_anchor "$id" 60
  [ "$(LC_ALL=$loc fm_progress_observe "$STATE" "$id" "$(hung_pane 109 '✢' '●' 512)")" = advanced ] \
    || fail "a real token-count change on the hung pane did not read advanced under $loc"
  [ "$(fm_progress_advanced_age "$STATE" "$id")" != - ] \
    || fail "a real token-count change did not record the advance under $loc"
}

check_hung_series en_US.UTF-8 hung
check_hung_series C hung-c
pass "a hung foreground command with a static token count never reads advanced and never latches, in the UTF-8 and C locales"

# --- a counter appearing or disappearing is not progress ----------------------

NOTOK=$(capture 'esc to interrupt' 'Working... (41s)')
WITHTOK=$(capture 'esc to interrupt' 'Working... (101s) | 12.4k tokens')
[ "$(observe_pair tok-appears "$NOTOK" "$WITHTOK")" = alive ] \
  || fail "a token counter appearing between samples must not read advanced"
[ "$(fm_progress_advanced_age "$STATE" tok-appears)" = - ] \
  || fail "a token counter appearing latched an advance"
[ "$(observe_pair tok-vanishes "$WITHTOK" "$NOTOK")" = alive ] \
  || fail "a token counter disappearing between samples must not read advanced"
[ "$(fm_progress_advanced_age "$STATE" tok-vanishes)" = - ] \
  || fail "a token counter disappearing latched an advance"
pass "a token counter appearing or disappearing between samples reads alive and latches nothing"

# --- an unreadable surface is not stillness ---------------------------------

BLANK='   '
[ "$(observe_pair blank "$BLANK" "$BLANK")" = unknown ] \
  || fail "two captures rendering no counter at all must report unknown, not still"
pass "a surface rendering no counter reports unknown: stillness is observed, never inferred"

# --- a transient footer line is not content movement -------------------------

# A harness notice that appears or expires inside the footer region slides the
# whole capture by one line, so a line crosses between footer and body though no
# rendered text moved. The shape is the one a live claude pane produced: the
# notice sits above the input box, and the turn summary above it is a footer row
# in one capture and a body row in the other.
notice_pane() {  # <with-notice: yes|no>
  local i
  for i in 1 2 3 4 5 6 7 8; do printf 'scrollback line %s\n' "$i"; done
  printf '  Worked for 11s\n'
  [ "$1" != yes ] || printf '                    a transient harness notice\n'
  printf '%s\n' '--------' '> ' '--------' 'model, context 12%' 'permissions line'
}

[ "$(observe_pair notice-gone "$(notice_pane yes)" "$(notice_pane no)")" = alive ] \
  || fail "a footer notice expiring must not read as rendered progress"
[ "$(observe_pair notice-new "$(notice_pane no)" "$(notice_pane yes)")" = alive ] \
  || fail "a footer notice appearing must not read as rendered progress"
pass "a transient footer line appearing or expiring reads alive, never advanced"

# The same pane with genuinely new output above the footer is still proof of life.
NEW_LINE=$(notice_pane no)
NEW_LINE=${NEW_LINE/'scrollback line 8'/$'scrollback line 8\n  wrote the summary file'}
[ "$(observe_pair new-line "$(notice_pane no)" "$NEW_LINE")" = alive ] \
  || fail "a genuinely new rendered line must read alive, never still"
pass "a rendered line that appeared nowhere in the previous capture reads alive"

# --- a blank capture is not an observation -----------------------------------

fm_progress_sample_clear "$STATE" blanked
fm_progress_observe "$STATE" blanked "$DEAD" > /dev/null
age_anchor blanked 60
before=$(cat "$(fm_progress_sample_path "$STATE" blanked)")
[ "$(fm_progress_observe "$STATE" blanked '  ')" = unknown ] \
  || fail "a blank capture must read unknown"
[ "$(cat "$(fm_progress_sample_path "$STATE" blanked)")" = "$before" ] \
  || fail "a blank capture must not replace the anchor"
[ "$(fm_progress_observe "$STATE" blanked "$DEAD")" = still ] \
  || fail "the real capture after a blank one must compare against the real anchor, not read advanced"
[ "$(fm_progress_advanced_age "$STATE" blanked)" = - ] \
  || fail "a blank capture latched an advance"
pass "a real sample, a blank capture, then the same real capture never reads advanced"

# --- a record from before the line set has no comparable prior ---------------

counters=$(fm_progress_counters "$DEAD")
old_footer=${counters%%$'\t'*}
old_tokens=${counters#*$'\t'}; old_tokens=${old_tokens%%$'\t'*}
printf 'v1 ts=%s verdict=still footer=%s tokens=%s content=deadbeef advanced_ts=-\n' \
  "$(( $(date +%s) - 60 ))" "$old_footer" "$old_tokens" \
  > "$(fm_progress_sample_path "$STATE" oldfmt)"
[ "$(fm_progress_observe "$STATE" oldfmt "$(capture_body '  something entirely new')")" = unknown ] \
  || fail "a record without a line set must read unknown, never advanced"
[ "$(fm_progress_advanced_age "$STATE" oldfmt)" = - ] \
  || fail "a record without a line set latched an advance"
pass "a record without a line set has no comparable prior and reads unknown"

# A harness that renders only prose still supplies the content counter, so its
# stillness IS measured and must not degrade to unknown.
PROSE=$(capture '  waiting for the reviewer')
[ "$(observe_pair prose "$PROSE" "$PROSE")" = still ] \
  || fail "a prose-only pane has a readable content counter and must report still"
pass "a prose-only pane still reports still: its content counter is readable"

# --- the pair is established once, by one caller, per poll ------------------

fm_progress_sample_clear "$STATE" once
fm_progress_observe "$STATE" once "$QUIET_A" > /dev/null
path=$(fm_progress_sample_path "$STATE" once)
sed -i "s/ ts=[0-9]*/ ts=$(( $(date +%s) - 60 ))/" "$path"
[ "$(fm_progress_observe "$STATE" once "$QUIET_B")" = alive ] || fail "setup: expected alive"
before=$(cat "$path")
[ "$(fm_progress_observe "$STATE" once "$QUIET_B")" = unknown ] \
  || fail "a second observation inside one poll must report unknown"
[ "$(cat "$path")" = "$before" ] \
  || fail "a second observation inside one poll must not re-anchor the pair"
[ "$(fm_progress_verdict "$STATE" once)" = alive ] \
  || fail "the pure read must return the verdict the completed observation established"
pass "a second observation inside one poll reports unknown, leaves the record, and the pure read still answers alive"

# --- a stale anchor answers nothing about this quiet stretch ----------------

fm_progress_sample_clear "$STATE" stale
fm_progress_observe "$STATE" stale "$DEAD" > /dev/null
path=$(fm_progress_sample_path "$STATE" stale)
sed -i "s/ ts=[0-9]*/ ts=$(( $(date +%s) - FM_PROGRESS_MAX_GAP_SECS - 60 ))/" "$path"
[ "$(fm_progress_observe "$STATE" stale "$DEAD")" = unknown ] \
  || fail "a sample older than the maximum gap must be discarded, not compared"
pass "a sample past the maximum gap reports unknown and re-anchors"

# --- a record from an unrelated episode licenses nothing ----------------------

observe_pair aged "$DEAD" "$DEAD" > /dev/null
[ "$(fm_progress_verdict "$STATE" aged)" = still ] \
  || fail "setup: expected a fresh still record"
age_anchor aged $(( FM_PROGRESS_MAX_GAP_SECS + 60 ))
[ "$(fm_progress_verdict "$STATE" aged)" = unknown ] \
  || fail "a verdict older than the maximum gap must read unknown through the pure read"
pass "the pure read reports unknown for a verdict older than the maximum gap"

# --- the pure read licenses nothing without a record ------------------------

fm_progress_sample_clear "$STATE" nored
[ "$(fm_progress_verdict "$STATE" nored)" = unknown ] \
  || fail "an absent record must read unknown"
printf 'garbage\n' > "$(fm_progress_sample_path "$STATE" nored)"
[ "$(fm_progress_verdict "$STATE" nored)" = unknown ] \
  || fail "a malformed record must read unknown"
printf 'v1 ts=%s verdict=busy elapsed=a tokens=b lines=c\n' "$(date +%s)" \
  > "$(fm_progress_sample_path "$STATE" nored)"
[ "$(fm_progress_verdict "$STATE" nored)" = unknown ] \
  || fail "a record carrying an unrecognised verdict must read unknown"
pass "an absent, malformed, or unrecognised record reads unknown and licenses nothing"

# --- counters are compared, never interpreted -------------------------------

# Two harnesses rendering the same movement in different notations must both
# read as movement; neither format is modelled, so neither can go quietly inert.
# A liveness counter that modelled the timer's notation would answer `still` for
# any harness whose notation it did not recognise - a dead-process verdict for a
# live worker, which is the expensive direction. The footer digest models none of
# them, so an unrecognised status line still reads as movement.
[ "$(observe_pair clockfmt "$(capture 'idle' '1:23')" "$(capture 'idle' '1:24')")" = alive ] \
  || fail "a clock-form timer must be readable as movement"
[ "$(observe_pair oddfmt "$(capture 'idle' 'phase 2 of 7 ~~ 1.2 kilotok')" \
  "$(capture 'idle' 'phase 3 of 7 ~~ 3.4 kilotok')")" = alive ] \
  || fail "a footer in a notation nothing models must still read as movement, never as stillness"
pass "a clock-form timer and a footer notation nothing models both read as movement"

# The progress counter is the one that knows a notation. Where it recognises the
# token counter the verdict rises to advanced; where it does not, the test above
# pins the degraded answer at alive, never at still.
[ "$(observe_pair arrowfmt "$(capture 'idle' '  ↑ 1.2k')" "$(capture 'idle' '  ↑ 3.4k')")" = advanced ] \
  || fail "an arrow-form context counter must be readable as progress"
pass "an arrow-form context counter reads as advanced"

# --- the advance latch ------------------------------------------------------

# A wedge is asked about a whole quiet window, while one sample pair only ever
# describes the gap between two polls. A worker rendering more slowly than the
# poll interval is therefore `alive` on most pairs and `advanced` on a few, so
# the last pair alone cannot answer the question the wedge timer is asking.
# The latch is what carries the answer across the window.
observe_pair latched "$(capture 'step 1' '  ↑ 1.2k')" "$(capture 'step 2' '  ↑ 3.4k')" > /dev/null
[ "$(fm_progress_verdict "$STATE" latched)" = advanced ] \
  || fail "the fixture did not establish an advance to latch"
age_anchor latched 60
fm_progress_observe "$STATE" latched "$(capture 'step 2' '  ↑ 3.4k xx')" > /dev/null
[ "$(fm_progress_verdict "$STATE" latched)" = alive ] \
  || fail "a footer-only redraw after an advance must read alive"
FM_PROGRESS_LATCH_MAX_SECS=240 fm_progress_advancing "$STATE" latched \
  || fail "an advance moments old stopped answering the wedge question after one alive poll"
pass "a measured advance survives the alive polls between it and the threshold"

# And the ceiling: past the window being judged, the same advance answers
# nothing. Without this the latch trades a false alarm for a permanent silence,
# which is the expensive direction the whole change exists to close.
age_advance latched 241
FM_PROGRESS_LATCH_MAX_SECS=240 fm_progress_advancing "$STATE" latched \
  && fail "an advance older than the window being judged still deferred a wedge"
age_advance latched 239
FM_PROGRESS_LATCH_MAX_SECS=240 fm_progress_advancing "$STATE" latched \
  || fail "an advance inside the window being judged stopped deferring"
pass "the latch expires a bounded time after the movement itself stops"

# A record written before the field existed carries no advance, so it defers
# nothing. Absence of evidence stays absence of evidence in this direction too.
printf 'v1 ts=%s verdict=advanced footer=a tokens=b lines=c\n' "$(date +%s)" \
  > "$(fm_progress_sample_path "$STATE" precompat)"
[ "$(fm_progress_advanced_age "$STATE" precompat)" = - ] \
  || fail "a record with no advance on it reported one"
FM_PROGRESS_LATCH_MAX_SECS=240 fm_progress_advancing "$STATE" precompat \
  && fail "a record written before the latch existed deferred a wedge"
pass "a pre-latch record carries no advance and defers nothing"

# Zero disables the latch, leaving exactly the single-pair question every caller
# asked before it existed - the setting that takes the new behaviour back out.
observe_pair unlatched "$(capture 'step 1' '  ↑ 1.2k')" "$(capture 'step 2' '  ↑ 3.4k')" > /dev/null
age_anchor unlatched 60
fm_progress_observe "$STATE" unlatched "$(capture 'step 2' '  ↑ 3.4k xx')" > /dev/null
FM_PROGRESS_LATCH_MAX_SECS=0 fm_progress_advancing "$STATE" unlatched \
  && fail "a zero ceiling still answered from the latch rather than the last pair"
pass "a zero ceiling restores the pre-latch single-pair question"

fm_test_cleanup
