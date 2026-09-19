#!/usr/bin/env bash
# usage: drive-update.sh <gitignore-ref>   (ROOT = firstmate worktree)
set -u
ROOT=/home/dev/.no-mistakes/worktrees/5480956096ee/01M2VX82EFVJPRGVPPWXFK0SE4
REF=$1
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
w=$(mktemp -d /tmp/fm-wr-drive.XXXXXX)
mkdir -p $w/home/state $w/home/data $w/fakebin $w/fake; : > $w/fake/windows; touch $w/home/state/.last-watcher-beat
printf '#!/usr/bin/env bash\ncase "${1:-}" in list-windows) cat "$FM_FAKE_DIR/windows";; esac\n' > $w/fakebin/tmux; chmod +x $w/fakebin/tmux
git init -q --bare $w/origin.git; git -C $w/origin.git symbolic-ref HEAD refs/heads/main
git clone -q $w/origin.git $w/seed 2>/dev/null
git -C $ROOT show $REF:.gitignore > $w/seed/.gitignore
printf 'v1\n' > $w/seed/AGENTS.md
mkdir -p $w/seed/bin; printf '#!/usr/bin/env bash\nexit 0\n' > $w/seed/bin/fm-remote-secondmate-control.sh; chmod +x $w/seed/bin/fm-remote-secondmate-control.sh
git -C $w/seed add -A; git -C $w/seed commit -qm c1; git -C $w/seed push -q origin main
git clone -q $w/origin.git $w/main; git -C $w/main remote set-head origin main >/dev/null 2>&1
# wrangler run in the checkout: placeholder bytes only
mkdir -p $w/main/.wrangler/cache; printf 'placeholder\n' > $w/main/.wrangler/cache/wrangler-account.json
# origin moves ahead with an instruction update
printf 'v2\n' > $w/seed/AGENTS.md; git -C $w/seed commit -qam c2; git -C $w/seed push -q origin main
echo "== git status --porcelain in checkout:"; git -C $w/main status --porcelain
echo "== fm-update.sh:"
PATH="$w/fakebin:$PATH" FM_FAKE_DIR="$w/fake" FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$ROOT/bin/fm-update.sh" 2>&1
echo "== AGENTS.md in checkout now: $(cat $w/main/AGENTS.md)"
echo "== git add -A; staged:"; git -C $w/main add -A; git -C $w/main diff --cached --name-only
rm -rf $w
