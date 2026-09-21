#!/usr/bin/env bash
# tests/fm-progress-live-e2e.test.sh - the live movement-evidence guard
# (live-harness-optin family).
#
# bin/fm-progress-lib.sh decides whether a quiet pane holds a live worker or a
# process that has stopped, and it decides it from what the harness VENDOR
# renders: a footer region, a context or token counter inside it, and the body
# above it. A stub agent can only confirm the assumption already written into
# the stub, so per .agents/skills/firstmate-coding-guidelines the verdict is
# proven here against every INSTALLED verified harness, in BOTH directions:
#
#   working   two samples taken while a real turn runs must NOT read `still`,
#             because `still` is the only verdict that admits a wedge and a
#             false one costs a live worker its supervision;
#   settled   two samples of the same pane once the turn has ended and the
#             rendering has stopped MUST read `still`, or the check has gone
#             inert and nothing would ever catch a real hang.
#
# The library deliberately models no harness's notation: the footer digest
# carries liveness whatever the footer says, and only the progress counter
# knows a format. So a harness whose footer this release cannot parse degrades
# to `alive` here, never to `still`, and that is a pass - the failure this
# guard exists to catch is the `still` one.
#
# Run explicitly with FM_PROGRESS_LIVE_E2E=1. This spends a small number of
# real model tokens per installed harness (one short turn each) - authorized by
# the harness-dependent-checks rule. An absent harness is reported explicitly
# and skipped; a run that verified nothing fails rather than passing vacuously.
# Restrict with FM_PROGRESS_LIVE_HARNESSES="claude pi ..." when needed, and tune
# the per-harness turn budget with FM_PROGRESS_LIVE_TIMEOUT (seconds, default
# 240). Record the dated per-harness result in
# docs/verification/runtime-backends.md ("Rendered movement evidence").
#
# Folder trust: harnesses launch with the repo root as cwd, which the
# operator's machine has normally already trusted; a trust dialog is a real
# unready state and correctly fails that harness's check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_PROGRESS_LIVE_E2E tmux

unset NO_MISTAKES_GATE

SOCKET="fm-progress-live-$$"
SESSION="proglive"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-progress-live.XXXXXX")
LAB=$(cd "$LAB" && pwd)
TIMEOUT=${FM_PROGRESS_LIVE_TIMEOUT:-240}
CHECKED=0
FAILED=0

pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

SHIM_DIR="$LAB/shim"
mkdir -p "$SHIM_DIR"
REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-progress-lib.sh"

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 220 -y 50 -c "$ROOT"

# The sample gap this guard uses. It must clear the library's own minimum, or
# every observation would answer `unknown` and the guard would prove nothing.
GAP=$(( FM_PROGRESS_MIN_GAP_SECS + 3 ))

harness_version() {  # <binary>
  "$1" --version 2>/dev/null | head -1 || printf 'version-unknown'
}

# The same unattended-autonomy launch posture bin/fm-spawn.sh uses, so a turn
# runs without an interactive approval standing in for the work.
launch_cmd() {  # <name>
  case "$1" in
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '\''{"feedbackDrafts":"off"}'\''' ;;
    codex) printf '%s' 'codex --dangerously-bypass-approvals-and-sandbox' ;;
    opencode) printf '%s' "OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}' opencode" ;;
    pi|pi-signed) printf '%s' "$1" ;;
    grok) printf '%s' 'grok --always-approve' ;;
    kimi) printf '%s' 'kimi --auto' ;;
    muse) printf '%s' 'MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on muse --yolo' ;;
    *) return 1 ;;
  esac
}

capture_pane() {  # <window>
  tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$1" 2>/dev/null || true
}

# One movement verdict over <gap> seconds of a real pane. Both captures are kept
# under the sample id, because a verdict that fails is only diagnosable from the
# two screens that produced it.
sample_verdict() {  # <window> <sample-id>
  local win=$1 id=$2 state="$LAB/progress-state"
  mkdir -p "$state"
  fm_progress_sample_clear "$state" "$id"
  capture_pane "$win" > "$LAB/$id.first"
  fm_progress_observe "$state" "$id" "$(cat "$LAB/$id.first")" >/dev/null
  sleep "$GAP"
  capture_pane "$win" > "$LAB/$id.second"
  fm_progress_observe "$state" "$id" "$(cat "$LAB/$id.second")"
}

# What a failed verdict needs in order to be read from its own output: the lines
# that differ between the two captures, and each capture's counters.
show_sample_evidence() {  # <sample-id>
  local id=$1 which counters
  for which in first second; do
    counters=$(fm_progress_counters "$(cat "$LAB/$id.$which")")
    printf '#   %s capture counters (footer tokens lines): %s\n' "$which" \
      "$(printf '%s' "$counters" | tr '\t' ' ' | cut -c1-120)" >&2
    printf '#   %s capture non-blank lines: %s\n' "$which" \
      "$(grep -c '[^[:space:]]' "$LAB/$id.$which" || true)" >&2
  done
  printf '#   lines that differ (< first capture, > second capture):\n' >&2
  diff "$LAB/$id.first" "$LAB/$id.second" | sed 's/^/#   /' >&2 || true
}

