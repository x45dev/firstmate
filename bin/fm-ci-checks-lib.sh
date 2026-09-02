# shellcheck shell=bash
# Shared classification of a pull request's checks.
# Usage: . bin/fm-ci-checks-lib.sh; jq "$FM_CI_CHECKS_JQ_DEFS"'<program>'
#
# ONE OWNER for the question "did this repository's own suites actually run and
# pass on this commit?". Everything that reads a pull request's checks and turns
# them into a verdict - bin/fm-pr-ci-verify.sh for a single pull request,
# bin/fm-bearings-snapshot.sh for the bearings PR rows - classifies through the
# jq functions below, so the two can never disagree about what green means.
#
# The rule that makes this file necessary: an all-green check list is NOT
# evidence that this repository validated anything. A repository can receive
# check runs from third-party GitHub Apps - review bots, coverage services -
# that report on every commit whether or not a single workflow of this
# repository's own ever started. GitHub also holds a fork contributor's upstream
# workflow runs until a maintainer approves them, so a pull request from a fork
# routinely carries a third-party bot's pass and nothing else. Read as a total,
# that list is "1 passed, 0 failed, 1 total" - indistinguishable from success to
# anything that only counts passes and failures, and the reason a green verdict
# was reported three times for pull requests whose suites had never run.
#
# The discriminator is structural rather than a bot name to keep up to date:
# GitHub records the workflow that produced a check run in workflowName, and
# only GitHub Actions check runs have one. A check run created by a third-party
# App has no workflow run behind it and so carries no workflow name at all, and
# a legacy commit status (StatusContext) is not a check run in the first place.
# A rollup with no repository-owned check therefore reports no-repo-ci, which is
# a distinct state from passing and from an empty rollup's none, and no caller
# can collapse it into success by counting conclusions.
#
# GitHub offers this evidence in two shapes and the file owns both, and both
# have to establish the same thing: that every required suite ran and passed.
# A pull request carries a check rollup, which mixes everyone's checks together
# and so needs the workflowName discriminator above, and whose entries are the
# individual job check runs the roster is read from directly. A commit in a
# given repository carries workflow runs, which are that repository's own by
# construction, but still mix every workflow the repository owns together - a
# gating workflow alongside a PR-body policy check or a manually dispatched spike -
# so this file applies the same by-name filter to that shape too, rather than
# accepting any repository-owned run as a stand-in for the one that actually
# ran the suites. The second shape is what answers "did MY fork validate this
# commit?" when the first shape says the upstream pull request has no
# repository check on it.
#
# A workflow run's own conclusion is NOT roster evidence, which is why this
# file reads that shape's JOBS rather than stopping at the run. GitHub
# concludes a run "success" whenever no job in it failed, and a job that never
# ran because it was skipped does not fail: cli/cli run 32701833535 concluded
# success with one job successful and two skipped. A CI run that lost most of
# its roster - a job that gained an if: condition, a matrix that did not
# expand, a path filter, or simply a thinner ci.yml on the branch under test -
# therefore still reports success, and reading only that conclusion is the same
# false-green shape as the third-party bot above, arriving from inside the
# repository's own workflow instead of outside it. fm_ci_run_jobs_state takes
# the run's jobs alongside the runs and applies the roster to them, so this
# shape refuses a run that cannot show every required suite inside it.
#
# States, in the order the classifier decides them. Both shapes use the same
# set, except no-repo-ci, which only the rollup shape can observe:
#   none        the commit carries no checks at all, or no gating workflow run
#   no-repo-ci  checks exist, but no gating workflow ever produced one
#   failing     at least one check reached a red conclusion
#   pending     at least one check has not finished
#   incomplete  the gating workflows reported, and everything they reported
#               succeeded, but fewer than the full required roster of suites is
#               in there, or the gate or that roster could not be established
#               at all
#   passing     the gating workflows ran and every required suite succeeded
#
# Only passing is evidence. Read against the three outcomes a caller has to
# tell apart - the required suites ran and passed, the required suites ran and
# did not pass, the required suites cannot be shown to have run - passing is
# the first, failing and pending are the second, and none, no-repo-ci and
# incomplete are all the third. No caller may collapse any of that third group
# into the first, which is the whole reason they are distinct states rather
# than one "not passing".
#
# failing and pending are judged over EVERY check, not only the repository's
# own, so a red third-party check refuses a green verdict instead of hiding
# behind the suites that passed. Deciding no-repo-ci before either of them keeps
# the missing-suites diagnosis from being reported as an ordinary red or an
# ordinary wait, which are different problems with different fixes.
#
# One green CI check is not the same claim as "CI ran": a rollup can carry a
# single passing Lint job because that is genuinely all that ran - the rest of
# the workflow's jobs never started or never reported - and read exactly like
# "1 passed, 0 failed" to anything that only tallies conclusions, the same
# false-green shape the no-repo-ci and other-workflow cases above already
# guard against. fm_ci_required_suites is the fix: the full job roster the
# gating workflows are expected to report, by the display name GitHub renders for each
# job (matrix jobs expanded, one name per shard). A rollup missing any of them
# is incomplete rather than passing, even when every check it does carry is
# green. incomplete is deliberately its own state rather than folded into
# no-repo-ci, because the two are different findings - "nothing of ours ran"
# against "some of ours ran, not all of it" - but a caller that only trusts
# "passing" is safe either way, and fm-pr-ci-verify.sh treats both the same:
# neither is evidence, so it falls through to ask the head repository.
#
# That roster belongs to the repository under test and to no other, which is
# why it is resolved per repository by fm_ci_roster rather than written here.
# A constant listing one repository's job names cannot be drifted into on a
# second repository - it simply does not describe it - so a roster held as a
# constant makes every OTHER project fail the completeness test by
# construction, however genuinely green it is. That is not a hypothetical: the
# constant this file used to carry refused three separately hand-verified
# repositories in one session before it was removed.
#
# fm_ci_roster derives the roster by OBSERVATION rather than by parsing
# .github/workflows/: it reads the job names of the newest successful run of
# each gating workflow on the branch the change is aimed at. The workflow file
# is the
# definition, but it is not a roster - a job name is a template evaluated by
# GitHub ("Behavior portable serial ${{ matrix.shard }}", or a matrix.include
# leg's "${{ matrix.name }}"), so turning that file into names means
# reimplementing matrix expansion and the Actions expression language, and
# getting either subtly wrong silently shortens the roster. GitHub has already
# done that evaluation in every run it has recorded, exactly and for free.
# Reading the run on the TARGET branch rather than on the branch under test is
# deliberate for the same reason the roster exists at all: a branch that thins
# its own workflow file would otherwise certify itself.
#
# "Repository-owned" alone is not enough evidence: a commit can carry a
# passing check from some OTHER workflow that repository owns (a PR-body
# policy check, a manually dispatched spike) while the gating workflow - the
# one whose jobs are the actual suites - never ran on it at all, because it did
# not trigger or its job graph failed to expand. That reads as "1 passed, 0
# failed" to anything that only checks "is some repository check green", which is
# same false-green shape as a third-party bot, just from inside the
# repository instead of outside it. fm_ci_workflow_names holds the workflows
# whose runs are that evidence, and both classifiers require them by name
# rather than accepting any repository-owned check as a stand-in.
#
# WHICH workflows those are belongs to the repository under test and to no
# other, for exactly the reason the roster does, so fm_ci_roster resolves them
# per repository too rather than this file naming one. The constant this file
# used to carry - the literal name "CI" - was the roster constant's mistake one
# layer up, one repository's answer written down as every repository's. A
# repository whose gate is named anything else had every conclusion it produced
# discarded before the roster was ever consulted, and this command refused four
# separately hand-verified pull requests over two days on a repository whose
# whole pull request gate is a workflow named "lint". The roster could not
# rescue that and no roster override can: the roster is bound separately as
# $fm_ci_roster and is read one layer BELOW the workflow-name filter, so a
# rollup emptied by that filter never reaches it.
#
# The resolution is observation, from the same query the roster is read from:
# the workflows this repository has actually run to validate the TARGET branch,
# taken from the successful PUSH runs on that branch. Reading the target branch
# rather than the branch under test is deliberate for the same reason it is
# there: a branch that deleted the gating workflow would otherwise certify
# itself. Restricting to push runs is what separates a gate from the rest of a
# repository's workflows, and it is a real discriminator rather than a
# convenience - x45dev/agent-standards owns exactly two workflows, and the one
# that gates its pull requests is the one that also runs on a push to main,
# while its release workflow is workflow_dispatch only and would otherwise drag
# its release jobs into the roster of every pull request.
#
# Two boundaries come with that, and both cost a verdict rather than granting
# one. A workflow that runs ONLY on pull_request is not in the gate, because a
# fork validating a commit on its own branch push can never produce such a run
# and requiring one would refuse the head-repository evidence this file exists
# to accept. And a workflow that runs on a push to the target branch but not on
# pull requests - a deploy, a release-notes job - IS in the gate, so a pull
# request carrying no run of it reads incomplete. FM_CI_GATING_WORKFLOWS is the
# override for a repository either boundary gets wrong, the same escape hatch
# FM_CI_REQUIRED_SUITES is for the roster.
#
# The window is the newest 100 successful push runs on that branch. A workflow
# that has not validated the branch inside it is not in the gate, which is the
# bound this resolution accepts in exchange for answering in one API call.
#
# A check or run that finished as SKIPPED, NEUTRAL, or STALE is also refused
# rather than treated as passing: those conclusions mean the job never
# actually validated anything, so a CI run that completed with one of its
# jobs in that state is a partially-skipped workflow, not a clean pass.

