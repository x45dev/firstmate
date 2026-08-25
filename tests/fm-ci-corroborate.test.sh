#!/usr/bin/env bash
# Tests for bin/fm-ci-corroborate.sh: the one place firstmate and its workers
# establish that a pull request's "checks green" is true of real repository CI
# rather than of a check set that never ran.
#
# The four recorded defects this pins, and what each case reproduces:
#   (a) the ABSENCE shape - the head's only check is a third-party review bot
#       reporting success while every workflow sits at action_required and never
#       starts. Observed on three independent fork-raised PRs, and the shape a
#       plain "1 passed, 0 failed, 1 total" summary reads as green.
#   (b) an internal pipeline test step reporting success must never satisfy the
#       gate. Observed once on real CI, where the pipeline's own test step
#       passed on exactly the code the repository's suite then failed.
#   (c) did-not-run and ran-and-failed are separate buckets with separate
#       refusals, because conflating them is the root of the defect.
#
# Matrix:
#   (a) a third-party success with no repository-owned check is not green
#   (b) a pipeline reporting checks-passed cannot make a red head green, and is
#       never consulted at all
#   (c) did-not-run and ran-and-failed are distinguished in buckets and refusals
#   (d) repository-owned checks that ran and passed are green
#   (e) a third-party check is counted apart and never counted toward the gate
#   (f) an unfinished repository-owned check is did-not-run, not a pass
#   (g) a held workflow run is absence even when one repository check passed
#   (h) a conditional skip neither passes nor blocks, and skips alone are not green
#   (i) an unrecognised conclusion blocks rather than passes
#   (j) gh absent refuses instead of reporting green
#   (k) an unreadable check set or head refuses instead of reporting green
#   (l) the live head is what gets queried, and --head audits another commit
#   (m) a task id resolves the recorded PR, and an unrecorded one refuses
#   (n) a GitLab merge request is refused here rather than answered
#   (o) recording a PR-ready task says whether its checks are corroborated
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CORROBORATE="$ROOT/bin/fm-ci-corroborate.sh"
TMP_ROOT=$(fm_test_tmproot fm-ci-corroborate-tests)
BASE_PATH=$PATH
PR_URL=https://github.com/example/repo/pull/9
LIVE_HEAD=1111111111111111111111111111111111111111
OTHER_HEAD=2222222222222222222222222222222222222222

# One sandbox per case: a fake gh answering from per-case fixture files, plus a
# fake no-mistakes that logs every invocation so a case can prove the gate never
# asked a pipeline anything. Echoes the case dir.
make_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/fakebin" "$dir/state"
  printf '%s\n' "$LIVE_HEAD" > "$dir/head"
  : > "$dir/check-runs.tsv"
  : > "$dir/workflow-runs.tsv"
  : > "$dir/gh.log"
  : > "$dir/no-mistakes.log"
  # The fake gh answers exactly the three reads the gate makes, from files this
  # case owns, and logs the sha it was asked about so a case can prove which
  # commit was queried. Marker files drive the unreadable paths.
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_CASE_DIR/gh.log"
case " $* " in
  *" headRefOid "*)
    [ ! -e "$FM_CASE_DIR/head-unreadable" ] || exit 1
    cat "$FM_CASE_DIR/head"
    exit 0
    ;;
esac
for arg in "$@"; do
  case "$arg" in
    *check-runs*)
      [ ! -e "$FM_CASE_DIR/checks-unreadable" ] || exit 1
      cat "$FM_CASE_DIR/check-runs.tsv"
      exit 0
      ;;
    *actions/runs*)
      [ ! -e "$FM_CASE_DIR/runs-unreadable" ] || exit 1
      cat "$FM_CASE_DIR/workflow-runs.tsv"
      exit 0
      ;;
  esac
done
exit 0
SH
  # A pipeline that insists its own run was green. Nothing may consult it.
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_CASE_DIR/no-mistakes.log"
printf 'outcome: checks-passed\ntest step: completed with status 0\n'
exit 0
SH
  chmod +x "$dir/fakebin/gh" "$dir/fakebin/no-mistakes"
  printf '%s\n' "$dir"
}

