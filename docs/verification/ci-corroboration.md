# CI corroboration verification

Audience: maintainer verification.

This record supports one active guarantee: `bin/fm-ci-corroborate.sh` reports green only when this repository's own CI actually ran and concluded successfully at a pull request's exact head, and reports not-green for the two shapes in which a validation tool has been observed reporting green over checks that carry no such evidence.

`bin/fm-ci-corroborate.sh`'s own header owns the rule, the buckets, and the boundary of what a green does and does not prove.
`tests/fm-ci-corroborate.test.sh` is the portable regression that enforces all of it without a network, and is what CI runs.
This record exists because that regression drives the classifier from fixtures, and fixtures can only confirm the shape already written into them: these commands ran the real script against the real GitHub API, so the fixture shapes are known to match what the forge actually emits.

## Environment

Recorded 2026-08-24 on Linux 6.8.0-138-generic (x86_64) with GNU bash 5.2.21, gh 2.95.0, and ShellCheck 0.11.0 (the version `bin/fm-lint.sh` pins).
The three live cases below read public pull requests through an authenticated `gh`; nothing is written to any forge.

## The absence shape, live

The head's only check is a third-party review bot reporting success, while both repository workflows sit `completed`/`action_required` with zero jobs and never start.
`gh pr checks` summarises this state as `1 passed, 0 failed, 1 total`.

```sh
bin/fm-ci-corroborate.sh https://github.com/kunchenguid/firstmate/pull/2777; echo "rc=$?"
```

```
ci-corroboration: not-green
pr: https://github.com/kunchenguid/firstmate/pull/2777
head: 7af9572f9a183f52275e06fbc414aa51cbd8b230
repository-owned checks at head: 0 passed, 0 failed, 0 did-not-run, 0 skipped
third-party checks at head: 1 (never satisfy this gate)
workflow runs at head: 0 passed, 0 failed, 2 did-not-run, 0 skipped
  third-party: greptile-apps "Greptile Review" (completed/success) - never satisfies this gate
  workflow did-not-run: .github/workflows/no-mistakes-required.yml (completed/action_required)
  workflow did-not-run: .github/workflows/ci.yml (completed/action_required)
refusing:
  - no repository-owned check ran and concluded successfully at this head
  - 2 workflow runs never ran at this head
rc=1
```

## A head where repository CI ran and failed, live

Real CI, twelve repository-owned jobs, one genuine failure.
This is the shape a pipeline's own passing test step was observed concealing, and it is reported as ran-and-failed rather than as absence.

```sh
bin/fm-ci-corroborate.sh https://github.com/x45dev/firstmate/pull/2; echo "rc=$?"
```

```
ci-corroboration: not-green
pr: https://github.com/x45dev/firstmate/pull/2
head: 71a2e8470985b0b97cee9c13d786815e0a2590a0
repository-owned checks at head: 11 passed, 2 failed, 0 did-not-run, 0 skipped
third-party checks at head: 0 (never satisfy this gate)
workflow runs at head: 0 passed, 2 failed, 0 did-not-run, 0 skipped
  failed: Behavior portable serial 1 (completed/failure)
  failed: PR must be raised via no-mistakes (completed/failure)
  workflow failed: .github/workflows/no-mistakes-required.yml (completed/failure)
  workflow failed: .github/workflows/ci.yml (completed/failure)
refusing:
  - 2 repository-owned checks ran and failed at this head
  - 2 workflow runs failed at this head
rc=1
```

## The positive control, live

A branch raised inside the repository, where every repository-owned check ran and passed.
The third-party bot is present here too and is counted apart from the thirteen checks that carried the verdict.

```sh
bin/fm-ci-corroborate.sh https://github.com/kunchenguid/firstmate/pull/2901; echo "rc=$?"
```

```
ci-corroboration: green
pr: https://github.com/kunchenguid/firstmate/pull/2901
head: 359799022046cd4ded931c21dfc5b281b7498d57
repository-owned checks at head: 13 passed, 0 failed, 0 did-not-run, 0 skipped
third-party checks at head: 1 (never satisfy this gate)
workflow runs at head: 2 passed, 0 failed, 0 did-not-run, 0 skipped
  third-party: greptile-apps "Greptile Review" (completed/success) - never satisfies this gate
corroborated: 13 repository-owned checks ran and passed at head 359799022046cd4ded931c21dfc5b281b7498d57
```

`rc=0`.

## The forge fields the classifier reads

Both reads and their exact projections, so a future change to either can be checked against what the API actually returns rather than against this script's assumptions.

```sh
gh api "repos/kunchenguid/firstmate/commits/7af9572f9a183f52275e06fbc414aa51cbd8b230/check-runs?per_page=100" \
  --jq '.check_runs[] | [(.app.slug // ""), .status, (.conclusion // ""), .name] | @tsv'
gh api "repos/kunchenguid/firstmate/actions/runs?head_sha=7af9572f9a183f52275e06fbc414aa51cbd8b230&per_page=100" \
  --jq '.workflow_runs[] | [.status, (.conclusion // ""), (.path // .name // "")] | @tsv'
```

```
greptile-apps	completed	success	Greptile Review
```

```
completed	action_required	pull_request	.github/workflows/no-mistakes-required.yml
completed	action_required	pull_request	.github/workflows/ci.yml
```

The `app.slug` field is what separates this repository's own workflow jobs, which the GitHub Actions app creates under the slug `github-actions`, from every installed third party.
A workflow run's `path` is its workflow file and is stable; its `name` is the rendered `run-name` and is not, which is why refusals name the path.

## Portable regression

```sh
bin/fm-test-run.sh tests/fm-ci-corroborate.test.sh
```

Fourteen cases pass, covering the absence shape, a pipeline verdict that is never consulted, did-not-run held apart from ran-and-failed, the positive control, unfinished checks, held workflows, conditional skips, an unrecognised conclusion, an absent `gh`, each unreadable forge read, which commit is queried, task-id resolution, GitLab's refusal, and the report `bin/fm-pr-check.sh` prints when it records a PR-ready task.
