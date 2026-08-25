#!/usr/bin/env bash
# Corroborate, from the forge alone, that a pull request's exact current head
# has real repository CI behind it.
# Firstmate and its workers call this instead of trusting a validation tool's
# own "checks green" verdict, because that verdict has been observed to be true
# of a check set that contained no repository CI at all.
#
# Usage: fm-ci-corroborate.sh <pr-url|task-id> [--head <sha>]
#   <pr-url>   a GitHub pull request URL.
#   <task-id>  a task whose state/<id>.meta records pr=<url>.
#   --head     corroborate this commit instead of the pull request's live head.
#              Auditing an older head only; the default is always the live head,
#              because a verdict is about one exact commit and a push moves it.
#
# Exit status is the verdict: 0 green, 1 not green, 2 an unusable request.
# The first stdout line is "ci-corroboration: green" or
# "ci-corroboration: not-green" for a caller that reads rather than parses.
#
# THE RULE. A green verdict is real only when at least one repository-owned,
# workflow-backed check has actually RUN and CONCLUDED successfully at that
# exact head, and nothing else at that head failed or never ran.
#
# Three properties follow, and each one is a defect this gate exists to stop:
#
# 1. A third-party CheckRun never satisfies the gate. A check run created by the
#    GitHub Actions app is one of this repository's own workflow jobs; every
#    other app slug is an installed third party - a review bot, a coverage
#    service - whose pass says nothing about this repository's suite. Those are
#    counted and reported, and they are never counted toward the gate.
# 2. A validation tool's own internal test step never satisfies the gate. This
#    script reads the forge and nothing else, so no local pipeline, log, or
#    report can reach the verdict. A pipeline test step has been observed
#    reporting success on exactly the code the repository's own suite then
#    failed, so the two are not interchangeable and this gate reads only the
#    one that is authoritative.
# 3. ABSENCE fails. A check set with zero repository-owned checks is no signal,
#    not a weak one. Fork-held workflows sit at conclusion "action_required"
#    with zero jobs and never start, so "did not run" is bucketed and reported
#    separately from "ran and failed" - conflating those two is what let the
#    absence be read as a pass.
#
# BUCKETS. Every check run and every workflow run at the head falls in exactly
# one bucket, by its forge status and conclusion:
#   passed       completed/success.
#   skipped      completed/skipped or completed/neutral - a conditional job that
#                legitimately did not apply. It neither passes nor blocks.
#   did-not-run  any status other than completed, or completed/action_required,
#                or completed with no conclusion at all.
#   failed       every other conclusion, including failure, timed_out,
#                cancelled, startup_failure, and stale. The catch-all blocks, so
#                a conclusion this script has never seen refuses rather than
#                passes.
#
# GREEN requires all of: at least one repository-owned check passed; no
# repository-owned check failed or did not run; no workflow run at the head
# failed or did not run; and every forge read succeeded. An unreadable head, an
# unreadable check set, or an absent gh refuses, because a verdict that cannot
# be corroborated is not green.
#
# WHAT THIS DOES NOT PROVE, stated so nobody reads more into a green than it
# carries: that the full expected suite was scheduled. This gate deliberately
# derives no expected workflow set. A hardcoded set rots silently as workflows
# change, and every derivable set - the workflow files at the head, the active
# workflow list, the base branch's own check count - misreads path filters,
# matrix expansion, and conditional jobs as absence. What it proves instead is
# that repository CI ran at this head and concluded, and that nothing observed
# at this head is unaccounted for; the per-bucket counts it prints are what make
# a drop in coverage visible to a reader rather than silent.
#
# GitHub only. A GitLab merge request is corroborated at merge time by
# bin/fm-pr-merge.sh, which reads the head pipeline's status and sha live and
# refuses a merge whose pipeline did not succeed at the exact current head.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  cat <<'USAGE'
usage: fm-ci-corroborate.sh <pr-url|task-id> [--head <sha>]
Corroborate from the forge that repository CI actually ran and passed at a pull
request's exact head. Exit 0 green, 1 not green, 2 unusable request.
USAGE
}

TARGET=
HEAD_OVERRIDE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --head)
      shift
      [ "$#" -gt 0 ] || { usage >&2; exit 2; }
      HEAD_OVERRIDE=$1
      ;;
    --head=*) HEAD_OVERRIDE=${1#--head=} ;;
    --) ;;
    -*) usage >&2; exit 2 ;;
    *)
      [ -z "$TARGET" ] || { usage >&2; exit 2; }
      TARGET=$1
      ;;
  esac
  shift