# mirror_path_without <dir> <tool>: the whole search path re-exposed by symlink
# except one tool, because a real copy anywhere on PATH would prove nothing and
# an empty PATH would only prove the script needs coreutils.
mirror_path_without() {
  local dir=$1 omit=$2 bindir entry name
  mkdir -p "$dir"
  while IFS= read -r bindir; do
    [ -d "$bindir" ] || continue
    for entry in "$bindir"/*; do
      [ -e "$entry" ] || continue
      name=${entry##*/}
      [ "$name" = "$omit" ] && continue
      [ -e "$dir/$name" ] || ln -s "$entry" "$dir/$name" 2>/dev/null
    done
  done <<EOF
$(printf '%s\n' "$BASE_PATH" | tr ':' '\n')
EOF
  ! PATH="$dir" command -v "$omit" >/dev/null 2>&1 \
    || fail "the $omit-free search path still resolved $omit"
}

# Append one check run row: app slug, status, conclusion, name.
add_check() {  # <dir> <slug> <status> <conclusion> <name>
  printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" >> "$1/check-runs.tsv"
}

# Append one workflow run row: status, conclusion, workflow file path.
add_run() {  # <dir> <status> <conclusion> <path>
  printf '%s\t%s\t%s\n' "$2" "$3" "$4" >> "$1/workflow-runs.tsv"
}

# Run the gate in a case sandbox, capturing stdout and stderr together.
# Echoes the output; the exit status is the verdict under test.
run_gate() {  # <dir> [args...]
  local dir=$1
  shift
  FM_CASE_DIR="$dir" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$CORROBORATE" "$@" 2>&1
}

# (a) The absence shape. Three independent fork-raised PRs reached exactly this
# state: the head's only check is a third-party review bot reporting success,
# and both repository workflows sit completed/action_required with zero jobs.
# A summary that counts checks reads "1 passed, 0 failed, 1 total" here.
case_absence_is_not_green() {
  local dir out rc
  dir=$(make_case absence)
  add_check "$dir" greptile-apps completed success "Greptile Review"
  add_run "$dir" completed action_required .github/workflows/ci.yml
  add_run "$dir" completed action_required .github/workflows/no-mistakes-required.yml
  set +e
  out=$(run_gate "$dir" "$PR_URL")
  rc=$?
  set -e
  expect_code 1 "$rc" "absence: a head with no repository CI must not corroborate"
  assert_contains "$out" "ci-corroboration: not-green" "absence: verdict"
  assert_not_contains "$out" "ci-corroboration: green" "absence: no green verdict anywhere"
  assert_contains "$out" "no repository-owned check ran and concluded successfully" \
    "absence: the missing repository check is named"
  assert_contains "$out" "2 workflow runs never ran at this head" \
    "absence: the workflows that never started are counted"
  assert_contains "$out" "third-party checks at head: 1" \
    "absence: the review bot is counted, apart from the gate"
  assert_contains "$out" "repository-owned checks at head: 0 passed" \
    "absence: zero repository-owned checks is reported as zero"
  pass "a third-party success over a head with no repository CI is not green"
}

# (b) The stronger shape. A pipeline whose own test step passed on code the
# repository's suite then failed. The pipeline's word cannot make this green,
# and the gate must not even ask: it reads the forge and nothing else.
case_pipeline_word_is_not_evidence() {
  local dir out rc
  dir=$(make_case pipeline-word)
  add_check "$dir" github-actions completed success Lint
  add_check "$dir" github-actions completed failure "Behavior portable serial 1"
  add_run "$dir" completed failure .github/workflows/ci.yml
  set +e
  out=$(run_gate "$dir" "$PR_URL")
  rc=$?
  set -e
  expect_code 1 "$rc" "pipeline-word: a repository-owned failure must not corroborate"
  assert_contains "$out" "ci-corroboration: not-green" "pipeline-word: verdict"
  assert_contains "$out" "1 repository-owned checks ran and failed at this head" \
    "pipeline-word: the failing repository check is what refuses"
  assert_contains "$out" "Behavior portable serial 1" \
    "pipeline-word: the failing check is named"
  [ ! -s "$dir/no-mistakes.log" ] \
    || fail "pipeline-word: the gate consulted a pipeline instead of the forge"
  pass "a pipeline reporting checks-passed cannot make a red head green, and is never consulted"
}

