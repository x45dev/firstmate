# Gating workflow resolution verification

Empirical record for how `bin/fm-ci-checks-lib.sh` decides which workflows are a repository's pull request gate, and for the three outcomes `bin/fm-pr-ci-verify.sh` must keep apart while doing it.
The resolution queries and the two-outcome transcripts under "The push-only deploy" were run on 2026-09-10; the transcripts under "The three outcomes, live" were run on 2026-09-02.
Every output is reproduced exactly.

The guarantee this record supports: the gate follows the repository under test, so a repository whose gating workflow is not named `CI` is answered rather than refused, a workflow no pull request can trigger is not demanded of one, and a green verdict is still granted only on evidence.
The portable regression in `tests/fm-ci-checks.test.sh` pins the classifier and the resolution logic against a stubbed forge; only a live run can show that the queries this resolution is built on return what the resolution assumes.

## Versions

```
$ gh --version | head -1
gh version 2.100.0 (2026-09-03)

$ jq --version
jq-1.8.2

$ bash --version | head -1
GNU bash, version 5.2.21(1)-release (x86_64-pc-linux-gnu)
```

The 2026-09-02 transcripts below were taken under gh 2.95.0 (2026-06-17) with the same jq and bash.

## What the candidate query returns

The candidates and the roster are both read from one query: the repository's successful push runs on the target branch.
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
A candidate that survives this query is then asked whether a pull request can trigger it at all, which the next section records.

## The push-only deploy

A successful push run proves a workflow validates the target branch, not that a pull request can produce it.
`x45dev/www.startrails.net` is the shape that separates the two: its `Deploy` runs on a push to `main` and on `workflow_dispatch`, and its `CI` also runs on `pull_request`.

```
$ gh api 'repos/x45dev/www.startrails.net/actions/runs?branch=main&status=success&event=push&per_page=100' --jq '[.workflow_runs[] | {name, path, workflow_id}] | group_by(.name) | map({name:.[0].name, path:.[0].path, workflow_id:.[0].workflow_id, n:length})'
[{"n":25,"name":"CI","path":".github/workflows/ci.yml","workflow_id":326562050},{"n":12,"name":"Deploy","path":".github/workflows/deploy.yml","workflow_id":328585471},{"n":1,"name":"Deploy to Cloud Run","path":".github/workflows/deploy.yml","workflow_id":328585471}]
```

Two facts the resolution depends on are visible there.
A run carries the `path` and `workflow_id` of the workflow that produced it, and `Deploy to Cloud Run` is not a retired workflow but the same `workflow_id` under the name it had when that run happened, so keying candidates on the run's name invents a second gating workflow out of a rename.
The repository's current workflow list is what says which of those names still exists and what the workflow is called now:

```
$ gh api 'repos/x45dev/www.startrails.net/actions/workflows?per_page=100' --jq '.workflows[] | [.id,.name,.path,.state] | @tsv'
331547049	Assert contact live	.github/workflows/assert-contact-live.yml	active
326562050	CI	.github/workflows/ci.yml	active
328585471	Deploy	.github/workflows/deploy.yml	active
326563125	Dependency Graph	dynamic/dependabot/update-graph	active
```

The trigger set is read from each candidate's own file at the target branch:

```
$ . bin/fm-ci-checks-lib.sh
$ gh api 'repos/x45dev/www.startrails.net/contents/.github/workflows/ci.yml?ref=main' | jq -r '.content | gsub("\\s";"") | @base64d' | fm_ci_workflow_events
push
pull_request

$ gh api 'repos/x45dev/www.startrails.net/contents/.github/workflows/deploy.yml?ref=main' | jq -r '.content | gsub("\\s";"") | @base64d' | fm_ci_workflow_events
push
workflow_dispatch
```

### The trigger grammar under other awks

The grammar is one awk program, so it is only as portable as the awk that runs it.
It uses `[[:blank:]]` rather than `[ \t]` and `index(line, "\t")` rather than a `\t` regex for that reason.
Checked on 2026-09-10 against every awk on hand, on the same four inputs each time - a block `on:`, an inline comment, the YAML 1.1 `true:` spelling, and a flow mapping that must be refused:

```
$ . bin/fm-ci-checks-lib.sh
$ for A in "gawk --posix" mawk "busybox awk"; do
>   printf 'name: CI\non:\n  push:\n    branches: [main]\n  pull_request:\n' | $A "$FM_CI_WORKFLOW_ON_AWK"
>   printf 'on: {push: null}\n' | $A "$FM_CI_WORKFLOW_ON_AWK" 2>/dev/null; echo "refused rc=$?"
> done
push
pull_request
refused rc=1
push
pull_request
refused rc=1
push
pull_request
refused rc=1
```

