# shellcheck shell=bash
# fm-allowance-resume-lib.sh - the ONE owner of RESUMING a worker parked on the
# ACCOUNT allowance. bin/fm-allowance-lib.sh owns the verdict; this file owns
# what supervision does about it.
#
# Why supervision resumes rather than reports: the park surfaced as a named wake
# from 2026-08-17 onward, and a wake is only as good as the reader. On 2026-09-11
# five workers parked at once and the wake told the reader to press Enter; on
# 2026-09-20 three sat stopped overnight with their reset long past and were
# restarted by hand. Surfacing a condition nothing acts on leaves the fleet
# stopped for exactly as long as it takes somebody to notice.
#
# Why the resume is a MESSAGE and not a keystroke: the refused turn ENDED. The
# composer is empty, so a bare Enter submits nothing - measured on 2026-09-11,
# where `fm_backend_send_key <backend> <target> Enter` returned success for all
# five parked workers and all five stayed stopped, their panes still showing the
# limit notice over an empty composer. What restarted them was an ordinary
# steering message. So this writes a durable steering record and rings its
# doorbell, which is the same plane every other firstmate steer rides, and which
# brings the watcher's existing re-ring ladder with it for free: a resume the
# first ring does not land is re-rung and eventually escalated by machinery that
# already exists, rather than by a retry loop invented here.
#
# Two gates, and the resume fires only when both are satisfied:
#
#   recorded reset  The absolute reset the refusal record itself carries
#                   (fm_allowance_record_reset_epoch). Local, free, and exact -
#                   but only for a park detected from a transcript, since a
#                   pane-only park has no record to read. An unknown reset is
#                   therefore not a blocker on its own; the provider gate below
#                   still has to pass, and it answers the same question.
#   provider        quota-axi's own effective-availability read. This is the
#                   authority: a message sent into an allowance that is still
#                   spent is consumed for nothing and the worker parks again on
#                   the same turn, so NO positive headroom evidence means no
#                   resume. An unreadable, incompatible, or missing quota-axi is
#                   not headroom; it reports unknown and the park stays surfaced
#                   for its reader rather than being messaged on a guess.
#
# The two gates are deliberately not redundant. The provider read alone would be
# enough to be correct, but it is a subprocess against a vendor CLI, while the
# recorded reset is a field already in a file this poll read; checking it first
# is what keeps a fleet of parked workers from asking the provider anything at
# all until at least one of them could plausibly be resumable.
#
# The provider read is cached fleet-wide per provider for a short TTL, because a
# fleet of N parked workers asks the same question about one account and must not
# cost N subprocesses per poll.
#
# Sourcing: set -u and set -e safe, and self-sufficient - it pulls in the verdict
# owner it extends and the two shared libraries the provider read needs, so a
# caller cannot half-source it. jq is the one dependency it cannot supply; its
# absence reports unknown rather than guessing.

# shellcheck source=bin/fm-allowance-lib.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-allowance-lib.sh"
# Bounded execution is fm-timeout-lib.sh's alone, and the quota-axi version floor
# is fm-quota-axi-lib.sh's alone; source both rather than restating either.
# shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-quota-axi-lib.sh"

# How long one provider read is reused across workers and polls. Short enough
# that a reset is acted on within a poll or two of becoming true, long enough
# that a fleet-wide park costs one subprocess rather than one per worker.
FM_ALLOWANCE_QUOTA_TTL=${FM_ALLOWANCE_QUOTA_TTL:-60}

# Wall-clock bound on the provider read. It runs on the watcher's poll path, so
# a hung vendor CLI must cost a bounded wait and then report unknown.
FM_ALLOWANCE_QUOTA_TIMEOUT=${FM_ALLOWANCE_QUOTA_TIMEOUT:-20}

# How long after the recorded reset a resume may be attempted. A provider's own
# accounting can lag its own boundary, so a small margin keeps the first attempt
# from landing on the wrong side of it and spending a message for nothing.
FM_ALLOWANCE_RESUME_GRACE_SECS=${FM_ALLOWANCE_RESUME_GRACE_SECS:-120}

# fm_allowance_resume_provider: the quota-axi provider id behind <harness>.
# Gated exactly like the park signature it pairs with: an adapter that never
# parks has no provider mapping here and can never be resumed by accident.
fm_allowance_resume_provider() {  # <harness>
  case "${1:-}" in
    claude*) printf 'claude' ;;
    *) return 1 ;;
  esac
}

