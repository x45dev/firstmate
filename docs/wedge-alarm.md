# Away-mode injection wedge alarm

The away-mode sub-supervisor (`bin/fm-supervise-daemon.sh`) buffers escalations and injects them into Firstmate's own pane.
When injection cannot confirm a submit past `FM_MAX_DEFER_SECS`, `inject_wedge_alarm` raises a loud, rate-limited alarm so the stall never stays invisible.
The active alert is pane-independent because a tmux status-line flash has no cross-backend equivalent and cannot reach an unattended captain reliably.
The durable marker and tmux flash remain as additional signals.

The marker, the flash, and the alert summary are written in outcome language on purpose.
When every other channel has failed these are the only things that reach the captain, so each one states how many updates are waiting, how long they have waited, why delivery failed, and that nothing has been lost.
`bin/fm-composer-lib.sh`'s `fm_composer_verdict_reason` is the single owner of the delivery-failure wording, so the daemon never carries a second copy of that vocabulary.

## Channels

`config/wedge-alarm` is local and gitignored.
It lists channel directives, one per non-empty, non-comment line, and every listed non-`off` channel fires best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with one directive for focused testing.

- `off` disables every active alert while retaining the durable marker and tmux flash.
- `auto` or `default` resolves to `osascript` on macOS and `notify-send` on Linux, each only when its binary is present.
  Any other platform, and a host missing that binary, resolves to no channel at all; configure `command:` there.
- `osascript` posts a macOS Notification Center banner outside the terminal pane.
- `notify-send` posts a Linux libnotify desktop notification outside the terminal pane.
- `herdr` calls `herdr notification show` outside the supervised pane.
- `command:<cmd>` runs `<cmd>` through `sh -c` with the alarm summary as `$1` and on stdin, allowing delivery to a phone or pager service.

An absent `config/wedge-alarm` behaves as `auto`, which is default-on wherever the platform has a reachable channel.
This is deliberate because the alarm fires only after a genuine max-defer wedge and is rate-limited to at most once per max-defer window.

An OS banner only reaches a captain who is at the machine, which the away posture frequently is not, so `command:` remains the route to a phone or pager.
A host with no resolvable channel is the case the bounded escape below exists for.

Each channel is best-effort.
A missing binary or non-zero exit logs a warning and continues to the next channel without crashing the daemon loop.
Every invocation is process-group bounded by `FM_WEDGE_ALARM_TIMEOUT_SECS`, which defaults to 10 seconds, including `command:`, `osascript`, `herdr`, and the test seam.
On timeout or daemon shutdown, the notifier process group is terminated and the next configured channel may run.
AppleScript receives the summary as an argv item rather than interpolated source, so summary text cannot alter the script.
See [`examples/wedge-alarm`](examples/wedge-alarm) for a copyable config.

## The bounded escape

An alert channel that reaches nobody used to be indistinguishable, to the daemon, from one that reached the captain, so the daemon kept deferring in silence for as long as the stall lasted.
`wedge_alarm_notify` now reports `delivered`, `disabled`, or `unreached` in `WEDGE_ALARM_LAST_DELIVERED` while still always returning 0, and `unreached` is what arms the escape.

After `FM_WEDGE_UNREACHED_WINDOWS` consecutive undelivered windows whose alert reached nobody (default 3), `escalate_unreached` hands the buffered updates to the home's durable wake queue as one `check` wake.
The wake queue is the escape because it needs nothing that is broken in this situation: no pane, no input box, no alert channel, and no configuration.
A queued row stays durable until acknowledged and is presented as the first work queue by the next wake drain, the next session start, and the away-return brief, so the escalation reaches the captain through whichever surface they open first instead of only through the one that is stalled.

The escape is bounded in both directions.
It arms only after the alert has demonstrably reached nobody that many windows in a row, and it fires at most once per stall, so a ten-hour stall queues one row rather than one per window.
An alert the captain turned `off` reports `disabled` and never arms it, because that silence is what they asked for.
A successful delivery ends the episode, so the next stall counts from zero.
The episode counters live in the daemon process rather than on disk, which is why a daemon restart begins a new episode and why they need no entry in the away delivery-artifact lifecycle that `bin/fm-afk-start.sh`, `bin/fm-afk-launch.sh`, and `bin/fm-afk-return.sh` each clear by name.

## Test safety

Every notifier routes through `FM_WEDGE_ALARM_EXEC` in `wedge_alarm_emit`.
When the daemon is sourced as a library, that seam defaults to `discard`, so a test cannot accidentally post a real notification.
`tests/wake-helpers.sh` replaces it with a recorder when a suite needs to assert channel selection and summary propagation.
Production leaves the seam unset and uses the configured real channels.

`tests/fm-daemon.test.sh` covers directive parsing, rate limiting, timeout and process-group cleanup, argv-safe dispatch, channel fallback, and safe `command:` summary delivery.
It also pins the delivery verdict for each channel outcome, the bounded escape's arming bound and its once-per-stall ceiling, that a reachable channel never escapes, and the marker's outcome wording.
[`verification/supervision.md`](verification/supervision.md#wedge-alarm-channels) records the bounded manual macOS and Herdr channel proof, the deterministic evidence for the Linux channel and the bounded escape, and the fact that the Linux banner itself is not yet banner-proven on a host carrying libnotify.
