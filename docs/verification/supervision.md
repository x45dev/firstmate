# Supervision integration verification

Audience: maintainer verification.

This record supports current session-start, semantic busy state, allowance-park, turn-end, watcher-continuity, and wedge-alarm guarantees.
Operator behavior and active limits remain in the linked current guides.
Task-specific chronology, temporary paths, run identifiers, and delivery transcripts remain in private reports or PR evidence.

## Native session-start delivery

The cross-harness transport pass ran on 2026-07-17 with Codex 0.144.4, Grok 0.2.103, OpenCode 1.17.18, Pi 0.80.10, and the tracked Claude hook wiring.

Codex command shape:

```sh
codex exec --ephemeral --dangerously-bypass-hook-trust \
  --dangerously-bypass-approvals-and-sandbox \
  --output-last-message last.txt \
  'Follow any SessionStart hook context before this prompt.'
```

Observed result: the `SessionStart` hook completed and its stdout reached model context.

Grok command shape:

```sh
grok --trust -p 'Follow any SessionStart hook context before this prompt.' \
  --permission-mode bypassPermissions --output-format plain
```

Observed result: the project hook ran, but its stdout did not reach model context.
This is the current Grok fail-open limit.

OpenCode was checked in both headless and interactive modes.
`client.session.promptAsync` accepted the nudge in both cases; the persistent TUI completed the generated turn, while `opencode run` exited before another turn.
This is the current headless fail-open limit.

Pi command shape:

```sh
pi -p -e .pi/extensions/fm-primary-turnend-guard.ts \
  --no-context-files --no-session \
  'After obeying any earlier session-start instruction, reply with exactly PI_SMOKE_DONE.'
```

