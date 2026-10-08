# shellcheck shell=bash
# ONE OWNER for the question "has this isolated copy's committed work actually
# LANDED?", asked with explicit arguments so every caller gets the same answer
# from the same evidence.
#
# bin/fm-teardown.sh asks it before destroying a copy, and asks it a second,
# stricter way when a task's runtime endpoint record is gone: a host restart can
# destroy the endpoint field of a record whose work is already fully landed, and
# cleanup then has nothing to shut down and no written endpoint to validate. The
# only safe way past that is to prove landed-ness WITHOUT reading the record
# that the restart damaged, which is what fm_work_landed_independently does.
#
# Two routes prove it, in this order:
#   1. A merged pull request on the forge whose head CONTAINS the current local
#      work - either HEAD is an ancestor of the PR head, or every commit this
#      copy has that no remote carries is replayed in that head by patch id.
#      This is the squash-merge-then-delete-branch flow, where the branch's own
#      commits live nowhere on a remote yet the change is fully merged.
#   2. The content is already present in the up-to-date default branch. A 3-way
#      merge of the default branch with HEAD that adds nothing to the default
#      branch's tree proves the change landed, however it was collapsed.
# Anything else is NOT landed. Inconclusive is not landed either: a gh error, a
# missing default ref, and a merge conflict all return non-zero so the caller
# refuses rather than guesses. A diverged copy is deliberately not accepted -
# path-set coverage, git cherry, and merge-tree containment each fail to prove
# content landed without also accepting unlanded edits to the same paths.
#
# Uncommitted changes are never landed, and fm_work_landed_dirty is the single
# owner of which working-tree entries count as work. Firstmate's own per-task
# harness artifacts do not: the agent hook files it writes into the copy are
# fleet plumbing, not the captain's change.
#
# Output globals, set by the functions that resolve them:
#   FM_WORK_LANDED_PR_URL    the pull request url the forge resolved, when a
#                            lookup discovered one the caller did not supply
#   FM_WORK_LANDED_EVIDENCE  one line naming the proof that answered, for the
#                            caller to print
# Both are cleared at the start of every call that can set them, so a stale
# value from an earlier task can never be reported as this one's evidence.

# Untracked paths that are firstmate's own harness plumbing rather than work.
FM_WORK_LANDED_PLUMBING_RE='^\?\? (\.claude/|\.fm-(grok|kimi)-turnend$)'

# fm_work_landed_dirty: print the first working-tree entry that counts as
# uncommitted work, or nothing when the copy is clean. Returns non-zero only
# when the copy cannot be inspected at all, which the caller must treat as
# unproven rather than clean.
fm_work_landed_dirty() {  # <worktree>
  local wt=$1 raw
  raw=$(git -C "$wt" status --porcelain 2>/dev/null) || return 1
  printf '%s\n' "$raw" | grep -vE "$FM_WORK_LANDED_PLUMBING_RE" | head -1 || true
}

