#!/usr/bin/env bash
# Live driver: real fm-claude-stop-autoarm.sh whose identity-gate `ps -o comm=`
# genuinely hangs, fired on every Stop, next to the real fm-turnend-guard.sh.
# usage: drive-repeating-hang.sh <root-with-bin> [guard-script-override]
set -u
SRC=$1; GUARD_OVERRIDE=${2:-}
GRACE=4
D=$(mktemp -d /tmp/fm-live-XXXXXX)
mkdir -p "$D/state" "$D/bin" "$D/docs" "$D/stubs"
git init -q "$D"; git -C "$D" -c user.name=t -c user.email=t@e.invalid commit -q --allow-empty -m init
: > "$D/AGENTS.md"
for f in fm-turnend-guard fm-operational-input fm-supervision-instructions fm-harness fm-primary-scope-lib fm-supervision-lib fm-wake-lib fm-hook-host-lib fm-timing-lib fm-session-lock-lib fm-cursor-lib fm-claude-stop-autoarm; do cp "$SRC/bin/$f.sh" "$D/bin/"; done
cp "$SRC/bin/fm-lock.sh" "$D/bin/"; cp "$SRC/bin/fm-turnend-guard-grok.sh" "$D/bin/" 2>/dev/null
cp -R "$SRC/docs/supervision-protocols" "$D/docs/"
[ -n "$GUARD_OVERRIDE" ] && cp "$GUARD_OVERRIDE" "$D/bin/fm-turnend-guard.sh"
chmod +x "$D"/bin/*.sh; ln -s /bin/bash "$D/fake-claude"
# ps stub: hangs on the identity gate's comm/args probes, real ps otherwise
REALPS=$(command -v ps)
cat > "$D/stubs/ps" <<PS
#!/usr/bin/env bash
case "\$*" in *"comm="*|*"args="*) exec sleep 3600 ;; esac
exec $REALPS "\$@"
PS
chmod +x "$D/stubs/ps"
: > "$D/state/task1.meta"
HOME_ABS=$(cd "$D" && pwd)
fire_autoarm() {  # background, hangs in identity gate
  ( printf '{"session_id":"s","stop_hook_active":false}\n' | PATH="$D/stubs:$PATH" FM_GUARD_GRACE=$GRACE FM_HOME="$HOME_ABS" "$D/fake-claude" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"; exec "$FM_HOME/bin/fm-claude-stop-autoarm.sh"' >/dev/null 2>&1 & )
}
fire_guard() {
  printf '{"stop_hook_active":true,"session_id":"s"}' | CLAUDECODE=1 FM_GUARD_GRACE=$GRACE FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=800 FM_HOME="$HOME_ABS" bash "$D/bin/fm-turnend-guard.sh" --claude >"$D/guard.out" 2>&1
  echo $?
}
T0=$(date +%s)
for i in 1 2 3 4 5 6 7 8 9 10; do
  fire_autoarm; sleep 0.6
  claim=$(sed -n '1p;3p' "$D/state/.claude-autoarm-claim" 2>/dev/null | tr '\n' ' ')
  rc=$(fire_guard)
  printf 't=+%ss stop#%s claim[%s] guard_exit=%s episode=%s\n' "$(( $(date +%s)-T0 ))" "$i" "$claim" "$rc" "$([ -e "$D/state/.claude-autoarm-claim-episode" ] && echo present || echo absent)"
  sleep 0.9
done
grep -o "TURN WOULD END BLIND" "$D/guard.out" | head -1
pkill -f "sleep 3600" 2>/dev/null; pkill -f "fm-claude-stop-autoarm" 2>/dev/null
rm -rf "$D"
