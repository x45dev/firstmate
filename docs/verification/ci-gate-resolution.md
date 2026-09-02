# Gating workflow resolution verification

Empirical record for how `bin/fm-ci-checks-lib.sh` decides which workflows are a repository's pull request gate, and for the three outcomes `bin/fm-pr-ci-verify.sh` must keep apart while doing it.
Every command below was run on 2026-09-02 against the live GitHub API, and every output is reproduced exactly.

The guarantee this record supports: the gate follows the repository under test, so a repository whose gating workflow is not named `CI` is answered rather than refused, and a green verdict is still granted only on evidence.
The portable regression in `tests/fm-ci-checks.test.sh` pins the classifier and the resolution logic against a stubbed forge; only a live run can show that the query this resolution is built on returns what the resolution assumes.

## Versions

```
$ gh --version | head -1
gh version 2.95.0 (2026-06-17)

$ jq --version
jq-1.8.2

$ bash --version | head -1
GNU bash, version 5.2.21(1)-release (x86_64-pc-linux-gnu)
```

## What the resolution query returns

The gate and the roster are both read from one query: the repository's successful push runs on the target branch.
`x45dev/agent-standards` is the case that motivated this - it owns two workflows, `lint` and `tag-release`, and only the first is a gate.

```
$ gh api 'repos/x45dev/agent-standards/actions/workflows?per_page=100' --jq '.workflows[] | [.id,.name,.path,.state] | @tsv'
322640314	lint	.github/workflows/lint.yml	active
318527028	tag-release	.github/workflows/tag-release.yml	active

$ gh api 'repos/x45dev/agent-standards/actions/runs?branch=main&status=success&per_page=100' --jq '[.workflow_runs[] | {name, event}] | group_by(.name+"|"+.event) | map({wf: .[0].name, ev: .[0].event, n: length}) | .[] | [.wf,.ev,.n] | @tsv'
lint	push	44
tag-release	workflow_dispatch	4
```

`tag-release` is `workflow_dispatch` only, so restricting the query to `event=push` is what separates the gate from the rest of what the repository owns.
Without that restriction its release jobs would join the roster every pull request is judged against.

The same query on `x45dev/firstmate`, whose gate is named `CI` and which also owns a pull-request-only body-policy workflow and a dispatch-only spike:

```
$ gh api 'repos/x45dev/firstmate/actions/runs?branch=main&status=success&event=push&per_page=100' --jq '[.workflow_runs[] | .name] | unique'
["CI"]
```

`Require no-mistakes` is deliberately absent: it runs only on `pull_request`, and a fork validating a commit on its own branch push can never produce such a run, so requiring one would refuse the head-repository evidence the verifier exists to accept.

## The defect this closed

Before the change, on the same repository and pull request:

```
$ bin/fm-pr-ci-verify.sh https://github.com/x45dev/agent-standards/pull/110
error: x45dev/agent-standards has no workflow named CI to take a required suite roster from
error: refusing to call https://github.com/x45dev/agent-standards/pull/110 green: could not establish what x45dev/agent-standards requires of a commit.
```

The pull request was green and merged.
`FM_CI_REQUIRED_SUITES` could not have fixed it: the roster is bound separately as `$fm_ci_roster` and is read one layer below the workflow-name filter, so a rollup emptied by that filter never reaches it.

## The three outcomes, live

Verified green, on a repository whose gate is a workflow named `lint` (PR #110, merged 2026-09-02):

```
$ bin/fm-pr-ci-verify.sh https://github.com/x45dev/agent-standards/pull/110
https://github.com/x45dev/agent-standards/pull/110
gating workflows: lint, from x45dev/agent-standards successful push runs on main
required suites: 1, from x45dev/agent-standards lint run 33598952234 on main
  suite SUCCESS	lint / lint
x45dev/agent-standards checks: passing (1 repository-owned)
validated: x45dev/agent-standards suites passed on 76291ea2e6bdb2778f308d05a4ccb1baa9a6d555 in x45dev/agent-standards
$ echo $?
0
```

PRs #104, #108 and #109 - the other three that had to be established by hand - verify the same way.

Verified red, on a repository whose gate is named `CI`, with one suite failing:

```
$ bin/fm-pr-ci-verify.sh https://github.com/x45dev/firstmate/pull/4
gating workflows: CI, from x45dev/firstmate successful push runs on main
required suites: 12, from x45dev/firstmate CI run 33371469355 on main
  suite FAILURE	CI / Behavior portable serial 4
x45dev/firstmate checks: failing (25 repository-owned)
error: refusing to call https://github.com/x45dev/firstmate/pull/4 green: its x45dev/firstmate checks are failing (see the roster above).
$ echo $?
1
```

Suite lines that passed are elided from that transcript; the failing one and the verdict are verbatim.

Verified unrun, where the gate resolved but produced no check on the commit:

```
$ bin/fm-pr-ci-verify.sh https://github.com/x45dev/firstmate/pull/1
gating workflows: CI, from x45dev/firstmate successful push runs on main
required suites: 12, from x45dev/firstmate CI run 33371469355 on main
x45dev/firstmate checks: none (0 repository-owned)
error: refusing to call https://github.com/x45dev/firstmate/pull/1 green: no x45dev/firstmate suite ran on this commit.
$ echo $?
1
```

Could not verify, where the gate itself cannot be established - a repository that has never run a workflow on a push to its default branch:

```
$ bin/fm-pr-ci-verify.sh https://github.com/octocat/Hello-World/pull/11064
error: octocat/Hello-World has run no workflow on a push to master, so its gating workflows cannot be established
error: refusing to call https://github.com/octocat/Hello-World/pull/11064 green: could not establish what octocat/Hello-World requires of a commit.
$ echo $?
1
```

Naming a gate for that repository by hand does not manufacture one either, because the roster is still read from that workflow's observed runs:

```
$ FM_CI_GATING_WORKFLOWS='["CI"]' bin/fm-pr-ci-verify.sh https://github.com/octocat/Hello-World/pull/11064
error: octocat/Hello-World has no successful push run of CI on master to take a required suite roster from
$ echo $?
1
```

## Refreshing this record

Re-run the transcripts above.
The pull requests named here are merged and their check history is immutable, so their outputs are stable; the resolution queries are not, because they read whatever has run on the branch since.
A resolution query whose reply no longer matches the shape recorded here is a finding about the resolution, not about this record.