# (c) The two states the defect conflated. Same repository, same one workflow,
# same count of non-passing checks - one ran and failed, the other never ran -
# and the gate must bucket and report them apart.
case_did_not_run_distinguished_from_failed() {
  local failed_dir absent_dir failed_out absent_out
  failed_dir=$(make_case ran-and-failed)
  add_check "$failed_dir" github-actions completed success Lint
  add_check "$failed_dir" github-actions completed failure "Repo invariants"
  add_run "$failed_dir" completed failure .github/workflows/ci.yml
  absent_dir=$(make_case did-not-run)
  add_check "$absent_dir" github-actions completed success Lint
  add_check "$absent_dir" github-actions completed action_required "Repo invariants"
  add_run "$absent_dir" completed action_required .github/workflows/ci.yml
  set +e
  failed_out=$(run_gate "$failed_dir" "$PR_URL")
  absent_out=$(run_gate "$absent_dir" "$PR_URL")
  set -e

  assert_contains "$failed_out" "1 passed, 1 failed, 0 did-not-run" \
    "ran-and-failed: the failure is bucketed as a failure"
  assert_contains "$failed_out" "repository-owned checks ran and failed" \
    "ran-and-failed: the refusal says it ran"
  assert_not_contains "$failed_out" "repository-owned checks never ran" \
    "ran-and-failed: must not be reported as absence"
  assert_contains "$failed_out" "1 workflow runs failed at this head" \
    "ran-and-failed: the workflow is bucketed as a failure"

  assert_contains "$absent_out" "1 passed, 0 failed, 1 did-not-run" \
    "did-not-run: absence is bucketed as absence"
  assert_contains "$absent_out" "1 repository-owned checks never ran at this head" \
    "did-not-run: the refusal says it never ran"
  assert_not_contains "$absent_out" "repository-owned checks ran and failed" \
    "did-not-run: must not be reported as a failure"
  assert_contains "$absent_out" "1 workflow runs never ran at this head" \
    "did-not-run: the held workflow is bucketed as absence"
  pass "did-not-run and ran-and-failed are separate buckets with separate refusals"
}

# (d) and (e) The positive control, with a third-party check alongside. The
# verdict comes from the repository's own checks; the bot is counted apart and
# changes nothing.
case_repository_checks_are_green() {
  local dir out rc
  dir=$(make_case green)
  add_check "$dir" github-actions completed success Lint
  add_check "$dir" github-actions completed success "Repo invariants"
  add_check "$dir" greptile-apps completed success "Greptile Review"
  add_run "$dir" completed success .github/workflows/ci.yml
  set +e
  out=$(run_gate "$dir" "$PR_URL")
  rc=$?
  set -e
  expect_code 0 "$rc" "green: repository checks that ran and passed must corroborate"
  assert_contains "$out" "ci-corroboration: green" "green: verdict"
  assert_contains "$out" "corroborated: 2 repository-owned checks ran and passed at head $LIVE_HEAD" \
    "green: the corroborated line names the count and the head"
  assert_contains "$out" "third-party checks at head: 1 (never satisfy this gate)" \
    "green: the bot is counted apart from the two that carried the verdict"
  assert_contains "$out" "repository-owned checks at head: 2 passed" \
    "green: the bot is not counted toward the repository total"
  pass "repository-owned checks that ran and passed are green, with third parties counted apart"
}

# (f) An unfinished check has not concluded, whatever it may conclude later.
case_unfinished_check_is_absence() {
  local dir out rc
  dir=$(make_case unfinished)
  add_check "$dir" github-actions completed success Lint
  add_check "$dir" github-actions in_progress "" "Behavior portable serial 1"
  add_check "$dir" github-actions queued "" "Behavior portable serial 2"
  add_run "$dir" in_progress "" .github/workflows/ci.yml
  set +e
  out=$(run_gate "$dir" "$PR_URL")
  rc=$?
  set -e
  expect_code 1 "$rc" "unfinished: a check still running must not corroborate"
  assert_contains "$out" "2 repository-owned checks never ran at this head" \
    "unfinished: both unfinished checks are absence"
  assert_contains "$out" "1 workflow runs never ran at this head" \
    "unfinished: the unfinished workflow run is absence"
  pass "an unfinished repository-owned check is did-not-run, not a pass"
}