# jq function definitions. Prepend to a jq program; the program then calls
# fm_ci_state on an array of statusCheckRollup entries.
#
# Every program built on these defs must bind BOTH halves of the standard
# fm_ci_roster resolves for the repository under test, with --argjson:
# $fm_ci_workflows, the names of the workflows whose runs are that repository's
# gate, and $fm_ci_roster, the required suite roster inside them. jq refuses to
# compile a program whose variables are not bound, so a caller that forgets one
# cannot silently classify against an absent standard - it gets no verdict at
# all. The shell wrappers at the bottom of this file take both as arguments and
# do that binding for you.
# $all, $own, $fm_ci_workflows and $fm_ci_roster are jq variables, deliberately
# not shell expansions.
# shellcheck disable=SC2016
FM_CI_CHECKS_JQ_DEFS='
def fm_ci_workflow_names: $fm_ci_workflows;
def fm_ci_required_suites: $fm_ci_roster;
def fm_ci_repo_owned:
  ((.__typename // "") == "CheckRun") and (((.workflowName // "") | tostring) != "");
def fm_ci_from_ci_workflow:
  ((.workflowName // "") | tostring) as $w
  | fm_ci_repo_owned and ((fm_ci_workflow_names | index($w)) != null);
def fm_ci_check_red:
  (((.conclusion // .state // "") | tostring | ascii_upcase)) as $s
  | $s == "FAILURE" or $s == "ERROR" or $s == "TIMED_OUT" or $s == "CANCELLED"
    or $s == "ACTION_REQUIRED" or $s == "STARTUP_FAILURE" or $s == "SKIPPED"
    or $s == "NEUTRAL" or $s == "STALE";
def fm_ci_check_unfinished:
  (((.status // "") | tostring | ascii_upcase) != "COMPLETED")
  and (((.state // "") | tostring | ascii_upcase) != "SUCCESS");
def fm_ci_missing_suites:
  (. // []) as $all
  | ([$all[] | select(fm_ci_from_ci_workflow) | ((.name // .context // "") | tostring)] | unique) as $ci_names
  | fm_ci_required_suites - $ci_names;
# An empty roster is "the roster could not be established", never "nothing is
# required": with no names to look for, fm_ci_missing_suites returns nothing
# missing and every green rollup would read as passing. Both classifiers refuse
# it as incomplete instead, so a roster lookup that failed can only ever cost a
# verdict, never grant one.
def fm_ci_no_roster: (fm_ci_required_suites | length) == 0;
# An empty gate is "the gating workflows could not be established", never
# "nothing gates this repository". With no names to match, every check reads as
# belonging to somebody else and the rollup would report no-repo-ci - a finding
# about the pull request, when what is missing is the standard. Both classifiers
# report incomplete instead, which is where every other unestablished standard
# already lands, and which no caller may read as evidence.
def fm_ci_no_gate: (fm_ci_workflow_names | length) == 0;
def fm_ci_state:
  (. // []) as $all
  | [$all[] | select(fm_ci_from_ci_workflow)] as $ci
  | if ($all | length) == 0 then "none"
    elif fm_ci_no_gate then "incomplete"
    elif ($ci | length) == 0 then "no-repo-ci"
    elif any($all[]; fm_ci_check_red) then "failing"
    elif any($all[]; fm_ci_check_unfinished) then "pending"
    elif fm_ci_no_roster then "incomplete"
    elif (($all | fm_ci_missing_suites) | length) > 0 then "incomplete"
    else "passing" end;
# The REST shapes - a workflow run and a workflow job - carry the same status
# and conclusion fields in the same lower case, unlike the upper-case GraphQL
# spelling of the rollup shape, so one pair of predicates classifies both.
def fm_ci_run_from_ci_workflow:
  ((.name // "") | tostring) as $w
  | (fm_ci_workflow_names | index($w)) != null;
def fm_ci_rest_red:
  (((.conclusion // "") | tostring | ascii_downcase)) as $c
  | $c == "failure" or $c == "cancelled" or $c == "timed_out"
    or $c == "action_required" or $c == "startup_failure" or $c == "stale"
    or $c == "skipped" or $c == "neutral";
def fm_ci_rest_unfinished:
  ((.status // "") | tostring | ascii_downcase) != "completed";
# The run-level judgement on its own: whether the CI workflow ran at all here,
# and whether the runs it produced are red or unfinished. It deliberately does
# NOT answer "did the required suites run", because the conclusion of a run
# cannot answer that - see the header on cli/cli run 32701833535. Every caller that
# needs a green verdict goes through fm_ci_run_jobs_state instead.
def fm_ci_runs_state:
  (. // []) as $all
  | [$all[] | select(fm_ci_run_from_ci_workflow)] as $runs
  | if ($runs | length) == 0 then "none"
    elif any($runs[]; fm_ci_rest_red) then "failing"
    elif any($runs[]; fm_ci_rest_unfinished) then "pending"
    else "passing" end;
# The roster in the jobs shape, the counterpart of fm_ci_missing_suites: the
# required suites that no job of the CI runs at this commit reported.
def fm_ci_jobs_missing_suites:
  (. // []) as $jobs
  | ([$jobs[] | ((.name // "") | tostring)] | unique) as $job_names
  | fm_ci_required_suites - $job_names;
# {runs, jobs} -> the same states the rollup shape produces. jobs are the jobs
# of the CI runs in runs, so an empty jobs array under a successful run means
# the roster could not be read at all, which is refused as incomplete rather
# than inherited from the conclusion of the run itself.
def fm_ci_run_jobs_state:
  (.runs // []) as $all
  | (.jobs // []) as $jobs
  | [$all[] | select(fm_ci_run_from_ci_workflow)] as $runs
  | if fm_ci_no_gate then "incomplete"
    elif ($runs | length) == 0 then "none"
    elif any($runs[]; fm_ci_rest_red) then "failing"
    elif any($runs[]; fm_ci_rest_unfinished) then "pending"
    elif ($jobs | length) == 0 then "incomplete"
    elif any($jobs[]; fm_ci_rest_red) then "failing"
    elif any($jobs[]; fm_ci_rest_unfinished) then "pending"
    elif fm_ci_no_roster then "incomplete"
    elif (($jobs | fm_ci_jobs_missing_suites) | length) > 0 then "incomplete"
    else "passing" end;
'

# fm_ci_gh <args...>: how this library reaches GitHub. A caller that must bound
# its own network calls redefines it after sourcing this file; the definition
# that is in scope when fm_ci_roster runs is the one used.
fm_ci_gh() {
  gh "$@"
}

# Set by fm_ci_roster: the two halves of the standard a commit is judged
# against - the gating workflow names and the required suite roster inside them
# - each as a JSON array, and for each a human-readable phrase naming where it
# came from, so a verdict can print the provenance of the standard it was judged
# against rather than only the standard. Returned through variables rather than
# on stdout, the same way fm_pr_url_parse returns FM_PR_*, because a caller
# reading them out of a command substitution would lose the provenance to the
# subshell.
FM_CI_WORKFLOWS=''
FM_CI_WORKFLOWS_SOURCE=''
FM_CI_ROSTER=''
FM_CI_ROSTER_SOURCE=''

# fm_ci_roster <repo> [<branch>]: resolve what <repo> requires of a commit into
# FM_CI_WORKFLOWS, a JSON array of gating workflow names, and FM_CI_ROSTER, a
# JSON array of the job display names those workflows are expected to report,
# and set the two SOURCE variables to where each came from. <branch> is the
# branch the change is aimed at, defaulting to the repository's own default
# branch.
#
# Both halves are read by OBSERVATION from one query: the repository's
# successful PUSH runs on that branch. The workflows among them are the gate,
# and the job names of the newest such run of each are the roster - the names
# GitHub itself rendered the last time each workflow reported in full, with
# every matrix leg already expanded. A successful run is required rather than
# merely a completed one because a run cancelled before its jobs were created
# carries no names at all, and an empty roster is the one answer that could turn
# every green rollup into a pass. The file header owns why the gate is push runs
# on the target branch and what that choice costs.
#
# Two overrides name a standard outright instead, for the cases observation
# cannot serve. FM_CI_REQUIRED_SUITES is a JSON array of job names, for a change
# that deliberately adds or removes a CI job, whose branch is therefore judged
# against a roster the target branch has not recorded yet.
# FM_CI_GATING_WORKFLOWS is a JSON array of workflow names, for a repository
# whose gate the push-run rule gets wrong. Set on its own it still takes the
# roster from those workflows' observed runs, so a named workflow the branch has
# never validated is refused rather than quietly contributing no suites at all.
#
# Leaves every output variable empty and returns 1 when either half cannot be
# established, naming the reason on stderr. Every caller must treat that as a
# refusal: this function never returns an empty array, because a caller cannot
# tell one apart from a repository that requires nothing.
fm_ci_roster() {
  local repo=$1 branch=${2:-}
  local gate_override='' roster_override='' runs gate observed missing
  local names names_source roster roster_source
  local name run_id run_jobs total jobs
  FM_CI_WORKFLOWS=''
  FM_CI_WORKFLOWS_SOURCE=''
  FM_CI_ROSTER=''
  FM_CI_ROSTER_SOURCE=''

  if [ -n "${FM_CI_GATING_WORKFLOWS:-}" ]; then
    gate_override=$(printf '%s' "$FM_CI_GATING_WORKFLOWS" | jq -c '
      if type == "array" and length > 0 and all(.[]; type == "string" and . != "")
      then unique else error("not a non-empty array of workflow names") end' 2>/dev/null) || {
      echo "error: FM_CI_GATING_WORKFLOWS is set but is not a non-empty JSON array of workflow names" >&2
      return 1
    }
  fi
  if [ -n "${FM_CI_REQUIRED_SUITES:-}" ]; then
    roster_override=$(printf '%s' "$FM_CI_REQUIRED_SUITES" | jq -c '
      if type == "array" and length > 0 and all(.[]; type == "string" and . != "")
      then unique else error("not a non-empty array of job names") end' 2>/dev/null) || {
      echo "error: FM_CI_REQUIRED_SUITES is set but is not a non-empty JSON array of job names" >&2
      return 1
    }
  fi

  # Both halves named outright: the repository is never reached at all.
  if [ -n "$gate_override" ] && [ -n "$roster_override" ]; then
    FM_CI_WORKFLOWS=$gate_override
    FM_CI_WORKFLOWS_SOURCE="the FM_CI_GATING_WORKFLOWS override"
    FM_CI_ROSTER=$roster_override
    FM_CI_ROSTER_SOURCE="the FM_CI_REQUIRED_SUITES override"
    return 0
  fi

  if [ -z "$branch" ]; then
    branch=$(fm_ci_gh api "repos/$repo" 2>/dev/null \
      | jq -r '.default_branch // empty' 2>/dev/null) || branch=''
    [ -n "$branch" ] || {
      echo "error: could not read the default branch of $repo" >&2
      return 1
    }
  fi

  # One query answers both halves. Run ids increase over time, so the largest id
  # carrying a given workflow name is that workflow's newest successful run on
  # the branch, without depending on the order the reply happens to arrive in.
  runs=$(fm_ci_gh api \
    "repos/$repo/actions/runs?branch=$branch&status=success&event=push&per_page=100" \
    2>/dev/null) || runs=''
  observed=$(printf '%s' "$runs" | jq -c '
    [.workflow_runs[]? | {name: ((.name // "") | tostring), id: .id}
     | select(.name != "" and (.id | type) == "number")]
    | group_by(.name) | map({name: .[0].name, run: (map(.id) | max)})
    | sort_by(.name)' 2>/dev/null) || observed=''
  [ -n "$observed" ] || observed='[]'

  if [ -n "$gate_override" ]; then
    names=$gate_override
    names_source="the FM_CI_GATING_WORKFLOWS override"
    gate=$(jq -cn --argjson observed "$observed" --argjson want "$gate_override" '
      [$want[] | . as $n | {name: $n, run: ([$observed[] | select(.name == $n) | .run] | max)}]' \
      2>/dev/null) || gate='[]'
  else
    if [ "$observed" = '[]' ]; then
      printf 'error: %s has run no workflow on a push to %s, so its gating workflows cannot be established\n' \
        "$repo" "$branch" >&2
      return 1
    fi
    names=$(printf '%s' "$observed" | jq -c '[.[].name] | unique' 2>/dev/null) || names=''
    [ -n "$names" ] || {
      printf 'error: could not read the workflows %s runs on a push to %s\n' "$repo" "$branch" >&2
      return 1
    }
    names_source="$repo successful push runs on $branch"
    gate=$observed
  fi

  if [ -n "$roster_override" ]; then
    FM_CI_WORKFLOWS=$names
    FM_CI_WORKFLOWS_SOURCE=$names_source
    FM_CI_ROSTER=$roster_override
    FM_CI_ROSTER_SOURCE="the FM_CI_REQUIRED_SUITES override"
    return 0
  fi

  # A gate the branch has never validated has no roster to offer, and an
  # overridden gate is the only way to reach that state.
  missing=$(printf '%s' "$gate" | jq -r '.[] | select(.run == null) | .name' 2>/dev/null \
    | tr '\n' ' ') || missing=''
  missing=${missing% }
  [ -z "$missing" ] || {
    printf 'error: %s has no successful push run of %s on %s to take a required suite roster from\n' \
      "$repo" "$missing" "$branch" >&2
    return 1
  }

  roster='[]'
  roster_source=''
  while IFS='	' read -r name run_id; do
    [ -n "$run_id" ] || continue
    run_jobs=$(fm_ci_gh api "repos/$repo/actions/runs/$run_id/jobs?per_page=100" 2>/dev/null) \
      || run_jobs=''
    # A second page of jobs would arrive as a roster with names missing from it,
    # which can only ever understate what is required and so can only ever grant
    # a pass that was not earned. Refused rather than truncated.
    total=$(printf '%s' "$run_jobs" | jq -r '.total_count // empty' 2>/dev/null) || total=''
    case "$total" in
      ''|*[!0-9]*)
        printf 'error: could not read the jobs of %s run %s in %s\n' "$name" "$run_id" "$repo" >&2
        return 1
        ;;
    esac
    [ "$total" -le 100 ] || {
      printf 'error: %s run %s in %s reports %s jobs, more than one page can name\n' \
        "$name" "$run_id" "$repo" "$total" >&2
      return 1
    }
    jobs=$(printf '%s' "$run_jobs" | jq -c '
      [.jobs[]? | (.name // "") | select(type == "string" and . != "")] | unique' 2>/dev/null) \
      || jobs=''
    [ -n "$jobs" ] && [ "$jobs" != '[]' ] || {
      printf 'error: %s run %s in %s named no jobs to require\n' "$name" "$run_id" "$repo" >&2
      return 1
    }
    roster=$(jq -cn --argjson a "$roster" --argjson b "$jobs" '($a + $b) | unique' 2>/dev/null) \
      || roster=''
    [ -n "$roster" ] || {
      printf 'error: could not assemble the required suite roster of %s on %s\n' "$repo" "$branch" >&2
      return 1
    }
    roster_source="${roster_source:+$roster_source, }$name run $run_id"
  done <<EOF
$(printf '%s' "$gate" | jq -r '.[] | select(.run != null) | "\(.name)\t\(.run)"' 2>/dev/null)
EOF

  [ "$roster" != '[]' ] && [ -n "$roster_source" ] || {
    printf 'error: %s named no jobs to require on %s\n' "$repo" "$branch" >&2
    return 1
  }

  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_CI_WORKFLOWS=$names
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_CI_WORKFLOWS_SOURCE=$names_source
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_CI_ROSTER=$roster
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_CI_ROSTER_SOURCE="$repo $roster_source on $branch"
}


# fm_ci_checks_state <rollup-json> <roster-json> <workflows-json>: print the
# state of one statusCheckRollup array against the standard fm_ci_roster
# resolved - the gating workflow names and the required suite roster inside
# them. Unreadable input - any payload - is refused rather than classified, so a
# malformed or truncated payload can never be reported as passing.
fm_ci_checks_state() {
  fm_ci_classify "$1" fm_ci_state "$2" "$3"
}

# fm_ci_runs_state <workflow-runs-json> <workflows-json>: print the run-level state of one
# repository's own workflow runs at a commit, refusing unreadable input the
# same way. Every run in that array came from the repository it was read from,
# but a repository can own more than one workflow, so this still narrows to the
# CI workflow's own runs before judging red, pending, or passing. Its passing
# means "no CI run here is red or unfinished", NOT "the required suites ran":
# a caller deciding whether to call a commit green wants fm_ci_run_jobs_state.
# It takes no roster because it consults none, and reports none rather than a
# state of its own when the gating workflows could not be established, which is
# a refusal like every other answer of its that is not passing.
fm_ci_runs_state() {
  fm_ci_classify "$1" fm_ci_runs_state '[]' "$2"
}

# fm_ci_run_jobs_state <workflow-runs-json> <ci-jobs-json> <roster-json>
# <workflows-json>: print the state of a repository's own gating-workflow runs
# at a commit judged against the required suite roster, where the second
# argument is the jobs of those runs.
# This is the workflow-runs answer to the same question the rollup shape
# answers, and the only one of the two that can return a passing verdict a
# caller may act on. Any payload being unreadable is refused rather than
# classified, so a truncated reply can never arrive at passing.
fm_ci_run_jobs_state() {
  local runs=$1 jobs=$2 roster=$3 workflows=$4 state
  state=$(jq -rn --argjson runs "$runs" --argjson jobs "$jobs" --argjson fm_ci_roster "$roster" \
    --argjson fm_ci_workflows "$workflows" \
    "$FM_CI_CHECKS_JQ_DEFS"'
    if ($runs | type) == "array" and ($jobs | type) == "array"
      and ($fm_ci_roster | type) == "array" and ($fm_ci_workflows | type) == "array"
    then {runs: $runs, jobs: $jobs} | fm_ci_run_jobs_state
    else error("payload is not an array") end' 2>/dev/null) || return 1
  [ -n "$state" ] || return 1
  printf '%s\n' "$state"
}

fm_ci_classify() {
  local payload=$1 fn=$2 roster=$3 workflows=$4 state
  state=$(printf '%s' "$payload" | jq -r --argjson fm_ci_roster "$roster" \
    --argjson fm_ci_workflows "$workflows" "$FM_CI_CHECKS_JQ_DEFS"'
    if type == "array" and ($fm_ci_roster | type) == "array" and ($fm_ci_workflows | type) == "array"
    then '"$fn"' else error("payload is not an array") end' 2>/dev/null) || return 1
  [ -n "$state" ] || return 1
  printf '%s\n' "$state"
}