`tests/fm-ci-checks.test.sh` pins the grammar itself on whichever awk CI provides.

### The defect the trigger test closed

Before the trigger test, on `x45dev/www.startrails.net` pull request 30, which is merged:

```
$ bin/fm-pr-ci-verify.sh https://github.com/x45dev/www.startrails.net/pull/30
https://github.com/x45dev/www.startrails.net/pull/30
gating workflows: CI, Deploy, Deploy to Cloud Run, from x45dev/www.startrails.net successful push runs on main
required suites: 6, from x45dev/www.startrails.net CI run 34432844118, Deploy run 31416123061, Deploy to Cloud Run run 31100329470 on main
  suite SUCCESS	CI / lint
  suite SUCCESS	CI / test
  suite SUCCESS	CI / e2e
x45dev/www.startrails.net checks: incomplete (3 repository-owned)
missing required suites:
  deploy-backend
  deploy-edge
  deploy-frontend
error: refusing to call https://github.com/x45dev/www.startrails.net/pull/30 green: x45dev/www.startrails.net checks do not cover the required suite roster.
$ echo $?
1
```

The three named suites are unreachable rather than not-yet-run, and `deploy-frontend` had already been deleted from `deploy.yml` - it survived only in the pre-rename run the old name dragged in.
The same refusal was reproduced on `x45dev/www.x45.dev` pull request 27, `x45dev/www.ioflow.org` pull request 19 and `x45dev/www.ehlands.com` pull request 25, all merged.

### After

```
$ bin/fm-pr-ci-verify.sh https://github.com/x45dev/www.startrails.net/pull/30
https://github.com/x45dev/www.startrails.net/pull/30
gating workflows: CI, from x45dev/www.startrails.net successful push runs on main that a pull request can trigger
not gating: Deploy (declares no pull_request trigger)
required suites: 3, from x45dev/www.startrails.net CI run 34432844118 on main
  suite SUCCESS	CI / lint
  suite SUCCESS	CI / test
  suite SUCCESS	CI / e2e
x45dev/www.startrails.net checks: passing (3 repository-owned)
validated: x45dev/www.startrails.net suites passed on c6258143848a45647998d07efb09a594db8da75f in x45dev/www.startrails.net
$ echo $?
0
```

`Deploy to Cloud Run` is gone from both halves without a rule of its own: grouping the runs by `workflow_id` collapses it onto `Deploy`, which the trigger test then drops.
The other three landing sites verify identically, each on `CI / lint`, `CI / test` and `CI / e2e` alone.

A repository that never had this problem is unchanged by it, which is the other half of the check.
`x45dev/firstmate` pull request 12, merged, before and after:

```
$ bin/fm-pr-ci-verify.sh https://github.com/x45dev/firstmate/pull/12
https://github.com/x45dev/firstmate/pull/12
gating workflows: CI, from x45dev/firstmate successful push runs on main that a pull request can trigger
required suites: 12, from x45dev/firstmate CI run 33701412177 on main
x45dev/firstmate checks: passing (25 repository-owned)
validated: x45dev/firstmate suites passed on 602033a5046ea75e38c2418ee4210c3e2daa2877 in x45dev/firstmate
$ echo $?
0
```

Only the provenance phrase changed; the gate, the roster and the verdict are the same as before the change.
The suite lines are elided from that transcript.
`Require no-mistakes` stays out of the gate for the reason it always did - it runs only on `pull_request`, so it produces no push run to be observed as a candidate - and the trigger test never sees it.

## The defect the per-repository gate closed

Before the gate followed the repository, on `x45dev/agent-standards` pull request 110:

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
The pull requests named here are merged and their check history is immutable, so their outputs are stable; the resolution queries are not, because they read whatever has run on the branch since, and the workflow list and file reads follow whatever the repository owns now.
A resolution query whose reply no longer matches the shape recorded here is a finding about the resolution, not about this record.
A verdict transcript can also move for a reason that is not a defect: the roster is read from the target branch as it is today, so a repository that has since added a gating workflow will refuse an older pull request that predates it.
That is what `x45dev/agent-standards` pull request 110 does now, identically before and after this change, because a `test` workflow was added to that repository after it merged.