# (g) Partial absence: one repository check really did pass, and a second
# workflow was held. The passing check must not cover for the held one.
case_held_workflow_is_absence() {
  local dir out rc
  dir=$(make_case held-workflow)
  add_check "$dir" github-actions completed success Lint
  add_run "$dir" completed success .github/workflows/ci.yml
  add_run "$dir" completed action_required .github/workflows/no-mistakes-required.yml
  set +e
  out=$(run_gate "$dir" "$PR_URL")
  rc=$?
  set -e
  expect_code 1 "$rc" "held-workflow: a held workflow must not be covered by a passing check"
  assert_contains "$out" "1 workflow runs never ran at this head" \
    "held-workflow: the held workflow is reported"
  assert_contains "$out" "no-mistakes-required.yml" "held-workflow: the held workflow is named"
  pass "a held workflow run is absence even when another repository check passed"
}

# (h) A conditional job that legitimately did not apply must not block, and must
# not stand in for a check that actually ran either.
case_skips_neither_pass_nor_block() {
  local mixed_dir only_dir mixed_out only_out mixed_rc only_rc
  mixed_dir=$(make_case skip-mixed)
  add_check "$mixed_dir" github-actions completed success Lint
  add_check "$mixed_dir" github-actions completed skipped "Windows spike"
  add_check "$mixed_dir" github-actions completed neutral "Advisory scan"
  add_run "$mixed_dir" completed success .github/workflows/ci.yml
  only_dir=$(make_case skip-only)
  add_check "$only_dir" github-actions completed skipped "Windows spike"
  add_run "$only_dir" completed skipped .github/workflows/windows-herdr-spike.yml
  set +e
  mixed_out=$(run_gate "$mixed_dir" "$PR_URL")
  mixed_rc=$?
  only_out=$(run_gate "$only_dir" "$PR_URL")
  only_rc=$?
  set -e
  expect_code 0 "$mixed_rc" "skip-mixed: a conditional skip must not block a real pass"
  assert_contains "$mixed_out" "1 passed, 0 failed, 0 did-not-run, 2 skipped" \
    "skip-mixed: skips are bucketed apart from passes"
  expect_code 1 "$only_rc" "skip-only: skips alone are not evidence that CI ran"
  assert_contains "$only_out" "no repository-owned check ran and concluded successfully" \
    "skip-only: the refusal is absence of a real pass"
  pass "a conditional skip neither passes nor blocks, and skips alone are not green"
}

# (i) The catch-all must block. A conclusion this gate has never seen is an
# unknown, and an unknown that passes is how the next shape of this defect
# would get through.
case_unknown_conclusion_blocks() {
  local dir out rc
  dir=$(make_case unknown-conclusion)
  add_check "$dir" github-actions completed success Lint
  add_check "$dir" github-actions completed some_future_conclusion "Repo invariants"
  add_run "$dir" completed success .github/workflows/ci.yml
  set +e
  out=$(run_gate "$dir" "$PR_URL")
  rc=$?
  set -e
  expect_code 1 "$rc" "unknown-conclusion: an unrecognised conclusion must block"
  assert_contains "$out" "1 repository-owned checks ran and failed at this head" \
    "unknown-conclusion: the unknown lands in the blocking bucket"
  pass "an unrecognised conclusion blocks rather than passes"
}