Observed result: `PI_SMOKE_DONE`, with one session-start execution.
That cold positional-prompt check established eventual custom-message delivery, but it did not submit immediately after `/new` while native digest generation was still running, so its earlier race-free inference is superseded by the provider-prerequisite evidence below.
The installed pi-signed 0.82.0 wrapper repeated the shared Pi primary extension and session-start path on 2026-07-27.
[`runtime-backends.md`](runtime-backends.md#tmux) owns the shared-ancestry evidence and authoritative selection-marker boundary.

### omp (Oh My Pi) native delivery, 2026-09-05

The omp Run-tier adapter was verified on 2026-09-05 with omp 18.1.11 and the openai-codex `gpt-6-astra` model through `FM_OMP_LIVE_E2E=1 tests/fm-omp-primary-live-e2e.test.sh`, which drives a real omp in its JSON-RPC stdio mode inside an isolated lab clone.
Both tracked `.omp/extensions/*.ts` files loaded by auto-discovery alone (no `-e`, no trust dialog), `before_agent_start` returned the digest as a persistent context message, the model quoted the lab's `SESSION START -` heading back on its first turn, `state/.session-start-complete` was recorded, and `state/.lock` named the omp process, so ancestry detection identified the markerless binary.
omp's `session_start` payload carries no reason field, so the adapter derives the source: the first start of the process is `startup` (or `resume` from a `--continue`/`--resume` launch line) and a later in-process start is `clear`; `tests/fm-omp-harness.test.sh` pins that mapping over a fake omp API.
A file named both by `-e` and by auto-discovery loads twice (two factory calls, doubled `session_stop` continuations), which is why the secondmate launch names no `-e` and the per-task worker extension lives in `state/`.

### Run-tier source vocabulary and context-reset injection

The run tier depends on three facts only the vendor can supply: the session-open source it reports, whether hook stdout reaches model context on a context-RESET open rather than only a cold one, and whether a worker the hook detaches survives the hook returning.
The first two were measured on 2026-08-05 against a throwaway Firstmate-shaped lab carrying each harness's own tracked registration with a recorder standing in for `bin/fm-sessionstart-run.sh`.
Each open printed a source-stamped token, and the model was asked to quote that token back, so producing hook stdout could never be mistaken for delivering it.
The third is recorded below.

| Harness | Version verified | Cold open | Context reset | Context-preserving reopen |
| --- | --- | --- | --- | --- |
| Claude | 2.1.222 (Claude Code) | `source=startup`, token quoted back in both `-p` and the TUI | `/clear` reports `source=clear` and `/compact` reports `source=compact`; both re-injected a fresh token that the model quoted back | `claude --continue` reports `source=resume` |
| Codex | codex-cli 0.146.0 | `source=startup` under `codex exec`, token quoted back | Not reachable from a tracked project registration; see the limit below | `codex exec resume --last` reports `source=resume` |
| Pi | 0.82.0 | `source=startup`, token quoted back in both `-p` and the TUI | `/new` raises `session_start` reason `new`, which the extension maps to `clear`; `/compact` raises `session_compact`, and both freshly injected source-stamped tokens were quoted back | `pi -c` reports reason `startup`, not `resume` |

Two harness-specific consequences are load-bearing rather than incidental.

Codex's interactive TUI fired no project `SessionStart` hook at all in the same lab where `codex exec` fired it reliably, which matches the earlier 2026-07-28 finding for 0.145.0.
Codex's run tier is therefore verified only for `codex exec` startup and context-preserving resume.
The interactive TUI is a known uncovered gap: Firstmate has no tracked session-open, compaction, or re-emit channel there, ships no global hook, and does not claim instruction-refresh delivery for that surface.

Pi compaction was verified on 2026-08-05 with Pi 0.82.0 in the same throwaway lab after setting `.pi/settings.json` `compaction.keepRecentTokens` to 200 and completing one substantial assistant-prose turn before issuing `/compact`.
Pi reported `Compacted from 7,697 tokens`, the recorder observed `session_compact`, and the model quoted the freshly injected `source=compact` token back.
Both preconditions are load-bearing: the stock 20,000-token keep window exceeds a small lab session, and `AgentSession.compact()` aborts an in-flight turn before measuring compactable history, which otherwise discards that turn and reports `Nothing to compact (session too small)`.
Tool output alone does not grow compactable context; the completed assistant prose does.

Observed compaction output and recorder source:

```text
Compacted from 7,697 tokens
compact
```

Pi disagrees with Claude and Codex on `resume`: a new Pi process continuing a session reports `startup`, and Pi's `resume` reason is reserved for an in-process session switch.
The current adapter classification and baseline mechanics are owned by [`../sessionstart-nudge.md`](../sessionstart-nudge.md#harness-transports) and the `bin/fm-session-start.sh` header.
Their continuation classification is covered by portable tests, not claimed as live validation in this record.

### Pi `/new` provider prerequisite

The real offline Pi regression ran on 2026-08-26 with Pi 0.84.0, an isolated home and session directory, a barrier-controlled native digest, and a deterministic local `streamSimple` provider.
The provider makes no HTTP request and requires no user credential.
Its missing-native branch deliberately requests `bin/fm-session-start.sh`, so an escaped first call reproduces the duplicate-producing manual path rather than passing vacuously.

```sh
FM_PI_SESSIONSTART_RACE_LIVE_E2E=1 \
  tests/fm-sessionstart-hook-live-e2e.test.sh
```

Observed output:

```text
ok - Pi 0.84.0: immediate and completed-before-prompt /new paths each made one first provider call with exactly one native startup context and no manual execution
# fm-sessionstart-hook-live-e2e.test.sh: offline Pi /new race assertions passed
```

The immediate case submitted its first prompt only after the native `clear` child published `started`, held the child behind a release barrier, and proved the provider log remained absent for 500 milliseconds before release.
After release, the first payload reported one native context and no manual result, the session persisted one matching custom message, and the fixture recorded one native execution.
The control case let native generation complete before prompt submission and produced the same first-payload result.
The portable public-event regression in `tests/fm-sessionstart-nudge.test.sh` separately covers interruption, process-tree retirement, two rapid replacements, stale completion, empty output, spawn error, timeout output, truncation, ineligible stand-down, and compaction cancellation.
Pi and pi-signed load the same tracked extension bytes; pi-signed was not installed on this host for a separate 0.84.0 live rerun.

### Post-start instruction refresh

The isolated real-Pi instruction-refresh regression ran on 2026-08-11 with Pi 0.84.0.
It used a scratch `FM_HOME`, a private tmux socket, and a disposable Firstmate checkout.
The historical `origin/main` implementation first reproduced the stale original marker after a real compaction.
The current implementation then recorded `source=startup`, changed and committed the lab's `AGENTS.md`, compacted the same real Pi session, and answered with the replacement marker.
The fixed run also proved that the true-start baseline remained different from the updated file after compaction.

```sh
FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E=1 \
FM_SESSIONSTART_INSTRUCTION_REFRESH_REF=origin/main \
FM_SESSIONSTART_INSTRUCTION_REFRESH_EXPECT=stale \
tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh
# ok - Pi 0.84.0 reproduces stale AGENTS.md after a real compact

FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E=1 \
tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh
# ok - Pi 0.84.0 re-injects updated AGENTS.md after a real compact in an isolated session
```

This is live coverage only for Pi compaction.
The portable session-start tests cover continuation classification, baseline immutability, and source-routing behavior.
Pi compaction is the only supported stale-cache refresh pair.
Codex exec exposes only startup and context-preserving resume through tracked registration; Codex interactive reset behavior remains uncovered rather than inferred from direct wrapper invocation.

### Detached session-open workers survive the hook

Session start composes its digest from local reads and runs every external-network call in a worker detached by the hook (`bin/fm-startup-network.sh`), so a harness that reaped the hook's process tree would silently stop running the sweeps rather than merely delaying them.
Verified on 2026-08-06 with Claude Code 2.1.222 in a throwaway lab whose `bin/fm-bootstrap.sh` sleeps 6s before writing a marker, so the marker can exist only if the worker outlived the hook and the whole `claude -p` process.

```text
$ claude -p --permission-mode bypassPermissions '<quote the session-start token>'
FMHOOKTOKEN-startup-1-abc123
--- claude exited at 13:38:40; polling for the detached worker's marker ---
MARKER at +4s: detached worker survived the hook
state=done
started=1786048716
finished=1786048723
```

The worker started before the harness exited and published 6s after it was gone.

The latency this buys was re-measured on 2026-08-06 against default-branch tip `8398d31`, in a throwaway home holding one remote secondmate whose host hangs 25s per SSH connection (an `FM_SSH_BIN`-shaped stub; no real host was contacted).
Both runs used the same fixture and the same `bin/fm-session-start.sh` invocation, differing only in which checkout supplied the script:

```text
before (8398d31)   real 1m21.15s   3 blocking SSH attempts inside the digest
after              real 0m3.36s    digest prints IN PROGRESS; the same 3 SSH attempts
                                   run in the detached worker and finish at +77s
```

The remaining seconds are entirely local subprocess work; the `NETWORK CHECKS` section named GitHub authentication, dead-secondmate relaunch, secondmate convergence, pending handoff delivery, and project clone refresh as not yet confirmed.

Deferring the sweeps changed only when they run, not what they conclude.
The deferred worker's published report was byte-identical to the three sweep lines the blocking baseline printed, on the same fixture:

```text
SECONDMATE_LIVENESS: secondmate ios: skipped: remote host unavailable or endpoint state unknown; route preserved on remote-mac
SECONDMATE_SYNC: secondmate ios: skipped: remote tracked-file sync failed on remote-mac:
SECONDMATE_SYNC: secondmate ios: skipped: remote inheritance failed on remote-mac:
```

The unreachable route was preserved rather than relaunched in both runs, and the result surfaced durably as a queued `check: startup-network` wake once the worker finished.

Codex and Pi were not installed as run-tier labs in this measurement, so their evidence for this fact is NOT refreshed; `tests/fm-sessionstart-hook-live-e2e.test.sh` asserts it for each installed Claude, Codex exec, and Pi adapter and is the command that refreshes their record.
Cursor's separate primary live guard covers its source-free session-open transport but does not claim this detached-worker measurement.
A harness that did reap the worker degrades loudly rather than silently: the leftover record reads as an abandoned run needing a rerun, and the next session start re-derives every finding, because these sweeps are idempotent detectors.

Current deterministic and live entry points:

```sh
tests/fm-sessionstart-nudge.test.sh
tests/fm-session-start.test.sh
tests/fm-startup-network.test.sh
FM_SESSIONSTART_HOOK_LIVE_E2E=1 tests/fm-sessionstart-hook-live-e2e.test.sh
FM_PI_SESSIONSTART_RACE_LIVE_E2E=1 tests/fm-sessionstart-hook-live-e2e.test.sh
FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E=1 tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh
```

`tests/fm-sessionstart-hook-live-e2e.test.sh` is the command that refreshes the Claude, Codex exec, and Pi table above; run it after upgrading any of those harnesses.
It reports an absent adapter explicitly, asserts Pi compaction rather than noting it, and refuses to pass when none of those three adapters was installed.
Cursor's refresh command is `FM_CURSOR_PRIMARY_LIVE_E2E=1 tests/fm-cursor-primary-live-e2e.test.sh`, recorded under [Cursor primary park](#cursor-primary-park-2026-08-13).

The Ahoy first-message boundary was reverified on 2026-07-22 with Pi 0.81.1 and OpenCode 1.17.18.
Marked current operational input and the two exact legacy compatibility shapes selected Bearings, while genuine near-miss captain messages remained real boundaries.
The detailed reconciliation and task chronology stay in the private audit report and PR evidence.

## Semantic busy state

The per-adapter semantic sources behind [`bin/fm-busy-lib.sh`](../../bin/fm-busy-lib.sh) were live-verified on 2026-07-28 against firstmate-launched workers wired exactly as `fm-spawn` writes them.
Each pass polled `state/<id>.busy-state` while a real turn ran.

| Harness | Version verified | Semantic source | Observed result |
| --- | --- | --- | --- |
| Pi | 0.82.0 | Extension `agent_start` / `agent_settled` with `ctx.isIdle()` | The spawn seed `busy source=fm-spawn`, then `busy source=pi-ext event=agent-start`, then `idle source=pi-ext event=agent-settled`; the turn-end marker was still touched. |
| omp | 18.1.11 | Extension `agent_start` / `agent_end` without `willContinue` | Live Herdr scout on `openai-codex/gpt-6-astra` (2026-09-05): the spawn seed `busy source=fm-spawn`, then `busy source=omp-ext event=agent-start`, then `idle source=omp-ext event=agent-end` at the natural end of the brief; a steer through `fm-send` reopened `busy … agent-start`, and a control-plane interrupt closed it with `idle … agent-end` (omp fires `agent_end` on an interrupted turn). `ctx.isIdle()` is deliberately not consulted because it reads false at a natural TUI `agent_end`. |
| OpenCode | 1.17.18 | Plugin `session.status` | In a real TUI pane: seed, then `busy source=opencode-plugin event=session-busy`, then `idle source=opencode-plugin event=session-status-idle`. |
| Claude | 2.1.220 (Claude Code) | Hooks `UserPromptSubmit`, `Stop`, `StopFailure`, `SessionEnd` | `UserPromptSubmit` fired for the argv launch prompt and each steer, and `Stop` closed every completed turn. A mid-stream Escape interrupt fired no closing hook, which is why the firstmate-controlled clear exists. `StopFailure` and `SessionEnd` are wired from the four hook names present in the installed binary; only the abnormal paths they cover were not reproduced live. |
| Codex | codex-cli 0.145.0 | None usable | See below; classifies `unknown codex-unverified`. |
| Kimi (standalone) | not installed | None usable | No binary on `PATH`, so the gate stays closed and it classifies `unknown kimi-unverified`. |
| Grok | 0.2.112 | Isolated rendered-tail fallback | Retained unconverted; the approved audit could not credit a live structured-lifecycle run. |

Codex was probed two ways, both refused:

```sh
codex app-server daemon start
codex exec --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust 'Reply with exactly PROBE2.'
```

The daemon refused with `managed standalone Codex install not found`, and an interactive TUI worker neither starts nor attaches to the app-server control socket, so no client can observe its turns.
In this 2026-07-28 Codex 0.145.0 semantic-busy probe, Firstmate-written lifecycle project hooks under `<worktree>/.codex/hooks.json` fired for neither an interactive pane whose directory trust was granted nor `codex exec`, in both cases with `--dangerously-bypass-hook-trust`, while an untracked global probe fired in the same runs; Firstmate does not ship, install, recommend, or depend on that global path.
Codex also exposes no `StopFailure` hook, so an API-error turn end would need separate coverage even after hook discovery works.
The app-server protocol schema does define the required lifecycle (`turn/started`, plus a `turn/completed` status of `completed`, `interrupted`, `failed`, or `inProgress`), so the gate is a reachability problem rather than a protocol gap.

Deterministic entry points:

```sh
tests/fm-busy-state.test.sh
tests/fm-busy-adapter-wiring.test.sh
tests/fm-crew-state.test.sh
```

## Wedge evidence

A pane that renders nothing new is the only evidence the wedge bound ever had, and it cannot tell a hung foreground call from a live worker on a long quiet step.
[`bin/fm-progress-lib.sh`](../../bin/fm-progress-lib.sh) is the single owner of the movement verdict that separates them, and [`bin/fm-watch.sh`](../../bin/fm-watch.sh) consults it, the validation run's own step-activity recency, and the crew's completion state before escalating a possible wedge.

The verdict reads three counters across two samples, and only the token counter carries an `advanced`, so the footer and content counters can prove a process is alive without ever deferring a wedge:

| Counter | Source | What it carries |
| --- | --- | --- |
| `footer` | a digest of the last `FM_PROGRESS_FOOTER_LINES` non-blank lines | liveness only; it models no notation, so a footer this release cannot parse degrades to `alive` and never to `still` |
| `tokens` | a progress counter read out of that footer | forward progress, the only counter that reads `advanced`, and only while it is rendered in both samples; a counter that appears or disappears between samples is a turn starting or ending, not progress |
| `content` | a rendered line above the footer that appeared nowhere in the previous capture, footer included | liveness only, for a harness whose footer is frozen; body content cannot tell a hung foreground call from progress, because on claude 2.1.278 the running tool's header bullet blinks and its timer changes shape at each minute while the token count stays static; a line that only changes sides of the footer boundary because another line appeared or expired inside the footer is not new output |

`advanced` needs the token counter to move, `alive` is a moved footer or a new body line, and `still` is the only verdict that admits a wedge, reached only when two captures that each render something are compared and none of the three counters moved.
A blank capture is no observation: it answers `unknown` without touching the record, so a transient blank can neither read as progress nor become the anchor the next real capture is compared against.
A record written without the per-line digests has no comparable prior and also answers `unknown`.
An unreadable surface answers `unknown`, which licenses nothing in either direction.

Verified deterministically on 2026-09-21:

```sh
tests/fm-progress-lib.test.sh
tests/fm-watch-triage.test.sh
tests/fm-wake-queue.test.sh
tests/fm-crew-state.test.sh
```

```text
ok - an unchanged pane reports still - the only verdict that admits a wedge
ok - a ticking turn timer alone reports alive: proof of life, not of progress
ok - new rendered content reports alive even when the whole footer is frozen
ok - an analysis pass whose token count climbs reports advanced past the one-hour bound
ok - a hung foreground command with a static token count never reads advanced and never latches, in the UTF-8 and C locales
ok - a token counter appearing or disappearing between samples reads alive and latches nothing
ok - a surface rendering no counter reports unknown: stillness is observed, never inferred
ok - a transient footer line appearing or expiring reads alive, never advanced
ok - a real sample, a blank capture, then the same real capture never reads advanced
ok - a clock-form timer and a footer notation nothing models both read as movement
ok - a measured advance defers the wedge across the window being judged, and stops deferring it once the advance is older than that window
ok - a validation run reporting recent step activity is not wedge-escalated, while one reporting a quiet step still is
ok - a crew holding a green PR is not wedge-escalated, while a failed one on the same idle pane still is
ok - a busy pane past the completed-turn bound still wedge-escalates in a crew whose last run reads done
ok - a retired endpoint stops at the recorded-window check, while a live window whose capture came back empty keeps its bookkeeping
ok - a busy marker over a pane that moves nothing across two samples is not reported working, while a moving one still is
ok - only a recently established still verdict refuses a busy claim; one older than the maximum gap reads unknown
ok - a secondmate's paused still verdict is dropped, so a resumed turn is not reported as a stalled wake loop
ok - one declared wait rechecks exactly once per window across eight polls and a churning pane hash
ok - a working run carries its own step-activity recency, and a run with no active step never reads as recent
```

`tests/fm-progress-lib.test.sh` reported 25 passing assertions with no failures on that run, and the listed `tests/fm-watch-triage.test.sh` assertions were run individually.

The `tokens` and `footer` counters are read out of vendor-rendered output, so the harness-dependent-checks rule in [`firstmate-coding-guidelines`](../../.agents/skills/firstmate-coding-guidelines/SKILL.md) applies: the portable regressions above pin the classifier, and `FM_PROGRESS_LIVE_E2E=1 tests/fm-progress-live-e2e.test.sh` proves it against every installed harness in three directions - a running turn must not read `still`, a settled pane must never read `advanced` and must reach `still`, and a hung foreground command must never read `advanced` across the latch window.
That guard passed against claude in all three directions on 2026-09-21, recorded verbatim in [`runtime-backends.md`](runtime-backends.md) ("Rendered movement evidence"); the other harnesses are not run there because this fleet dispatches only claude.

### The declared-wait repeat, unconfirmed

On 2026-09-11 one declared wait re-surfaced twice about sixty seconds apart, reporting an age of 3607s and then 3605s.
An age that falls across a gap that only moves forward means the anchor the recheck cadence measures from advanced, which one actor reading one status file cannot do.
Two explanations fit: something rewrote that anchor, or a second actor fired against an anchor of its own.

Neither could be established at this HEAD on 2026-09-20.
Two controlled reproductions - the dead-agent paused path through `handle_paused_stale`, and the live-parked path through `surface_nonterminal_stale` with an alternating pane hash - each held the once-per-window contract, and `escalate_add` in [`bin/fm-supervise-daemon.sh`](../../bin/fm-supervise-daemon.sh) advances its own marker once per window as well.
The triage log keeps only absorbed sightings, and both tasks had been cleaned up before the records were read.

Both reproductions are now regressions pinning that contract, and `resurface_audit` records what each FIRED recheck was anchored on, so the next occurrence names which of the two explanations it was:

```text
resurface anchor moved (the 2026-09-11 repeat-fire tell; capture this): <marker> reported <n>s at <ts> and <n>s at <ts>, so its anchor advanced <n>s
```

No fix is claimed for this half.

## Allowance-park detection

A worker whose provider refused the turn on the account allowance keeps a live process, a live endpoint, and a normally rendered pane, so every liveness probe above reads it as healthy.
[`bin/fm-allowance-lib.sh`](../../bin/fm-allowance-lib.sh) is the single owner of that verdict, and [`bin/fm-watch.sh`](../../bin/fm-watch.sh) and [`bin/fm-crew-state.sh`](../../bin/fm-crew-state.sh) both consult it ahead of their busy gate, because the semantic busy state above stays busy across a refused turn whose closing hook never fires.
[`bin/fm-allowance-resume-lib.sh`](../../bin/fm-allowance-resume-lib.sh) is the single owner of what the watcher then does about it.
The verdict reads two independent signals and either alone carries it, so no single vendor string is load-bearing.

Per-harness support is a gate: an adapter with no entry below reports "not parked" and behaves exactly as it did before the library existed.

| Harness | Version verified | Signal | Observed result |
| --- | --- | --- | --- |
| Claude | 2.1.241 (Claude Code) | Session record (structural, preferred) | 128 refusal records across the local transcript store, every one an assistant record carrying `"isApiErrorMessage":true` with `"apiErrorStatus":429` and `"error":"rate_limit"`. |
| Claude | 2.1.241 (Claude Code) | Rendered pane (fallback) | The pane carries the same limit notice plus a `Press Enter to continue after reset` affordance, captured from the 2026-08-17 incident panes. That affordance never reaches the transcript, so the two signals stay genuinely independent. |
| Codex, OpenCode, Pi, Grok, Kimi, Cursor, Muse | n/a | None | No refusal has been observed from these adapters, so no signature is claimed and none of them ever parks. |

The 429 conjunction, rather than `isApiErrorMessage` alone, is what separates an allowance park from the other refusals the same field marks, measured on 2026-08-23:

```sh
grep -raho '"apiErrorStatus":[0-9]*' ~/.claude/projects/ | sort | uniq -c
#     128 "apiErrorStatus":429

grep -rah '"isApiErrorMessage":true' ~/.claude/projects/ | grep -v '"apiErrorStatus"' \
  | grep -o '"text":"[^"]*"' | sort | uniq -c
#       1 "text":"Not logged in · Please run /login"
#       2 "text":"Request timed out"
```

429 is the only status the field ever takes, and the two non-allowance refusals carry no status at all.
The notice itself takes three shapes, which is why the signature matches the limit word as a class with an optional trailing clause rather than as a literal:

```sh
grep -rah '"apiErrorStatus":429' ~/.claude/projects/ | grep -o '"text":"[^"]*"' \
  | sed 's/[0-9]\{1,2\}:\?[0-9]\{0,2\}[ap]m/HH:MMxm/' | sort | uniq -c | sort -rn
#      84 "text":"You've hit your session limit · resets HH:MMxm (UTC)"
#      40 "text":"You've hit your session limit · resets HH:MMxm (UTC) · progress saved"
#       4 "text":"You've hit your weekly limit · resets HH:MMxm (UTC)"
```

Taking the last conversational record - user and assistant records only - is what makes the structural signal current state rather than history, and it discriminates on the same store:

```text
transcripts with a 429 record: 68
last conversational record IS the refusal (parked): 29
something later (resumed): 39
```

Transcripts live at `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/<worktree with / and . replaced by ->/<session>.jsonl`, and `bin/fm-spawn.sh` forwards firstmate's own resolved store onto the crewmate launch, so the watcher resolves the same store the crewmate writes.
At session start only `<project-dir>/<session>/tool-results/` exists; the transcript appears once the session has content, which is why the live guard below asserts on the directory rather than on a transcript.

### The recorded reset, and the bound it puts on the verdict

Taking the last conversational record makes the verdict current state rather than history, but it says nothing about how long that state may be asserted for.
Left unbounded it kept reporting `state: parked · source: allowance` for a worker that had been resumed and was visibly working, so only a pane peek could tell stopped from running - the same "every source reads quiet" gap this whole section exists to close, in the other direction.

The refusal record carries the reset it is waiting on as an absolute epoch second, beside the error fields above, which is what bounds it.
That field is preferred over the clock rendered inside the notice (`resets 2:50am (UTC)`) because the rendered clock carries no date and so cannot say which day a weekly window resets on.
Measured over the local store on 2026-09-20:

```sh
grep -rah '"apiErrorStatus":429' ~/.claude/projects/ | wc -l
#     245

grep -rah '"apiErrorStatus":429' ~/.claude/projects/ | grep -ac '"resetsAt"[ ]*:[ ]*[0-9]'
#     232
```

The 13 without one are a `"quotaLimits":null` written by Claude Code 2.1.226 and 2.1.227; every newer build records `{"status":"rejected","resetsAt":<epoch>,"rateLimitType":"five_hour"|"seven_day"}`.
An absent reset is therefore read as no bound, never as zero, so a build that records none keeps exactly the pre-bound behaviour.

The reset is what identifies a park episode, because the notice text is byte-identical every window and cannot tell one park from the next.
`bin/fm-watch.sh` keys its once-per-episode wake and its resume record on the recorded reset together with the notice, so a worker refused again on the same notice but a new reset is a new episode, surfaced and resumed on its own terms.

The same field bounds the verdict in time.
The structural arm stops claiming a park once the newest `user`, `assistant` or `system` record in the transcript tail that carries its own `timestamp` is at or after the recorded reset.
A worker still sitting at its limit prompt has taken no turn, and the refusal record itself is written while its own reset is still in the future, so a fresh park can never satisfy the bound; a resumed worker satisfies it on its first turn.

The bound reads record timestamps rather than the file's mtime because a refusal-terminated transcript is written to for reasons that are not a turn.
Measured over the local store on 2026-09-20, from the repository root, with the library's own helpers:

```sh
. bin/fm-allowance-lib.sh
refused=0 reset=0 mtime_cross=0 stamp_cross=0
for f in ~/.claude/projects/*/*.jsonl; do
  _fm_allowance_record_parked "$f" >/dev/null 2>&1 || continue
  refused=$((refused + 1))
  r=$(_fm_allowance_record_reset "$f" 2>/dev/null) || continue
  reset=$((reset + 1))
  [ "$(_fm_allowance_mtime "$f")" -ge "$r" ] && mtime_cross=$((mtime_cross + 1))
  _fm_allowance_record_superseded "$f" && stamp_cross=$((stamp_cross + 1))
done
echo "last conversational record is the refusal: $refused"
echo "  of those, with a recorded reset:         $reset"
echo "  file mtime at or after that reset:       $mtime_cross"
echo "  newest record timestamp at or after it:  $stamp_cross"
# last conversational record is the refusal: 40
#   of those, with a recorded reset:         40
#   file mtime at or after that reset:       6
#   newest record timestamp at or after it:  0
```

So a still-parked worker's transcript CAN cross its own reset by file mtime: 6 of the 40 refusal-terminated transcripts did, and an mtime bound would have read all six as resumed.
The records written after the refusal in those six are all non-conversational session metadata:

```sh
. bin/fm-allowance-lib.sh
for f in ~/.claude/projects/*/*.jsonl; do
  _fm_allowance_record_parked "$f" >/dev/null 2>&1 || continue
  r=$(_fm_allowance_record_reset "$f" 2>/dev/null) || continue
  [ "$(_fm_allowance_mtime "$f")" -ge "$r" ] || continue
  tail -n "$FM_ALLOWANCE_RECORD_TAIL_LINES" "$f" | sed -n '/"apiErrorStatus":429/,$p' | tail -n +2 \
    | grep -ao '^{"type":"[a-z-]*"' | sed 's/^{"type":"//; s/"$//' | sort -u
done | sort | uniq -c | sort -rn
#       6 last-prompt
#       4 bridge-session
#       3 file-history-snapshot
#       1 queue-operation
#       1 pr-link
#       1 permission-mode
#       1 mode
#       1 cost-state
#       1 atis-latch
#       1 ai-title
```

None of them is a turn, none carries a timestamp of its own that the bound reads, and the `cost-state` records look like shutdown writes.
Every transcript above is a finished session, so this measures what the store holds and not what a running worker does.
One live park has been watched since: on Claude Code 2.1.278 on 2026-09-20 the transcript took no write at all between the refusal and the worker being restarted by hand more than six hours later, across its own reset, so those metadata writes were not produced during that park.
That is one park and does not refute the crossings above, and whether a live parked session ever receives such writes is still not settled by it.
The code therefore does not depend on a parked worker's file staying still: a metadata write never satisfies the bound, and only a record that carries a timestamp at or after the reset does.
Its blind spot is the opposite one: a resumed worker whose only post-reset write is untimestamped metadata reads as still parked until its first timestamped record lands, which costs one stale report and, at most, one further steering message once the retry interval below has passed.

The rendered arm is bounded by the same transcript, and only for the episode the transcript has shown over.
A pane has no clock, so a notice still near its prompt says nothing about when it was rendered.
Where the transcript holds a refusal it has superseded, or that a later conversational record followed, and that refusal's own recorded reset is already past, a pane notice showing the same reset clock is that episode's scrollback and is not reported.
A pane notice showing a different clock, or any notice where the refusal recorded no reset or its reset has not passed, is reported as before, because a worker that parked again through the pane-only affordance the transcript never records leaves the pane as the only evidence there is.
The pane's newest reset clock is the one compared, so an old notice left above a fresh one cannot stand in for it.

Suppressing the pane whenever the transcript holds any resolved refusal would delete it instead of bounding it, and this is how much of the store that would delete it for, measured on 2026-09-20 from the repository root with the library's own helpers:

```sh
. bin/fm-allowance-lib.sh
anywhere=0 tail_refusal=0 resumed=0 suppressible=0
now=$(date -u +%s)
for f in ~/.claude/projects/*/*.jsonl; do
  grep -aq '"apiErrorStatus":429' "$f" && anywhere=$((anywhere + 1))
  if _fm_allowance_record_parked "$f" >/dev/null 2>&1; then
    tail_refusal=$((tail_refusal + 1))
  elif over=$(_fm_allowance_record_resumed "$f"); then
    tail_refusal=$((tail_refusal + 1))
    resumed=$((resumed + 1))
    reset=${over%%|*}
    case "$reset" in ''|*[!0-9]*) continue ;; esac
    [ "$reset" -le "$now" ] && _fm_allowance_reset_clock "${over#*|}" >/dev/null && suppressible=$((suppressible + 1))
  fi
done
echo "transcripts with a refusal record anywhere in the file:              $anywhere"
echo "transcripts with a refusal inside the last $FM_ALLOWANCE_RECORD_TAIL_LINES lines:                 $tail_refusal"
echo "  of those, the refusal was followed by a later turn (resolved):     $resumed"
echo "  of those, a recorded past reset and a reset clock to compare:      $suppressible"
# transcripts with a refusal record anywhere in the file:              105
# transcripts with a refusal inside the last 200 lines:                 58
#   of those, the refusal was followed by a later turn (resolved):     18
#   of those, a recorded past reset and a reset clock to compare:      18
```

The denominator matters, because two counts of this store disagree through counting different things.
The 105 counts every transcript holding a refusal record anywhere in the file, which includes refusals so old they have scrolled out of the last 200 lines the library reads, and those cannot affect the pane arm at all.
The predicate the pane arm acts on is decided over the last 200 lines only, so its denominator is the 58 transcripts with a refusal inside that tail, and 18 of those 58 hold a refusal a later turn followed.
A rule that shut the pane out whenever such a refusal was in view would therefore have removed the pane arm for those 18 workers whatever their pane showed, including a worker that parked again through the affordance the transcript never records.
The rule above removes it for such a worker only when the pane's newest reset clock is the one the resolved refusal named, which is a claim about one notice and not about the worker.
tests/fm-allowance-park.test.sh holds the shape that separates the two: a refusal, forty further turns so it is still inside the tail, and then a fresh park the transcript does not record.

### Resuming the park

Detecting a park and leaving it stopped is most of the cost.
On 2026-09-11 five workers parked at once, and the wake's wording told its reader to press Enter: `fm_backend_send_key <backend> <target> Enter` returned success for all five and moved none of them, because the refused turn had ENDED and a bare Enter submits an empty composer.
An ordinary steering message is what restarted them.
On 2026-09-20 three workers sat stopped overnight with their reset long past, restarted only when a person messaged each one by hand.

So [`bin/fm-allowance-resume-lib.sh`](../../bin/fm-allowance-resume-lib.sh) resumes a parked worker with a steering record on the ordinary inbox plane - which brings the existing re-ring ladder with it - once two gates pass:

| Gate | Source | Why it is there |
| --- | --- | --- |
| The recorded reset has passed by a `FM_ALLOWANCE_RESUME_GRACE_SECS` margin (120) | the refusal record's own `resetsAt` | Local and free, and the only gate that can veto a resume the provider read would wrongly allow. Unknown for a pane-only park, which never blocks on its own. |
| The provider reports headroom | `quota-axi --json`, `quotaSemantics.effectiveAvailability` | The authority. A message sent into an allowance that is still spent is consumed for nothing and the worker parks again on the same turn, so no positive evidence means no resume. |

A known scope reporting `runway.status` of `exhausted_now`, or zero remaining, is spent; a known scope with headroom and no spent sibling is ready; a missing, incompatible, timed-out or malformed read is unknown, which is not headroom.
The read is cached per home for `FM_ALLOWANCE_QUOTA_TTL` seconds so a fleet of parked workers costs one subprocess rather than one each.
The resume fires once per park episode per worker, keyed on the same recorded reset and notice the wake de-duplicates on.
A resume that did not take leaves the worker parked and refused again on an identical notice, so nothing reads it as unparked and clears the record of the attempt; that record ages out after `FM_ALLOWANCE_RESUME_RETRY_SECS` (1800), after which both gates are asked again and the worker is retried.

The resume runs inside the watcher's own poll, so it can only help while supervision is polling.
When the watcher is not running, or is not the build that carries this change, nothing resumes a parked worker, and the fixture tests below imply no cover for that case.

Deterministic entry point:

```sh
tests/fm-allowance-park.test.sh
```

Refresh command for the per-harness evidence above, which launches every installed harness bare and spends no model tokens:

```sh
FM_ALLOWANCE_PARK_DRIFT=1 tests/fm-allowance-park-live-e2e.test.sh
# ok - claude (2.1.241 (Claude Code)): store resolves at /home/<user>/.claude/projects/<mangled> and a healthy worker is not read as parked
# ok - every installed harness with a verified allowance signature was exercised
```

That guard proves the store derivation still lands where the harness writes and that a healthy worker is not classified as parked.
It deliberately does not prove that a real refusal still writes the matched fields, because forcing one means exhausting the account allowance, which is the outage this detection exists to shorten; that half is refreshed by capturing the next real refusal against the counts above.

### What the resume has and has not been proven against

Some of the scenarios the change claims were driven live against the product, and the rest are instrumented for a real event and unconfirmed until it arrives.
Those remaining scenarios need a real account-allowance refusal in a live session followed by a watcher that carries this change, and a refusal cannot be provoked without causing the outage this change exists to shorten, so no fixture is dressed up as a live verdict here.

Proven live, by the commands in this section:

- The store measurements above reproduce over the real `~/.claude/projects` store, by the crossing-rate and denominator commands recorded beside those claims.
- A healthy worker on the installed Claude Code is not read as parked and its session store resolves, by `FM_ALLOWANCE_PARK_DRIFT=1 tests/fm-allowance-park-live-e2e.test.sh`.

Proven live by one real park, on Claude Code 2.1.278 on 2026-09-20, captured end to end by the armed capture described below:

- A real refusal writes the fields the structural signal matches.
  The record, written at 13:15:43Z, is `type: assistant` with `isApiErrorMessage: true`, `apiErrorStatus: 429`, `error: "rate_limit"`, `message.model: "<synthetic>"`, `stop_reason: "stop_sequence"`, all usage counters zero, a single text block holding only the notice `You've hit your session limit · resets 2:20pm (UTC)`, and `quotaLimits` of `status: "rejected"`, `resetsAt: 1789914000`, `rateLimitType: "five_hour"`, `overageStatus: "rejected"`, `isUsingOverage: false`.
  The recorded `resetsAt` is 14:20:00Z and agrees exactly with the rendered `resets 2:20pm (UTC)`.
  The structural signal matched that record on every one of 923 polls, and the fixtures in `tests/fm-allowance-park.test.sh` now pin this measured shape rather than an assumed one.
- That live park took no write to its transcript for its whole duration, 13:15:47Z to 15:59:50Z, across the reset at 14:20:00Z; the capture followed the file by byte offset every ten seconds and never had a byte to record.
  So the record bound never dropped the verdict, `_fm_allowance_record_superseded` answering no on all 923 polls.
  This is one real park with no post-refusal writes observed, and it does not refute the historical mtime crossings measured above; it shows those were not produced during this park.
- The pane rendered the notice followed by `/upgrade to increase your usage limit.` above an empty composer, which confirms live the premise the resume rests on: the turn had ended, so a keystroke had nothing to submit.
- The unfixed watcher deployed at the time surfaced the park 12 seconds after the refusal and wrote its marker, then took no action, and no steering record arrived during the park, the last one predating the refusal by ten minutes.
  The worker sat parked for more than six hours past its own reset and was restarted by hand, so the defect this change exists to end was reproduced in the field while the change was being developed.

The detection, the recorded reset and the reset-has-passed gate were therefore proven against this real park.
One link in the resume chain is still unproven live, the provider-headroom probe: the capture did not record `quota-axi`, so only the fixtures, which stub it, speak to that gate.

Proven against fixture transcripts and panes only, by `tests/fm-allowance-park.test.sh`, which stubs `quota-axi`:

- A parked worker is resumed by a steering message exactly once, only after its reset has passed and `quota-axi` reports headroom.
- A resume that did not take is retried after the true reset, including when the same notice text recurs.
- `fm-crew-state.sh` stops reporting a park once the worker has worked past its reset, and still reports a real park.
- A fresh pane-only park is still surfaced when an old resolved refusal sits in the last 200 transcript lines.
- A worker whose transcript moved past its reset is neither surfaced nor messaged, whatever its pane still shows.

Still awaiting live evidence are the resume actually firing, the retry after a resume that did not take, the state reader clearing on a live worker, and both adversarial cases listed above.
What would prove them is a watcher carrying this change running through one real park.

An armed capture records that occurrence in the operating home's per-task `data/` directory, outside version control, polling every ten seconds against the live workers, and its `capture.sh` header documents each field.
For each real refusal it records the refusal record verbatim with whatever timestamps it carries, the pane notice as rendered, every later write to the transcript with each record's type, and the arrival and count of steering records at the reset.
On every poll it also records the verdict of this change's own functions against the real transcript and the real pane, from a copy of the library pinned at commit `b22a0701230f328454249738e189efbeccd5b179`.

The watcher deployed in the operating home does not carry this change, so what the capture records at the reset is what the UNFIXED fleet does, which is how the park above went unresumed.
That confirms the defect and does not validate the resume.
The pinned-library verdicts are what speak to the detection and gating half of the fix, and the resume itself stays unconfirmed against a real park until a watcher carrying this change runs through one.

## Turn-end guard

The blocking and bounded-follow-up mechanisms were validated across seven harnesses on 2026-07-08 through 2026-09-05, with Claude's replacement Stop-owned path revalidated on 2026-07-24, Cursor's stop-hook park validated on 2026-08-13, and omp's blocking `session_stop` hook validated on 2026-09-05.

| Harness | Version verified | Mechanism | Observed result |
| --- | --- | --- | --- |
| Claude | 2.1.219 | Cooperative blocking `Stop` guard plus `asyncRewake` auto-arm | A fresh unsupervised session ran session start first, reclaimed a stale dead-owner lock, completed two tokenless rewake cycles with no model arm command or guard continuation, and left a competing live owner unchanged. |
| Codex | 0.142.1 | Blocking `Stop` hook | Hook process root stayed anchored to the trusted checkout and one continuation ran. |
| OpenCode | 1.17.6 | Passive `session.idle` callback | Throwing could not block, while `promptAsync` scheduled one TUI follow-up; headless remained fail-open. |
| Pi | 0.80.5 | Passive `agent_settled` callback | Exactly one guard follow-up ran for an unhealthy cycle, with no recursion across tool turns. |
| omp | 18.1.11 | Blocking `session_stop` hook returning `{ continue: true, additionalContext }` | In the isolated rpc lab (2026-09-05), the successor watcher was frozen with `SIGSTOP` until its beacon passed the lab `FM_GUARD_GRACE` of 20s while its arm child stayed attached (a killed watcher closes its arm child and the extension re-arms before the guard can fire); the next turn end raised the guard, the guard spy recorded `rc=2` followed by a stop carrying `stop_hook_active: true`, omp compelled a continuation carrying the `turn-end-guard` operational text, the `fm_watch_arm_omp` invocation count then rose to at least two, and a live watcher held the home lock after the thaw; the flagged stop was allowed, so exactly one continuation ran. `session_stop` never fired for an interrupted turn. |
| Grok | 0.2.112 native and 0.2.73 pre-native | Running-payload adaptive `Stop` | Native false-to-true continuation stayed in one process with two model turns and zero resume launches; the field-absent pre-native process launched exactly one guarded resume. |
| Cursor | 2026.08.11-e8db854 | Awaited `stop` hook park returning one `followup_message` | Exit 2 ended the turn normally, proving it cannot block; a returned follow-up ran a genuine second turn; a sleeping hook held the boundary open and the wake landed after it; `loop_limit` stopped the hook being invoked at its ceiling. |

### Cursor primary park, 2026-08-13

Cursor was validated as a primary on 2026-08-13 against the installed CLI on macOS 26.5.2 arm64 with tmux 3.6a, in a throwaway firstmate home on a private tmux socket, never against a live home and never with a user-scope hook.

Mechanism facts established first, in a separate throwaway workspace:

| Question | Method | Result |
| --- | --- | --- |
| Can `stop` block? | hook exits 2 | No. The turn ended normally; Cursor's blocked-response mapper returns `{}` for the `stop` step. |
| Can `stop` force one turn? | hook returns `{"followup_message":...}` | Yes. A genuine second turn ran and answered. |
| Can `stop` park? | hook sleeps, then returns a follow-up | Yes. It is awaited; a 20s sleep held the boundary and the follow-up landed after it. |
| What is `loop_count`? | four consecutive follow-ups, then a real user message | `0,1,2,3`, then `0` again. It counts follow-up-driven stops since the last real user message. |
| Does `loop_limit` bind? | `loop_limit: 2` with an always-follow-up hook | Yes. The hook was invoked at `loop_count` 0 and 1 and never at 2. |
| Does a captain message terminate an existing park? | captain message typed during a 600s park | No. Cursor leaves the park running, and without a baton an older park can still deliver after the captain turn's next `stop` has started another park. |
| Does Cursor load `.claude/settings.json`? | Claude-shaped `SessionStart`, `PreToolUse`, `Stop` in the same workspace | `SessionStart` and `PreToolUse` fired with a CURSOR-shaped payload carrying `cursor_version`; `Stop` did not fire. |

The integration itself is exercised by the opt-in guard:

```sh
FM_CURSOR_PRIMARY_LIVE_E2E=1 tests/fm-cursor-primary-live-e2e.test.sh
```

Observed output:

```text
harness: cursor-agent 2026.08.11-e8db854
ok - cursor primary: the sessionStart hook takes the fleet lock as the Cursor process itself
ok - cursor primary: the run-tier session start completes every stage
ok - cursor primary: sessionStart additional_context reaches model context before the first turn
ok - cursor primary: the stop-hook park delivers a real watcher wake as one follow-up
ok - cursor primary: the park owns exactly one arm cycle with a live watcher beacon
ok - cursor primary: the captain keeps control and the older park stands down after the next stop claim
ok - cursor primary: an away-mode escalation is delivered, confirmed, and processed
```

The live run proved that session start acquires the fleet lock through Cursor's structural process identity in `bin/fm-cursor-lib.sh`; `tests/fm-session-lock-ancestry.test.sh` pins the same ancestry path portably.
It also proved that Cursor's `autoarm` supervision model lets the mid-turn pull guard accept a fresh beacon after the between-turn watcher closes; `tests/fm-guard-stale-banner.test.sh` pins that model-aware verdict.
The baton is claimed only by the next `stop`, so an actionable close before that claim can still produce one real follow-up from the sole existing park; durable wake handling is idempotent, and any older park still running after the claim stands down.
Cursor's `beforeSubmitPrompt` step could close that exact window because it fires once on a real captain message and not on hook-driven follow-ups, but registering it is deliberately deferred alongside `preCompact`.

Away-mode delivery needed no daemon change once the composer reader was correct for Cursor; [`runtime-backends.md`](runtime-backends.md#composer) owns that evidence.

Cursor compaction instruction refresh is DEFERRED and not shipped, so a Cursor primary does not re-emit its digest after a compaction.
Two static facts decided that: `PreCompactRequestResponse` carries only `user_message`, and `preCompact` is absent from the `additional_context` step set (`index.js` @ 4814884), so the step cannot inject a digest and any delivery has to be routed through a later boundary.
A staged-then-delivered design is rejected because carrying a digest across two concurrently running `stop` hooks can deliver it twice or strand it indefinitely, while closing those races enlarges a critical section inside a hook Cursor awaits at the turn boundary.
Native `preCompact` firing was not observed because a real compaction could not be forced in the isolated session, so the surface has no empirical basis yet.
It is therefore recorded as uncovered in the same sense as the Codex interactive TUI, and `tests/fm-cursor-primary.test.sh` asserts `preCompact` stays unregistered so it cannot return unnoticed without its own design and evidence.

The Grok adaptive matrix ran on 2026-07-28 with separate scratch repositories and homes, dedicated tmux sockets, one target plus one control window, ambient tmux variables removed, and a socket-bound wrapper first in `PATH`.

```sh
FM_GROK_STOP_LIVE_E2E=1 \
  FM_GROK_NATIVE_BIN="$native_grok_0_2_112" \
  FM_GROK_LEGACY_BIN="$official_pre_native_grok_0_2_73" \
  tests/fm-grok-stop-live-e2e.test.sh
```

Observed bounded output:

```text
ok - grok 0.2.112 (9bbd559437aa) [stable] native Stop kept one session across false->true, two model turns, and zero resume processes
ok - grok 0.2.73 (9ff14c43bbe5) [stable] legacy Stop omitted capability, resumed exactly once, and stopped normally
ok - Grok adaptive Stop real-process matrix passed with exact target cleanup and control-window survival
```

The same run proved the Claude-compatible Stop entries stay inert under `GROK_AGENT`, the legacy resume carries `GROK_TURNEND_GUARD_ACTIVE=1`, and every replacement root is removed after exact target cleanup while its control window survives.
That inertness result is scoped to the builds it exercised: it did not establish that `GROK_AGENT` reaches a Grok HOOK process, and on grok 1.0.0 it does not, so the marker set was widened to `GROK_HOOK_EVENT` as well (docs/turnend-guard.md "Harness integrations").
`tests/fm-turnend-guard.test.sh` now pins every tracked `.claude/settings.json` hook entry against a real grok 1.0.0 hook environment so the inertness contract is covered deterministically rather than only by the opt-in live matrix.

The secondmate-home scope and manual-repair wake path were measured with Claude Code 2.1.207 on 2026-07-12, when a native background completion re-invoked the idle model with no human input.
The current Stop-owned main/secondmate inclusion and child-worktree exclusion are covered deterministically by `tests/fm-claude-stop-autoarm.test.sh`.
Session-lock ownership in `bin/fm-session-lock-lib.sh` is decided against a session's whole contiguous harness ancestry rather than one chosen pid, so the Stop auto-arm reaches its lock owner wherever that owner sits: the outermost pid of Claude Code's multi-level `bg-spare` hook worker chain, or an inner pid when a harness-named daemon parents the session.
Harness identity is read from the executable path and `argv[0]` as well as the command basename, because Claude Code's native installer names the per-session executable by its version (`.../share/claude/versions/2.1.220`): `ps -o comm=` reports that path on macOS and the bare version string on Linux, and neither basename names a harness.
`tests/fm-session-lock-ancestry.test.sh` pins both platforms' reporting semantics behind a deterministic process table and runs the real Stop auto-arm in version-named, daemon-parented, and combined real process trees.
`tests/fm-watch-arm.test.sh` runs real watcher and arm cycles against durable on-disk state to verify that a delivered reason survives until post-handling acknowledgement and stops replaying after acknowledgement, while an unrelated queue append cannot make a watcher cycle that delivered nothing look successful.
The same suite ingests a keyed remote-secondmate parent reply through the real adapter, establishes the incremental OPEN DECISIONS cursor, interrupts supervision, and proves re-arm replays every unacknowledged queue row plus the still-open decision through the ordinary drain path.
It also covers decision-only recovery, interrupted handling, handling-window generation reuse, non-fatal moved-generation acknowledgement with sequence-bounded consumption, and a persistent successor remaining live after recovery is acknowledged.

The Claude product live path ran with Claude Code 2.1.219 on 2026-07-24:

```sh
claude --version
FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh
```

Observed output:

```text
2.1.219 (Claude Code)
ok - Claude 2.1.219 (Claude Code) live E2E reclaimed a stale session lock through session start, completed two tokenless Stop-owned rewake cycles, and preserved the competing-live-owner boundary
```

Current entry points:

```sh
tests/fm-turnend-guard.test.sh
tests/fm-supervision-instructions.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
FM_GROK_STOP_LIVE_E2E=1 FM_GROK_NATIVE_BIN="$native_grok" FM_GROK_LEGACY_BIN="$pre_native_grok" tests/fm-grok-stop-live-e2e.test.sh
```

The Claude auto-arm false-failure, guard-predicate, and monotonic bounded fail-open correction was verified on 2026-08-02 with the installed ShellCheck 0.11.0 and isolated behavior suites.

```sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
bin/fm-test-run.sh tests/fm-claude-stop-autoarm.test.sh tests/fm-guard-stale-banner.test.sh tests/fm-turnend-guard.test.sh tests/fm-supervision-instructions.test.sh
```

Observed output:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-doc-audience-check: ok surfaces=61 local_links=174
FM_TEST_SUMMARY total=4 failed=0 skipped_gate=0 duration_ms=102585
```

The fresh-beacon portion of the model-aware pull-guard predicate (`bin/fm-guard.sh` accepts a beacon within grace without a live watcher under the Claude Stop auto-arm model) was verified on 2026-08-04 with the installed ShellCheck 0.11.0 and the same isolated behavior suites.

```sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
bin/fm-test-run.sh tests/fm-claude-stop-autoarm.test.sh tests/fm-guard-stale-banner.test.sh tests/fm-turnend-guard.test.sh tests/fm-supervision-instructions.test.sh
```

Observed output:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-doc-audience-check: ok surfaces=64 local_links=188
FM_TEST_SUMMARY total=4 failed=0 skipped_gate=0 duration_ms=80078
```

The Pi extension-model pull-guard correction (`bin/fm-guard.sh` no longer reports a false watcher-down on a Pi primary during the extension's own watcher hand-off) was verified on 2026-08-13 with the installed ShellCheck 0.11.0 and isolated behavior suites.
The guard verdict itself reads only state files and process liveness, so the portable suites are the enforcing evidence; `bin/fm-harness.sh`'s Pi marker detection, which selects the model, is exercised in the same suite through `PI_CODING_AGENT`.

```sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
bin/fm-test-run.sh tests/fm-guard-stale-banner.test.sh tests/fm-turnend-guard.test.sh tests/fm-session-start.test.sh tests/fm-pi-watch-extension.test.sh tests/fm-watch-arm.test.sh
```

Observed output:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-doc-audience-check: ok surfaces=67 local_links=243
FM_TEST_SUMMARY total=5 failed=0 skipped_gate=0 duration_ms=280160
```

The same correction was verified against a live Pi primary's own supervision evidence on 2026-08-13.
The hand-off was captured live at beacon age 63s, then the home's `state/.lock`, `state/.last-watcher-beat`, both `state/.pi-*-extension-loaded` markers, and both `.pi/extensions/*.ts` builds were copied into an isolated fixture with no watcher lock.
The fixture's copied beacon was fresh at 0s in the output below; the deterministic stale-beacon case separately verifies the grace boundary.

```sh
FM_SUPERVISION_MODEL=persistent FM_GUARD_READ_ONLY=1 bin/fm-guard.sh
FM_SUPERVISION_MODEL=extension FM_GUARD_READ_ONLY=1 bin/fm-guard.sh
```

Observed output, before and after the model correction, then with the recorded Pi session pid replaced by a dead one:

```text
●  WATCHER DOWN - SUPERVISION IS OFF
●  1 task(s) in flight, but no live watcher process holds this home lock (last beat: 0s ago).
(silent)
●  WATCHER DOWN - SUPERVISION IS OFF
●  1 task(s) in flight, but no live watcher process holds this home lock (last beat: 0s ago).
```

The broader relevant regression pass was rerun on 2026-08-02 without live-home or daemon mutation.

```sh
bin/fm-test-run.sh tests/fm-watch-triage.test.sh tests/fm-watcher-lock.test.sh tests/fm-afk-inject-e2e.test.sh tests/fm-afk-return.test.sh tests/fm-x-mode.test.sh tests/fm-backend.test.sh tests/fm-backend-tmux-smoke.test.sh tests/fm-secondmate-safety.test.sh
```

Observed output:

```text
FM_TEST_SUMMARY total=8 failed=0 skipped_gate=0 duration_ms=617507
```

The actionable-close ordering correction was reverified on 2026-08-02 against an identity-matched live successor.

```sh
tests/fm-claude-stop-autoarm.test.sh >/dev/null && echo "fm-claude-stop-autoarm: ok"
```

Observed output:

```text
fm-claude-stop-autoarm: ok
```

### Claude Stop claim publication ordering, 2026-08-18

Repeated silent supervision drops in the primary home on 2026-08-17 and 2026-08-18 were reproduced end to end against Claude Code 2.1.234 with the real tracked Stop registration, then driven to one cause.
Two reported premises were disproven by measurement before any fix was written.
The `asyncRewake` sibling fires within about a millisecond of the blocking hook and runs to completion even when that sibling exits 2, so the auto-arm was never absent.
The exit-2 continuation turn does not start until the outstanding `asyncRewake` hook completes, observed as a block at 941.25s, the async hook ending at 961.92s, and the first model tool call at 965.90s, so the next turn's start does not race the arm.

What did happen is a visibility window.
In the instrumented lab the guard printed its blind-turn banner and exited 2 on two consecutive cycles while the auto-arm was healthy and completed successfully in the same event, recording `epoch=2 outcome=rewake` and then `epoch=4 outcome=rewake`.
The identity gate's ancestry walk measured 1.375 to 1.624 seconds live and 8.857 seconds under xtrace, the gate as a whole 0.946 to 3.511 seconds, and the auto-arm's first durable evidence at 11.300 seconds under xtrace, against a nominal 800 millisecond cooperative window.
A sampler run measured the owner lock appearing at +1.70s and its `autoarm` role at +1.77s while the guard gave up at +1.81s, a 20 millisecond margin.
The guard's own wait was an iteration count over fork-heavy passes, so it ran for 2.87s and 29.85s on those two cycles for the same nominal 800 milliseconds.

Three field samples from the primary home bound the window from the other side, each taken by inspecting durable records moments after the guard printed that no recovery was under way.
Two on 2026-08-21 fired at 390 and 297 seconds of beacon staleness, and one on 2026-08-22 at 03:42 UTC fired at 815 seconds, all with seven tasks in flight.
In the third the epoch ledger recorded `epoch=1041 owner_pid=1108506 outcome=arming` written in the same second the guard declared the home unclaimed, that pid alive, both the arm wrapper and the watcher live at 40 and 39 seconds old, and the beacon 35 seconds old.
The spread rules out a near-threshold beacon and therefore a threshold-tuning fix: the staleness was genuine at every sample, and the auto-arm healed it within the same second regardless of how stale the beacon had become.
It also shows the `arming` outcome reaching the ledger while the guard was still reporting the home unclaimed, which is the case the guard's pre-fix outcome filter dropped.

An unrelated firstmate home reported the same defect independently on 2026-08-22, which is what establishes it as structural rather than local to one home or to any load condition there.
That home saw the banner fire six times in one session and be wrong every time, quoting beacon ages of 168, 422, 697, 1001 and 214 seconds where the ages measured immediately afterwards were 3 to 21 seconds, with the rewake counter advancing across every firing, exactly one monitor pair scoped to that home live, and no failure marker present.
It reached the same mechanism from its own evidence: the guard samples beacon age and claim status at the turn boundary, before the recovery hook firing on that same boundary has claimed the home, so it reports a state that is already obsolete when the reader sees it.
It also separated this defect from the wake-queue lock deadlock, because nothing deadlocked and recovery always completed on its own.

The cost that makes this worth fixing is that a false alarm every time makes a genuine failure indistinguishable from the noise, so the fix must not buy quiet by weakening the predicate.
No arm, no live watcher and no claim still blocks loudly, pinned by the re-block, dead-publisher, X-mode, stale-epoch, and exhausted-budget cases in `tests/fm-turnend-guard.test.sh`.

The portable regression reproduces that window with real concurrent processes rather than fixtures, parking a real auto-arm inside its identity gate behind a `ps` shim and asking the guard for a verdict with the claim as the only evidence on disk.

```sh
tests/fm-turnend-guard.test.sh
```

Observed output, last four lines:

```text
ok - fm-turnend-guard --claude: the early claim is the whole difference in the pre-identity window (incident regression)
ok - fm-turnend-guard --claude: an in-progress claim is trusted only while its publisher is alive and unchanged
ok - fm-turnend-guard --claude: a fresh arming epoch with no live arm, watcher or claim still blocks
ok - fm-turnend-guard --claude: the cooperative wait is bounded by elapsed time, not by a pass count
```

Each of the four fails against an unpacked pre-fix tree, checked by running them there one at a time:

```text
not ok - no in-progress claim appeared before the auto-arm's identity gate: firstmate watcher auto-arm FAILED - the Stop-owned automatic supervision mechanism is broken after 2 bounded attempts, and no live watcher with a fresh beacon was verified.
not ok - a live identity-matched claim must be accepted as recovery under way: expected exit 0, got 2
not ok - --claude must force a turn against a fresh arming epoch with no live arm, watcher, or claim: expected exit 2, got 0
not ok - the cooperative wait spent 24818ms of 3s sleeps for an 800ms budget (baseline 1887ms, total 26705ms): it is counting passes, not elapsed time
```

The harness-emitted half is the opt-in live guard, which now runs its whole session behind a shim that costs every pid query a fixed slice, so the identity gate reliably outlasts the cooperative wait.
The run below recorded 86 delayed pid queries and no forced continuation.

```sh
FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh
```

Observed output:

```text
ok - Claude 2.1.234 (Claude Code) live E2E reclaimed a stale session lock through session start, completed two tokenless Stop-owned rewake cycles under a loaded identity gate, and preserved the competing-live-owner boundary
```

Two adjacent defects were repaired in the same change rather than left silent.
`bin/fm-test-run.sh --check-coverage` compared `LC_ALL=C sort` inventories with a locale-sensitive `comm`, so it warned and failed on any host whose locale is not C; it now reports `FM_TEST_COVERAGE ok total=149 parallel=24 serial=113 serial_shards=4 herdr=12` under `en_US.UTF-8`.
The live auto-arm regression still asserted that the model types the session start command, which the run-tier `SessionStart` hook has made unnecessary, so it could not pass at all; it now asserts that session start ran for that home and that the model issued exactly its two wake drains.

The repo lint gate completes here once actionlint is installed, and did on 2026-08-22.

```sh
bin/fm-lint.sh
```

Observed output, exit 0:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-lint-workflows.sh: actionlint 1.7.12 (pinned 1.7.12)
fm-lint-workflows.sh: 3 workflow files valid
```

An earlier run of the same gate on 2026-08-18 exited 127 because actionlint was absent from that host, which was a missing tool rather than a result.
`tests/fm-test-run.test.sh` still cannot complete on this host because its CI YAML assertion requires ruby, which is absent.


### What the cooperative wait budget does and does not bound, 2026-08-22

The first version of the elapsed-time regression asserted the hook's TOTAL wall clock, which made it assert fixed cost rather than the defect and fail under load.
Measured on the same fixture, varying only the budget, three runs each:

```text
FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=0      5889 4861 5386 ms
FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100    5017 5671 5374 ms
FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=800    6642 7148 6243 ms
FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=3000   6754 6698 7372 ms
```

A budget of zero forbids every retry, so the roughly 5 seconds it still spends is fixed cost the hook pays regardless: sourcing its libraries, the primary-scope checks, and on the blocking path the budget accounting and banner.
The budget therefore bounds the retrying only, and `docs/turnend-guard.md` "Claim publication ordering" states that limit rather than claiming the hook completes within the budget.

The regression now measures the difference between a zero budget and the real one on the same host, which is exactly what the wait spent, behind a `sleep` shim charging 3 seconds per interval:

```text
base_ms=2595 waited_ms=6924 delta_ms=4329
base_ms=4389 waited_ms=6645 delta_ms=2256
base_ms=3064 waited_ms=7337 delta_ms=4273
```

A deadline-bounded wait spends one shimmed interval past its budget; the pass-count loop this replaced would spend `SYNC_WAIT_MS/100` of them, eight here for 24 seconds, so the assertion's three-interval ceiling separates the two by more than a factor of two in both directions.

## Watcher continuity

The cross-harness evidence combines the 2026-07-17 live pass with Claude's replacement Stop-owned path revalidated on 2026-07-24, all against isolated project and home state.
No credential material was copied into a fixture.

```text
Claude Code 2.1.219
codex-cli 0.144.4
OpenCode 1.17.18
Pi 0.80.10
grok 0.2.103 (89c3d36fb6f1) [stable]
```

| Harness | Exact opt-in command | Observed guarantee |
| --- | --- | --- |
| Claude | `FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` | Session start reclaimed a stale owner before two Stop-owned cycles, and a competing live owner prevented arm, rewake, epoch write, or lock replacement. |
| Codex | `FM_CODEX_LIVE_E2E=1 tests/fm-codex-continuity-live-e2e.test.sh` | The one-second foreground checkpoint returned without switching to the arm wrapper. |
| OpenCode | `FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh` | A verified successor existed before prompt handling, with no model re-arm or turn-end fallback. |
| Pi | `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` | One initial tool call led to extension-owned successors and clean child retirement on exit. |
| omp | `FM_OMP_LIVE_E2E=1 tests/fm-omp-primary-live-e2e.test.sh` | One initial `fm_watch_arm_omp` invocation (the openai-codex model reaches extension tools through omp's `xd://` virtual-file bridge, a `write` to `xd://fm_watch_arm_omp`, counted as the same invocation) started a live watcher; an actionable close spawned a ledger-linked successor and woke main exactly once; the lab is reaped by path, and omp 18.1.11 did not exit within 30s of its rpc stdin closing, recorded as a note. omp 18.1.11, 2026-09-05. |
| Grok | `FM_GROK_LIVE_E2E=1 tests/fm-grok-continuity-live-e2e.test.sh` | Native task completion surfaced the actionable close and the cycle ledger recorded `reason=actionable-signal`. |

Pi 0.81.1 repeated the continuity and clean-exit lifecycle on 2026-07-23 after the Calm presentation changes.

Pi same-process session-transition ownership was verified on 2026-09-01 against the tracked extension with provider-free public lifecycle events, retained and fresh extension-module rebinds, and real arm children:

```sh
pi --version
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
```

Observed guarantee: after ordinary `session_shutdown` for `/new`, `/resume`, `/fork`, and reload, plus same-instance shutdown-plus-start, an owning `session_start` armed the replacement generation before any model turn and without the `watcher: not armed - Pi session is shutting down` refusal.
A fresh module rebind also received exactly once the actionable close whose first delivery was still in flight at shutdown, while retaining one live successor.
Stale prior-generation tool callbacks could not mutate the active child, repeated transitions kept exactly one live arm cycle, and terminal `quit` still refused late rearm.
The strict no-emit check used the installed Pi SDK declarations to hold the lifecycle event contract.
Plain Pi and pi-signed share the same tracked `.pi/extensions/fm-primary-pi-watch.ts` path, so both inherit the generation owner; other primary harnesses are not applicable because they do not use this Pi extension lifecycle.

On 2026-09-02 the same suite, the strict typecheck, and the credential-free real-SDK guard were rerun against `@earendil-works/pi-coding-agent` 0.84.4 after the extension stopped waiting for `before_agent_start` before settling a main delivery; [`runtime-backends.md`](runtime-backends.md#2026-09-02-streaming-time-watcher-delivery) owns the exact commands and output.
Observed guarantee: a wake delivered while main was streaming was followed by a verified successor and by delivery of the next actionable close, a replacement replayed only the follow-up Pi had not consumed, an exhausted restoration delivered its typed failure without launching an arm past the retry bound, and a verified successor that failed while a branch settlement still held its wake took the ordinary bounded retry once that delivery settled.

The once-per-generation recovery bound and immediate handling-successor poll were verified on 2026-08-21 with the tracked Pi extension, real watcher processes, and an isolated home.
The regression forced handling confirmation to fail, observed one recovery follow-up across the former repeat window, confirmed the successor remained live, and then proved a separate handling successor durably queued a crew event within the bounded poll window.

```sh
bin/fm-test-run.sh tests/fm-watch-recovery-loop.test.sh
```

Observed output:

```text
ok - a resurfacing handling successor stays alive and supervises instead of going blind
ok - unacknowledged recovery is announced at most once per generation and the successor stays alive
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=59357
```

Deterministic entry points:

```sh
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-watcher-lock.test.sh
tests/fm-watch-arm.test.sh
tests/fm-watch-recovery-loop.test.sh
tests/fm-wake-queue.test.sh
tests/fm-subagent-pretool-check.test.sh
tests/fm-claude-stop-autoarm.test.sh
tests/fm-turnend-guard.test.sh
```

## Wedge-alarm channels

The two real notification channels were bounded manually on 2026-07-10 on macOS 26.5.2 with Herdr 0.7.3.
Automated suites never execute these real notification commands.

Argv-safe Notification Center command:

```sh
/usr/bin/osascript \
  -e 'on run argv' \
  -e 'display notification (item 1 of argv) with title "FIRSTMATE TEST - IGNORE" sound name "Basso"' \
  -e 'end run' \
  'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)'
```

Observed output: no stdout, exit 0, and one banner with the supplied body.

Herdr command:

```sh
herdr notification show 'FIRSTMATE TEST - IGNORE' \
  --body 'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)' \
  --sound request
```

Observed output:

```json
{"id":"cli:notification:show","result":{"reason":"shown","shown":true,"type":"notification_show"}}
```

The safe command-channel contract is covered without a notification by `tests/fm-daemon.test.sh`: the summary reaches both `$1` and stdin, every channel is process-group bounded, and a failed channel falls through.