done
[ -n "$TARGET" ] || { usage >&2; exit 2; }
if [ -n "$HEAD_OVERRIDE" ] && ! fm_pr_head_valid "$HEAD_OVERRIDE"; then
  echo "error: --head is not a commit sha" >&2
  exit 2
fi

# A target is either the PR URL itself or a task whose metadata records one.
RAW_URL=
case "$TARGET" in
  http://*|https://*) RAW_URL=$TARGET ;;
  *)
    if ! fm_pr_task_id_valid "$TARGET"; then
      echo "error: invalid corroboration request" >&2
      exit 2
    fi
    META="$STATE/$TARGET.meta"
    if [ ! -f "$META" ] || [ -L "$META" ]; then
      echo "error: task metadata is unavailable" >&2
      exit 2
    fi
    RAW_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
    if [ -z "$RAW_URL" ]; then
      echo "error: no PR is recorded for this task" >&2
      exit 2
    fi
    ;;
esac
if ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid corroboration request" >&2
  exit 2
fi
URL=$FM_PR_URL
if [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: only a GitHub pull request is corroborated here; a GitLab merge request is verified at merge time by bin/fm-pr-merge.sh" >&2
  exit 2
fi
OWNER=$FM_PR_OWNER
REPO=$FM_PR_REPO
NUMBER=$FM_PR_NUMBER

# Refusals accumulate so one run reports every reason, not just the first.
REFUSALS=
refuse() { REFUSALS="$REFUSALS  - $1
"; }

# Detail lines name the checks that are not plain passes, capped so a pathological
# check set cannot bury the verdict it belongs to.
DETAIL=
DETAIL_LINES=0
DETAIL_SUPPRESSED=0
DETAIL_CAP=20
detail() {
  if [ "$DETAIL_LINES" -ge "$DETAIL_CAP" ]; then
    DETAIL_SUPPRESSED=$((DETAIL_SUPPRESSED + 1))
    return 0
  fi
  DETAIL="$DETAIL  $1
"
  DETAIL_LINES=$((DETAIL_LINES + 1))
}

# One check run or workflow run, bucketed by its forge status and conclusion.
# The header owns the bucket definitions; keep the two in step.
bucket_for() {  # <status> <conclusion>
  case "$1" in
    completed) ;;
    *) printf 'did-not-run\n'; return 0 ;;
  esac
  case "$2" in
    success) printf 'passed\n' ;;
    skipped|neutral) printf 'skipped\n' ;;
    action_required|'') printf 'did-not-run\n' ;;
    *) printf 'failed\n' ;;
  esac
}

if ! command -v gh >/dev/null 2>&1; then
  printf 'ci-corroboration: not-green\n'
  printf 'pr: %s\n' "$URL"
  printf 'refusing:\n  - gh is not on PATH, so no check at this head could be read\n'
  exit 1
fi

# The live head, because a verdict is about one exact commit and a push moves
# it. --head only replaces this read when a caller is auditing an older commit.
HEAD_SHA=$HEAD_OVERRIDE
if [ -z "$HEAD_SHA" ]; then
  HEAD_SHA=$(gh pr view "$NUMBER" --repo "$OWNER/$REPO" --json headRefOid --jq .headRefOid 2>/dev/null || true)
fi
if ! fm_pr_head_valid "$HEAD_SHA"; then
  printf 'ci-corroboration: not-green\n'
  printf 'pr: %s\n' "$URL"
  printf 'refusing:\n  - the head commit of this pull request could not be read from the forge\n'
  exit 1
fi

# Check runs at the head, one tab-separated row per run: app slug, status,
# conclusion, name. The app slug is what separates this repository's own
# workflow jobs from every installed third party.
CHECKS=
CHECKS_READ=1
CHECKS=$(gh api "repos/$OWNER/$REPO/commits/$HEAD_SHA/check-runs?per_page=100" --paginate \
  --jq '.check_runs[] | [(.app.slug // ""), .status, (.conclusion // ""), .name] | @tsv' 2>/dev/null) \
  || CHECKS_READ=0

# Workflow runs at the same head, one row per run: status, conclusion, workflow
# file path. This is where a fork-held workflow that never started is visible at
# all: it produces a run record and no check run.
RUNS=
RUNS_READ=1
RUNS=$(gh api "repos/$OWNER/$REPO/actions/runs?head_sha=$HEAD_SHA&per_page=100" --paginate \
  --jq '.workflow_runs[] | [.status, (.conclusion // ""), (.path // .name // "")] | @tsv' 2>/dev/null) \
  || RUNS_READ=0