# (j) With no gh there is no forge read at all, so there is no verdict to give.
case_absent_gh_refuses() {
  local dir out rc nogh
  dir=$(make_case absent-gh)
  add_check "$dir" github-actions completed success Lint
  add_run "$dir" completed success .github/workflows/ci.yml
  # The whole search path minus gh alone, so the refusal is about gh and not
  # about a shell that lost its coreutils.
  nogh="$dir/nogh"
  mirror_path_without "$nogh" gh
  set +e
  out=$(FM_CASE_DIR="$dir" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" \
    PATH="$nogh" "$CORROBORATE" "$PR_URL" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "absent-gh: no forge read must refuse"
  assert_contains "$out" "ci-corroboration: not-green" "absent-gh: verdict"
  assert_contains "$out" "gh is not on PATH" "absent-gh: the missing tool is named"
  pass "gh absent refuses instead of reporting green"
}

# (k) A read that failed is an unknown, and an unknown is not green. Each of the
# three reads refuses on its own.
case_unreadable_forge_refuses() {
  local dir out rc marker
  for marker in head-unreadable checks-unreadable runs-unreadable; do
    dir=$(make_case "unreadable-$marker")
    add_check "$dir" github-actions completed success Lint
    add_run "$dir" completed success .github/workflows/ci.yml
    : > "$dir/$marker"
    set +e
    out=$(run_gate "$dir" "$PR_URL")
    rc=$?
    set -e
    expect_code 1 "$rc" "unreadable-$marker: an unreadable forge must refuse"
    assert_contains "$out" "ci-corroboration: not-green" "unreadable-$marker: verdict"
    assert_contains "$out" "could not be read from the forge" \
      "unreadable-$marker: the unreadable read is named"
  done
  pass "an unreadable head, check set, or run set refuses instead of reporting green"
}

# (l) A verdict is about one exact commit. The default is the live head read
# from the forge, and --head only redirects the read for an audit.
case_head_is_the_one_queried() {
  local dir out rc
  dir=$(make_case live-head)
  add_check "$dir" github-actions completed success Lint
  add_run "$dir" completed success .github/workflows/ci.yml
  set +e
  out=$(run_gate "$dir" "$PR_URL")
  rc=$?
  set -e
  expect_code 0 "$rc" "live-head: the fixture head should corroborate"
  assert_contains "$out" "head: $LIVE_HEAD" "live-head: the live head is reported"
  assert_grep "$LIVE_HEAD" "$dir/gh.log" "live-head: the live head is what was queried"
  assert_no_grep "$OTHER_HEAD" "$dir/gh.log" "live-head: no other commit was queried"

  dir=$(make_case audit-head)
  add_check "$dir" github-actions completed success Lint
  add_run "$dir" completed success .github/workflows/ci.yml
  set +e
  out=$(run_gate "$dir" "$PR_URL" --head "$OTHER_HEAD")
  rc=$?
  set -e
  expect_code 0 "$rc" "audit-head: an explicit head should corroborate from its own reads"
  assert_contains "$out" "head: $OTHER_HEAD" "audit-head: the audited commit is reported"
  assert_grep "$OTHER_HEAD" "$dir/gh.log" "audit-head: the audited commit is what was queried"
  assert_no_grep headRefOid "$dir/gh.log" "audit-head: an explicit head skips the live read"

  set +e
  out=$(run_gate "$dir" "$PR_URL" --head not-a-sha)
  rc=$?
  set -e
  expect_code 2 "$rc" "audit-head: a malformed head is an unusable request"
  pass "the live head is what gets queried, and --head audits another commit"
}

# (m) Firstmate holds a task id rather than a URL, so the recorded PR resolves.
case_task_id_resolves_recorded_pr() {
  local dir out rc
  dir=$(make_case task-id)
  add_check "$dir" github-actions completed success Lint
  add_run "$dir" completed success .github/workflows/ci.yml
  fm_write_meta "$dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "kind=ship" \
    "mode=no-mistakes" \
    "pr=$PR_URL"
  set +e
  out=$(run_gate "$dir" task-x1)
  rc=$?
  set -e
  expect_code 0 "$rc" "task-id: a recorded PR should resolve and corroborate"
  assert_contains "$out" "pr: $PR_URL" "task-id: the recorded PR is the one corroborated"

  fm_write_meta "$dir/state/task-x2.meta" "window=fm-task-x2" "kind=ship"
  set +e
  out=$(run_gate "$dir" task-x2)
  rc=$?
  set -e
  expect_code 2 "$rc" "task-id: a task with no recorded PR is an unusable request"
  assert_contains "$out" "no PR is recorded" "task-id: the missing PR is named"
  pass "a task id resolves the recorded PR, and an unrecorded one refuses"
}

# (n) GitLab merge requests are verified at merge time by bin/fm-pr-merge.sh
# against the head pipeline. This gate says so rather than answering for a
# forge it does not read.
case_gitlab_is_refused_here() {
  local dir out rc
  dir=$(make_case gitlab)
  set +e
  out=$(run_gate "$dir" https://gitlab.example/group/subgroup/project/-/merge_requests/7)
  rc=$?
  set -e
  expect_code 2 "$rc" "gitlab: a merge request is not answered here"
  assert_not_contains "$out" "ci-corroboration: green" "gitlab: no green verdict is given"
  assert_contains "$out" "fm-pr-merge.sh" "gitlab: the owner of that verdict is named"
  pass "a GitLab merge request is refused here rather than answered"
}

# (o) The wiring. Recording a PR-ready task is where a validation tool's verdict
# enters firstmate's own records, and where a merge that keys off it begins, so
# arming reports whether the forge corroborates the checks. It reports and never
# refuses: a repository with no PR CI at all is supported and must still arm.
case_arming_reports_corroboration() {
  local dir out rc
  for dir in "$(make_case arming-absence)" "$(make_case arming-green)"; do
    mkdir -p "$dir/root/bin" "$dir/home/state" "$dir/wt"
    cat > "$dir/root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$dir/root/bin/fm-guard.sh"
    fm_write_meta "$dir/home/state/task-p1.meta" \
      "window=fm-task-p1" \
      "worktree=$dir/wt" \
      "kind=ship" \
      "mode=no-mistakes"
  done

  # The absence shape, arriving at the moment firstmate records the PR.
  dir="$TMP_ROOT/arming-absence"
  add_check "$dir" greptile-apps completed success "Greptile Review"
  add_run "$dir" completed action_required .github/workflows/ci.yml
  set +e
  out=$(FM_CASE_DIR="$dir" FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-pr-check.sh" task-p1 "$PR_URL" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "arming-absence: arming must still succeed with no repository CI"
  assert_contains "$out" "armed: state/task-p1.check.sh" "arming-absence: the merge poll is armed"
  assert_contains "$out" "repository CI is NOT corroborated at this head" \
    "arming-absence: recording a PR over an absent check set must say so"
  assert_contains "$out" "is not evidence" \
    "arming-absence: the warning must name what the verdict is not"
  assert_not_contains "$out" "notice: repository CI corroborated" \
    "arming-absence: an absent check set must not be reported as corroborated"

  # The same path over a head where repository CI really did run.
  dir="$TMP_ROOT/arming-green"
  add_check "$dir" github-actions completed success Lint
  add_check "$dir" github-actions completed success "Repo invariants"
  add_run "$dir" completed success .github/workflows/ci.yml
  set +e
  out=$(FM_CASE_DIR="$dir" FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-pr-check.sh" task-p1 "$PR_URL" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "arming-green: arming must succeed"
  assert_contains "$out" "armed: state/task-p1.check.sh" "arming-green: the merge poll is armed"
  assert_contains "$out" "notice: repository CI corroborated - 2 repository-owned checks ran and passed" \
    "arming-green: a corroborated head must be reported as corroborated"
  assert_not_contains "$out" "NOT corroborated" \
    "arming-green: a corroborated head must not warn"
  pass "recording a PR-ready task reports whether the forge corroborates its checks"
}

case_absence_is_not_green
case_pipeline_word_is_not_evidence
case_did_not_run_distinguished_from_failed
case_repository_checks_are_green
case_unfinished_check_is_absence
case_held_workflow_is_absence
case_skips_neither_pass_nor_block
case_unknown_conclusion_blocks
case_absent_gh_refuses
case_unreadable_forge_refuses
case_head_is_the_one_queried
case_task_id_resolves_recorded_pr
case_gitlab_is_refused_here
case_arming_reports_corroboration
