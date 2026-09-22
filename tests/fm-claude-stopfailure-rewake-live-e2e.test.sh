#!/usr/bin/env bash
# Live regression for the Claude primary's refused-turn continuity
# (bin/fm-claude-stop-autoarm.sh registered on StopFailure in the tracked
# .claude/settings.json).
#
# A turn that ends on an API error - the account's own session limit refusing
# the handling turn - fires StopFailure INSTEAD of Stop, so a Stop-only
# registration left supervision down until someone typed into the session. What
# only the real harness can answer is whether its StopFailure event runs the
# tracked asyncRewake entry and delivers that entry's exit-2 rewake, so this
# drives a real interactive Claude Code session whose every turn is refused:
# it is launched on a model name that does not exist, which ends each turn in
# StopFailure (error model_not_found) without reaching a model, so the guard
# spends no model tokens. Print mode cannot stand in for it, because it exits
# on the refused turn and takes the async hook with it before it arms.
#
# The arm wrapper is a fixture: two actionable closes, then a clean one that
# ends the supervision need so a misbehaving session cannot loop. Passing needs
# at least two hook-owned arms, which is a refused turn arming, rewaking, and the
# rewake's own refused turn arming again, each as a handling successor.
#
# The lab project is its own repository, so Claude asks whether to trust it and
# this accepts, which Claude records against the lab path in its own user
# config. The path is fixed rather than per-run so repeated runs leave that one
# entry rather than one each, and a second concurrent run refuses instead of
# sharing it. The FM_HOME and tmux server are isolated, and no live fleet home,
# worktree, or session is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CLAUDE_STOPFAILURE_LIVE,FM_CLAUDE_LIVE_E2E claude tmux

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

LAB="$ROOT/.claude-stopfailure-live-e2e"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
SOCK="fm-stopfailure-live-$$"
CLAUDE_VERSION=$(claude --version)

cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

pane() {
  tmux -L "$SOCK" capture-pane -pt fm-stopfailure 2>/dev/null || true
}

arm_runs() {
  if [ -f "$HOME_DIR/state/arm-ran" ]; then
    wc -l < "$HOME_DIR/state/arm-ran" | tr -d ' '
  else
    printf '0'
  fi
}

mkdir "$LAB" 2>/dev/null \
  || { trap - EXIT; fail "$LAB already exists: another run holds it, or a killed run left it to remove by hand"; }
# A clone carries only committed state, so copy the working-tree surfaces under
# test, as the Stop auto-arm live guard does.
git clone -q "$ROOT" "$PROJECT"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
cp "$ROOT/.claude/settings.json" "$PROJECT/.claude/settings.json"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
printf 'project=fixture\nwindow=fixture\nbackend=tmux\n' > "$HOME_DIR/state/task.meta"
# A numeric pid above the supported OS pid range is a demonstrably dead prior
# owner, which session start reclaims for this session.
printf '9999999\n' > "$HOME_DIR/state/.lock"

cat > "$PROJECT/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
N=$(cat "$FM_HOME/state/arm-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/arm-count"
echo "arm-run=$N predecessor=${FM_WATCH_PREDECESSOR_ARM_PID-unset}" >> "$FM_HOME/state/arm-ran"
if [ "$N" -ge 3 ]; then
  rm -f "$FM_HOME/state/task.meta"
  printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
  exit 0
fi
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-refused-%s\n' "$N"
exit 0
SH
chmod +x "$PROJECT/bin/fm-watch-arm.sh"

tmux -L "$SOCK" new-session -d -s fm-stopfailure -x 200 -y 50 -c "$PROJECT" \
  "env FM_HOME='$HOME_DIR' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --model fm-nonexistent-model --dangerously-skip-permissions" \
  || fail "could not start an isolated tmux server for Claude $CLAUDE_VERSION"

# Wait for the composer, then submit until the first refused turn is visible; a
# keystroke sent while the TUI is still starting is dropped.
i=0
submitted=0
while [ "$i" -lt 90 ]; do
  case "$(pane)" in
    *'❯ No, exit'*)
      tmux -L "$SOCK" send-keys -t fm-stopfailure Down
      sleep 0.5
      tmux -L "$SOCK" send-keys -t fm-stopfailure Enter
      sleep 2 ;;
    *'❯ No, disable external imports'*)
      # The lab's CLAUDE.md import resolves outside it; nothing here needs it.
      tmux -L "$SOCK" send-keys -t fm-stopfailure Enter
      sleep 2 ;;
    *'❯'*'Yes, I trust this folder'*)
      tmux -L "$SOCK" send-keys -t fm-stopfailure Enter
      sleep 2 ;;
    *'selected model'*) submitted=1; break ;;
    *'bypass permissions'*)
      tmux -L "$SOCK" send-keys -t fm-stopfailure -l 'reply OK'
      sleep 1
      tmux -L "$SOCK" send-keys -t fm-stopfailure Enter
      sleep 4 ;;
    *) sleep 1 ;;
  esac
  i=$((i + 1))
done
[ "$submitted" = 1 ] \
  || fail "Claude $CLAUDE_VERSION never showed a refused turn for the nonexistent model: $(pane | grep -v '^[[:space:]]*$' | tail -8)"

i=0
while [ "$i" -lt 120 ] && [ "$(arm_runs)" -lt 3 ]; do
  sleep 1
  i=$((i + 1))
done

RUNS=$(arm_runs)
[ "$RUNS" -ge 2 ] \
  || fail "Claude $CLAUDE_VERSION: a refused turn armed the watcher $RUNS time(s), so StopFailure did not run the tracked auto-arm and deliver its rewake: $(cat "$HOME_DIR/state/arm-ran" 2>/dev/null)"
! grep -q 'predecessor=unset' "$HOME_DIR/state/arm-ran" \
  || fail "Claude $CLAUDE_VERSION: a refused turn armed as a fresh start rather than a handling successor: $(cat "$HOME_DIR/state/arm-ran")"
REWAKES=$(pane | grep -c 'Stop hook feedback' || true)
[ "$REWAKES" -ge 1 ] \
  || fail "Claude $CLAUDE_VERSION: no rewake was delivered from the refused turn's auto-arm"
printf 'ok - claude (%s): a refused turn re-arms through StopFailure as a handling successor and its rewake is delivered (%s arms, %s rewakes)\n' \
  "$CLAUDE_VERSION" "$RUNS" "$REWAKES"
