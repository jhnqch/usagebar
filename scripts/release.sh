#!/bin/bash
# Releases UsageBar: `scripts/release.sh vX.Y.Z` tags the current commit of
# main, pushes the tag and creates a GitHub Release with generated notes.
# Installed apps find it through GitHub's "latest release" and offer
# "Update to vX.Y.Z".
#
# Refuses a tag that isn't vX.Y.Z, uncommitted changes to tracked files, a
# branch other than main, a main that differs from origin/main, and a tag
# that already exists here or on origin. Needs the GitHub CLI (`gh`),
# signed in.
set -euo pipefail
cd "$(dirname "$0")/.."

die() {
  echo "release: $*" >&2
  exit 1
}

tag="${1:-}"
[[ $tag =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
  || die "usage: scripts/release.sh vX.Y.Z (got '${tag}'; a release tag is vX.Y.Z, e.g. v1.2.0)"
command -v gh >/dev/null || die "needs the GitHub CLI: https://cli.github.com"

[ -z "$(git status --porcelain --untracked-files=no)" ] || die "uncommitted changes; commit or stash them first"
branch="$(git symbolic-ref --quiet --short HEAD || true)"
[ "$branch" = "main" ] || die "releases are cut from main, not '${branch:-a detached HEAD}'"

git fetch --quiet --tags origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "main isn't the same as origin/main; push or pull first"
if git rev-parse --quiet --verify "refs/tags/$tag" >/dev/null || git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null; then
  die "$tag already exists"
fi

git tag --annotate "$tag" --message "UsageBar $tag"
git push --quiet origin "refs/tags/$tag"
gh release create "$tag" --verify-tag --generate-notes --title "UsageBar $tag"
echo "Released $tag"