# fm_work_landed_default_branch: the project's default branch name, from
# origin/HEAD when the clone records one and otherwise from the conventional
# local names. Returns non-zero when nothing names it.
fm_work_landed_default_branch() {  # <project-dir>
  local proj=$1 ref branch
  ref=$(git -C "$proj" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$proj" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

fm_work_landed_pr_number_from_branch() {  # <worktree> <branch>
  local wt=$1 branch=$2 out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  out=$( cd "$wt" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null ) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

fm_work_landed_pr_number_from_target() {  # <target>
  local target=$1 n
  case "$target" in
    '' ) return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*)
      n=${target%%[!0-9]*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

# Make <commit> resolvable in this copy, fetching the pull request's own head
# ref when the branch it came from was deleted after the merge.
fm_work_landed_ensure_commit_object() {  # <worktree> <target> <commit>
  local wt=$1 target=$2 commit=$3 n
  git -C "$wt" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  n=$(fm_work_landed_pr_number_from_target "$target") || return 1
  git -C "$wt" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$wt" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
  git -C "$wt" cat-file -e "$commit^{commit}" 2>/dev/null
}

fm_work_landed_patch_id() {  # <worktree> <commit>
  local wt=$1 commit=$2
  git -C "$wt" show --pretty=medium --no-ext-diff "$commit" 2>/dev/null \
    | git patch-id --stable 2>/dev/null \
    | awk 'NR == 1 { print $1 }'
}

# Is every commit this copy holds that no remote carries already replayed in
# <pr-head> by patch id? This is what recognizes a pipeline rebase whose
# per-commit hashes no longer match the merged head.
fm_work_landed_unpushed_patches_are_in_head() {  # <worktree> <pr-head>
  local wt=$1 pr_head=$2 current base pr_patch_ids commit patch_id unpushed
  current=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || return 1
  base=$(git -C "$wt" merge-base "$current" "$pr_head" 2>/dev/null) || return 1
  pr_patch_ids=$(
    git -C "$wt" log --format=%H "$base..$pr_head" -- 2>/dev/null \
      | while IFS= read -r commit; do
          fm_work_landed_patch_id "$wt" "$commit"
        done \
      | sed '/^$/d' \
      | sort -u
  ) || return 1
  [ -n "$pr_patch_ids" ] || return 1
  unpushed=$(git -C "$wt" log --format=%H HEAD --not --remotes -- 2>/dev/null) || return 1
  [ -n "$unpushed" ] || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    patch_id=$(fm_work_landed_patch_id "$wt" "$commit") || return 1
    [ -n "$patch_id" ] || return 1
    printf '%s\n' "$pr_patch_ids" | grep -qxF "$patch_id" || return 1
  done <<EOF
$unpushed
EOF
}

# Route 1. Resolves the pull request from <recorded-pr> when the caller supplies
# one, and otherwise from the copy's own branch name on the forge - which is the
# only route available when the task's record cannot be trusted to name it. Asks
# the forge for both the state and the head, and returns 0 only for a merged
# pull request whose head contains the current local work. Sets
# FM_WORK_LANDED_PR_URL to the url the forge reported when the caller supplied
# none. Returns non-zero on any gh error, so the caller falls through to route 2.
fm_work_landed_pr_is_merged() {  # <worktree> <recorded-pr> <branch>
  local wt=$1 recorded=$2 branch=$3
  local target view state remainder head resolved_url current landed=0
  FM_WORK_LANDED_PR_URL=
  if [ -n "$recorded" ]; then
    target=$recorded
  else
    target=$(fm_work_landed_pr_number_from_branch "$wt" "$branch") || return 1
  fi
  [ -n "$target" ] || return 1
  view=$(cd "$wt" && gh pr view "$target" --json state,headRefOid,url -q '.state + "\t" + .headRefOid + "\t" + .url' 2>/dev/null) || return 1
  state=${view%%$'\t'*}
  remainder=${view#*$'\t'}
  [ "$state" != "$view" ] || return 1
  head=${remainder%%$'\t'*}
  resolved_url=${remainder#*$'\t'}
  [ "$head" != "$remainder" ] || return 1
  case "$state" in
    MERGED|merged) ;;
    *) return 1 ;;
  esac
  [ -n "$head" ] || return 1
  fm_work_landed_ensure_commit_object "$wt" "$target" "$head" || return 1
  current=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || return 1
  if git -C "$wt" merge-base --is-ancestor "$current" "$head" 2>/dev/null; then
    landed=1
  elif fm_work_landed_unpushed_patches_are_in_head "$wt" "$head"; then
    landed=1
  fi
  [ "$landed" = 1 ] || return 1
  if [ -z "$recorded" ]; then
    [ -n "$resolved_url" ] || return 1
    FM_WORK_LANDED_PR_URL=$resolved_url
  fi
  FM_WORK_LANDED_EVIDENCE="merged pull request $target contains this copy's work"
  return 0
}

# Route 2. Fetches the default branch first, so the answer is about the branch
# as it stands on the forge rather than a stale local ref, then 3-way merges it
# with HEAD: when HEAD introduces nothing the default branch does not already
# contain, the merged tree equals the default branch's tree. Isolating the
# branch's own changes this way keeps unrelated commits the default branch
# gained past the merge-base from counting as additions. Returns non-zero when
# inconclusive, so the caller refuses rather than guesses.
fm_work_landed_content_in_default() {  # <worktree> <project-dir>
  local wt=$1 proj=$2 name ref default_tree merged_tree
  name=$(fm_work_landed_default_branch "$proj") || return 1
  if git -C "$wt" remote get-url origin >/dev/null 2>&1; then
    git -C "$wt" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || return 1
    ref="refs/remotes/origin/$name"
  elif git -C "$wt" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
  default_tree=$(git -C "$wt" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$wt" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$default_tree" ] || return 1
  FM_WORK_LANDED_EVIDENCE="this copy's content is already present in $ref"
  return 0
}

# Has the copy's committed work landed, though its commits are not reachable
# from any remote-tracking branch? True on either route above. <recorded-pr> may
# be empty, in which case the pull request is discovered from the branch.
fm_work_landed() {  # <worktree> <project-dir> <recorded-pr> <branch>
  local wt=$1 proj=$2 recorded=$3 branch=$4
  FM_WORK_LANDED_PR_URL=
  FM_WORK_LANDED_EVIDENCE=
  fm_work_landed_pr_is_merged "$wt" "$recorded" "$branch" && return 0
  fm_work_landed_content_in_default "$wt" "$proj"
}

# The stricter question, for a caller that cannot trust the task's own written
# record - because that record is what was damaged. Nothing here reads the
# record: the copy answers whether anything is uncommitted and what its branch
# and HEAD are, and the forge answers whether that work is merged. A pull
# request recorded on the task is deliberately NOT consulted, and neither is a
# recorded branch, PR head, or landing verdict.
#
# Returns 0 only when the copy is inspectable and clean AND one of the two
# routes proves the work landed, with FM_WORK_LANDED_EVIDENCE naming which.
# Returns 1 with FM_WORK_LANDED_EVIDENCE naming what could not be proven
# otherwise - including when the copy is simply absent, since a copy that is not
# there cannot answer, and the caller must refuse rather than assume.
fm_work_landed_independently() {  # <worktree> <project-dir>
  local wt=$1 proj=$2 dirty branch
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_WORK_LANDED_PR_URL=
  FM_WORK_LANDED_EVIDENCE=
  if [ ! -d "$wt" ] || ! git -C "$wt" rev-parse --verify HEAD >/dev/null 2>&1; then
    FM_WORK_LANDED_EVIDENCE="the local copy at $wt cannot be inspected for landed work"
    return 1
  fi
  if ! dirty=$(fm_work_landed_dirty "$wt"); then
    FM_WORK_LANDED_EVIDENCE="the local copy at $wt cannot be inspected for uncommitted changes"
    return 1
  fi
  if [ -n "$dirty" ]; then
    FM_WORK_LANDED_EVIDENCE="the local copy at $wt has uncommitted changes"
    return 1
  fi
  branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'HEAD\n')
  if fm_work_landed "$wt" "$proj" "" "$branch"; then
    FM_WORK_LANDED_EVIDENCE="the local copy is clean and $FM_WORK_LANDED_EVIDENCE"
    return 0
  fi
  FM_WORK_LANDED_EVIDENCE="neither a merged pull request for branch $branch nor the default branch proves this copy's work landed"
  return 1
}