wait_ready() {  # <window>
  local win=$1 i=0 budget=60 verdict dismissed=0 screen
  while [ "$i" -lt "$budget" ]; do
    verdict=$(fm_tmux_composer_state "$SESSION:$win")
    [ "$verdict" = empty ] && return 0
    i=$((i + 1))
    if [ "$dismissed" -eq 0 ] && [ "$i" -ge $((budget / 3)) ]; then
      screen=$(capture_pane "$win")
      if ! printf '%s\n' "$screen" | grep -qi 'trust'; then
        tmux -L "$SOCKET" send-keys -t "$SESSION:$win" Escape 2>/dev/null || true
      fi
      dismissed=1
    fi
    sleep 1
  done
  case "$verdict" in
    pending) return 1 ;;
  esac
  return 2
}

# The pane has stopped rendering: <n> consecutive one-second captures identical.
wait_settled() {  # <window> <budget-secs>
  local win=$1 budget=$2 i=0 prev='' cur stable=0
  while [ "$i" -lt "$budget" ]; do
    cur=$(capture_pane "$win")
    if [ "$cur" = "$prev" ]; then
      stable=$((stable + 1))
      [ "$stable" -ge 4 ] && return 0
    else
      stable=0
    fi
    prev=$cur
    sleep 1
    i=$((i + 1))
  done
  return 1
}

check_harness_movement() {  # <name>
  local name=$1 version cmd win="px-$1" ready_rc verdict home
  version=$(harness_version "$name")
  cmd=$(launch_cmd "$name") || { note "no launch recipe for $name"; return 0; }
  tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$win" -c "$ROOT" \
    -- bash -lc "$cmd" \
    || { FAILED=1; printf 'not ok - %s (%s): could not launch in the isolated tmux server\n' "$name" "$version" >&2; return 0; }
  wait_ready "$win"; ready_rc=$?
  if [ "$ready_rc" -eq 1 ]; then
    FAILED=1
    printf 'not ok - %s (%s): composer stayed visibly pending; no turn could be started\n' "$name" "$version" >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  [ "$ready_rc" -eq 0 ] || note "$name ($version): idle composer never classified empty; proceeding anyway"

  # The turn is started through the REAL steering path, so the pane this guard
  # reads is rendering the same work a supervised worker renders. The ask is
  # long enough to still be running across both samples and made of rendered
  # output rather than tool calls, because rendered output is what the library
  # reads.
  home="$LAB/$name-home"
  mkdir -p "$home/state"
  printf 'window=%s:%s\nkind=ship\nharness=%s\n' "$SESSION" "$win" "$name" \
    > "$home/state/live-$name.meta"
  if ! FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-send.sh" "live-$name" \
    'Firstmate live check: without running any commands or tools, write out the numbers 1 to 60, one per line, then one short closing sentence.' \
    >/dev/null 2>&1; then
    FAILED=1
    printf 'not ok - %s (%s): the steering path refused the live turn\n' "$name" "$version" >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  sleep 3

  verdict=$(sample_verdict "$win" "$name-working")
  if [ "$verdict" = still ]; then
    FAILED=1
    printf 'not ok - MOVEMENT BLIND: %s (%s) rendered a running turn that read "still" across %ss, which is the verdict that admits a wedge. Teach bin/fm-progress-lib.sh the footer this release renders.\n' \
      "$name" "$version" "$GAP" >&2
    show_sample_evidence "$name-working"
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  note "$name ($version): a running turn reads '$verdict'"

  if ! wait_settled "$win" "$TIMEOUT"; then
    FAILED=1
    printf 'not ok - %s (%s): the pane never stopped rendering within %ss, so the settled direction could not be proven\n' \
      "$name" "$version" "$TIMEOUT" >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  verdict=$(sample_verdict "$win" "$name-settled")
  if [ "$verdict" != still ]; then
    FAILED=1
    printf 'not ok - MOVEMENT INERT: %s (%s) rendered a settled pane that read "%s", not "still", so nothing on this harness would ever be admitted as a possible wedge. Something in its idle rendering moves; bin/fm-progress-lib.sh must stop counting it as movement.\n' \
      "$name" "$version" "$verdict" >&2
    show_sample_evidence "$name-settled"
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi

  CHECKED=$((CHECKED + 1))
  pass "$name ($version): a running turn is not read as still, and a settled pane is"
  tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
}

HARNESSES=${FM_PROGRESS_LIVE_HARNESSES:-'claude codex opencode pi grok kimi muse'}
for h in $HARNESSES; do
  if command -v "$h" >/dev/null 2>&1; then
    check_harness_movement "$h"
  else
    note "harness absent, not verified here: $h"
  fi
done

if [ "$FAILED" -ne 0 ]; then
  printf 'not ok - live movement-evidence guard found failures above\n' >&2
  exit 1
fi
if [ "$CHECKED" -eq 0 ]; then
  printf 'not ok - live movement-evidence guard verified nothing (no harness installed?)\n' >&2
  exit 1
fi
pass "live movement-evidence guard: $CHECKED harness(es) separate a running turn from a settled pane"