OWNED_PASSED=0
OWNED_FAILED=0
OWNED_ABSENT=0
OWNED_SKIPPED=0
THIRD_PARTY=0
while IFS=$'\t' read -r slug status conclusion name; do
  [ -n "${slug-}${status-}${conclusion-}${name-}" ] || continue
  if [ "$slug" != github-actions ]; then
    THIRD_PARTY=$((THIRD_PARTY + 1))
    detail "$(printf 'third-party: %s "%s" (%s/%s) - never satisfies this gate' \
      "${slug:-unknown}" "${name:-unnamed}" "${status:-unreadable}" "${conclusion:-none}")"
    continue
  fi
  case "$(bucket_for "${status:-}" "${conclusion:-}")" in
    passed) OWNED_PASSED=$((OWNED_PASSED + 1)) ;;
    skipped)
      OWNED_SKIPPED=$((OWNED_SKIPPED + 1))
      detail "$(printf 'skipped: %s (%s/%s)' "${name:-unnamed}" "${status:-unreadable}" "${conclusion:-none}")"
      ;;
    did-not-run)
      OWNED_ABSENT=$((OWNED_ABSENT + 1))
      detail "$(printf 'did-not-run: %s (%s/%s)' "${name:-unnamed}" "${status:-unreadable}" "${conclusion:-none}")"
      ;;
    *)
      OWNED_FAILED=$((OWNED_FAILED + 1))
      detail "$(printf 'failed: %s (%s/%s)' "${name:-unnamed}" "${status:-unreadable}" "${conclusion:-none}")"
      ;;
  esac
done <<CHECK_ROWS
$CHECKS
CHECK_ROWS

RUN_PASSED=0
RUN_FAILED=0
RUN_ABSENT=0
RUN_SKIPPED=0
while IFS=$'\t' read -r status conclusion path; do
  [ -n "${status-}${conclusion-}${path-}" ] || continue
  case "$(bucket_for "${status:-}" "${conclusion:-}")" in
    passed) RUN_PASSED=$((RUN_PASSED + 1)) ;;
    skipped) RUN_SKIPPED=$((RUN_SKIPPED + 1)) ;;
    did-not-run)
      RUN_ABSENT=$((RUN_ABSENT + 1))
      detail "$(printf 'workflow did-not-run: %s (%s/%s)' "${path:-unnamed}" "${status:-unreadable}" "${conclusion:-none}")"
      ;;
    *)
      RUN_FAILED=$((RUN_FAILED + 1))
      detail "$(printf 'workflow failed: %s (%s/%s)' "${path:-unnamed}" "${status:-unreadable}" "${conclusion:-none}")"
      ;;
  esac
done <<RUN_ROWS
$RUNS
RUN_ROWS

[ "$CHECKS_READ" = 1 ] || refuse "the check runs at this head could not be read from the forge"
[ "$RUNS_READ" = 1 ] || refuse "the workflow runs at this head could not be read from the forge"
[ "$OWNED_PASSED" -ge 1 ] \
  || refuse "no repository-owned check ran and concluded successfully at this head"
[ "$OWNED_FAILED" = 0 ] \
  || refuse "$OWNED_FAILED repository-owned checks ran and failed at this head"
[ "$OWNED_ABSENT" = 0 ] \
  || refuse "$OWNED_ABSENT repository-owned checks never ran at this head"
[ "$RUN_FAILED" = 0 ] \
  || refuse "$RUN_FAILED workflow runs failed at this head"
[ "$RUN_ABSENT" = 0 ] \
  || refuse "$RUN_ABSENT workflow runs never ran at this head"

if [ -n "$REFUSALS" ]; then
  printf 'ci-corroboration: not-green\n'
else
  printf 'ci-corroboration: green\n'
fi
printf 'pr: %s\n' "$URL"
printf 'head: %s\n' "$HEAD_SHA"
printf 'repository-owned checks at head: %s passed, %s failed, %s did-not-run, %s skipped\n' \
  "$OWNED_PASSED" "$OWNED_FAILED" "$OWNED_ABSENT" "$OWNED_SKIPPED"
printf 'third-party checks at head: %s (never satisfy this gate)\n' "$THIRD_PARTY"
printf 'workflow runs at head: %s passed, %s failed, %s did-not-run, %s skipped\n' \
  "$RUN_PASSED" "$RUN_FAILED" "$RUN_ABSENT" "$RUN_SKIPPED"
[ -z "$DETAIL" ] || printf '%s' "$DETAIL"
[ "$DETAIL_SUPPRESSED" = 0 ] \
  || printf '  and %s more checks not listed\n' "$DETAIL_SUPPRESSED"
if [ -n "$REFUSALS" ]; then
  printf 'refusing:\n'
  printf '%s' "$REFUSALS"
  exit 1
fi
printf 'corroborated: %s repository-owned checks ran and passed at head %s\n' \
  "$OWNED_PASSED" "$HEAD_SHA"