# fm_allowance_reset_passed: 1 when the worker's own refusal record names a reset
# that has NOT yet passed by the grace margin - the one case where a resume is
# provably premature and must not be attempted.
#
# It returns 0 both when the recorded reset is safely past and when no reset was
# recorded at all (a pane-only park, or a harness build that wrote none). That
# asymmetry is deliberate: this gate exists to veto a resume it can prove is
# early, not to authorise one. Nothing is resumed on its say-so alone, because
# the provider gate still has to report headroom.
fm_allowance_reset_passed() {  # <harness> <worktree> [now-epoch]
  local harness=${1:-} wt=${2:-} now=${3:-} reset
  case "$now" in ''|*[!0-9]*) now=$(date -u +%s) ;; esac
  reset=$(fm_allowance_record_reset_epoch "$harness" "$wt") || return 0
  [ "$(( now - reset ))" -ge "$FM_ALLOWANCE_RESUME_GRACE_SECS" ]
}

# _fm_allowance_quota_probe: ask quota-axi whether <provider> has headroom now.
# Prints exactly one of ready|spent|unknown and always succeeds, because every
# failure mode of the read is itself an answer this caller has to act on.
#
# "spent" is any KNOWN scope that reports itself exhausted now or at zero
# remaining; "ready" needs at least one known scope and no spent one; everything
# else - no jq, a quota-axi below the shared compatibility floor, a timeout, a
# malformed document, a provider that is simply absent from the report - is
# unknown, which this library treats as "not headroom".
_fm_allowance_quota_probe() {  # <provider>
  local provider=${1:-} json verdict
  command -v jq >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  fm_quota_axi_compatible "$FM_ALLOWANCE_QUOTA_TIMEOUT" >/dev/null 2>&1 \
    || { printf 'unknown'; return 0; }
  json=$(fm_run_timed "$FM_ALLOWANCE_QUOTA_TIMEOUT" quota-axi --json 2>/dev/null </dev/null) \
    || { printf 'unknown'; return 0; }
  printf '%s\n' "$json" | fm_quota_json_valid || { printf 'unknown'; return 0; }
  verdict=$(printf '%s\n' "$json" | jq -r --arg p "$provider" '
    ([.providers[]? | select(.provider == $p)] | first) as $prov
    | if ($prov // null) == null then "unknown"
      elif $prov.quotaSemantics.status != "known" then "unknown"
      else ([$prov.quotaSemantics.effectiveAvailability[]? | select(.status == "known")]) as $known
        | if ($known | length) == 0 then "unknown"
          elif any($known[]; (.runway.status // "") == "exhausted_now") then "spent"
          elif any($known[]; (.effectivePercentRemaining // 0) <= 0) then "spent"
          else "ready"
          end
      end' 2>/dev/null) || verdict=''
  case "$verdict" in
    ready|spent) printf '%s' "$verdict" ;;
    *) printf 'unknown' ;;
  esac
}

# fm_allowance_quota_state: the cached provider verdict for <provider>, refreshed
# no more often than FM_ALLOWANCE_QUOTA_TTL. Prints ready|spent|unknown.
#
# The cache file's own mtime is the TTL clock, so a watcher restart inherits the
# remaining TTL instead of re-probing on every relaunch. A cache that cannot be
# written is not fatal: the probe's answer is still returned, and the next caller
# simply probes again.
fm_allowance_quota_state() {  # <state-dir> <provider>
  local state=${1:-} provider=${2:-} cache mtime now verdict tmp
  case "$provider" in ''|*[!a-z0-9-]*) printf 'unknown'; return 0 ;; esac
  cache="$state/.allowance-quota-$provider"
  now=$(date -u +%s)
  mtime=$(_fm_allowance_mtime "$cache") || mtime=''
  if [ -n "$mtime" ] && [ "$(( now - mtime ))" -lt "$FM_ALLOWANCE_QUOTA_TTL" ]; then
    verdict=$(cat "$cache" 2>/dev/null || true)
    case "$verdict" in
      ready|spent|unknown) printf '%s' "$verdict"; return 0 ;;
    esac
  fi
  verdict=$(_fm_allowance_quota_probe "$provider")
  if tmp=$(mktemp "$cache.XXXXXX" 2>/dev/null); then
    if printf '%s' "$verdict" > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$cache" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    else
      rm -f "$tmp" 2>/dev/null || true
    fi
  fi
  printf '%s' "$verdict"
}

# fm_allowance_resume_text: the steering message a resumed worker receives.
#
# It is written for the worker, not for a supervisor reading a log: it says what
# happened, that nothing was lost, and what to do, because the worker's own last
# turn ended on a provider error it has no other explanation for. It carries no
# task-specific content so it is safe to send to any parked worker.
fm_allowance_resume_text() {
  printf '%s' "Your last turn was refused because the account ran out of provider allowance, not because of anything you did. The allowance has reset and the account has headroom again. Nothing you had done was lost: pick up exactly where that turn stopped and carry on, re-reading your task brief first if you need the contract again."
}
