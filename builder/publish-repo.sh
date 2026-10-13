#!/usr/bin/env bash
#
# publish-repo.sh — build claude-desktop-builder and publish it as a dnf
# repository on the "repo" branch, served by raw.githubusercontent.com.
# No CI needed. Needs rpm-build and createrepo_c.
#
# Usage: builder/publish-repo.sh [--no-push]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(dirname "$HERE")"
cd "$TOP"
SLUG="$(git remote get-url origin | sed -E 's#(\.git)?$##; s#.*github\.com[:/]##')"
BASE="https://raw.githubusercontent.com/$SLUG/repo"

W="$(mktemp -d)"; trap 'git worktree remove --force "$W/site" 2>/dev/null || true; rm -rf "$W"' EXIT
bash "$HERE/make-srpm.sh" "$W" >/dev/null
rpmbuild --define "_topdir $W/rb" --define "dist %{nil}" ${RPMBUILD_EXTRA:-} \
         --rebuild "$W"/*.src.rpm >"$W/rpmbuild.log" 2>&1 \
    || { tail -30 "$W/rpmbuild.log" >&2; exit 1; }

git fetch -q origin repo 2>/dev/null || true
if git rev-parse -q --verify origin/repo >/dev/null; then
    git worktree add -q -B repo "$W/site" origin/repo
else
    git worktree add -q --detach "$W/site"
    ( cd "$W/site" && git checkout -q --orphan repo && git rm -q -rf . )
fi

cp "$W"/*.src.rpm "$W"/rb/RPMS/noarch/*.rpm "$W/site/"
createrepo_c -q --update "$W/site"
cat > "$W/site/claude-desktop.repo" <<REPO
[claude-desktop-builder]
name=Claude Desktop builder
baseurl=$BASE/
enabled=1
gpgcheck=0
metadata_expire=6h
REPO
cat > "$W/site/README.md" <<MD
# Dépôt dnf claude-desktop-builder

Branche générée par \`builder/publish-repo.sh\` (voir la branche main).

    sudo dnf config-manager addrepo --from-repofile=$BASE/claude-desktop.repo
    sudo dnf install claude-desktop-builder
    sudo claude-desktop-update
MD

cd "$W/site"
git add -A
if git diff --cached --quiet; then echo "rien de nouveau à publier"; exit 0; fi
git commit -q -m "Publish $(ls claude-desktop-builder-*.noarch.rpm | sort -V | tail -1)"
[ "${1:-}" = --no-push ] && { echo "commit créé sur la branche repo (non poussé)"; exit 0; }
git push -q -u origin repo
echo "publié : $BASE/claude-desktop.repo"
