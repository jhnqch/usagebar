#!/bin/bash
# Releases UsageBar: `scripts/release.sh vX.Y.Z` tags the current commit of
# main, pushes the tag and creates a GitHub Release with generated notes.
# Installed apps find it through GitHub's "latest release" and offer
# "Update to vX.Y.Z".
#
# Refuses a tag that isn't vX.Y.Z, `gh` (the GitHub CLI) missing or signed
# out, uncommitted changes to tracked files, a branch other than main, a main
# that differs from origin/main, a tag that already exists here or on origin
# at another commit, and a tag that's already released. Rerunnable: when an
# earlier run tagged this commit but its push or `gh release create` failed,
# it pushes that same tag and creates the release, without retagging.
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
gh auth status --active --hostname github.com >/dev/null 2>&1 || die "gh isn't signed in to github.com; run gh auth login first"

repository="$(scripts/build-info.sh | sed -n 's/^repository=//p')"
[ -n "$repository" ] && git config --get remote.origin.url >/dev/null || die "origin isn't a GitHub repository"
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "uncommitted changes; commit or stash them first"
branch="$(git symbolic-ref --quiet --short HEAD || true)"
[ "$branch" = "main" ] || die "releases are cut from main, not '${branch:-a detached HEAD}'"

git fetch --quiet --tags origin || die "couldn't fetch origin (does a local tag differ from origin's?)"
head="$(git rev-parse HEAD)"
[ "$head" = "$(git rev-parse origin/main)" ] || die "main isn't the same as origin/main; push or pull first"

# A tag already here or on origin must be this commit's, from an earlier run.
local_tag="$(git rev-parse --quiet --verify "refs/tags/$tag" || true)"
remote_tag="$(git ls-remote --tags origin "refs/tags/$tag" | cut -f1)"
if [ -n "$local_tag$remote_tag" ]; then
  if [ -z "$local_tag" ] || { [ -n "$remote_tag" ] && [ "$remote_tag" != "$local_tag" ] ; } \
    || [ "$(git rev-parse "refs/tags/$tag^{commit}")" != "$head" ]; then
    die "$tag already exists at another commit"
  fi
  # The repo installed apps check: origin's, whatever `gh repo set-default` says.
  if gh release view "$tag" --repo "$repository" >/dev/null 2>&1; then
    die "$tag is already released"
  fi
  echo "$tag already tags this commit; finishing its release"
else
  git tag --annotate "$tag" --message "UsageBar $tag"
fi
git push --quiet origin "refs/tags/$tag"
gh release create "$tag" --repo "$repository" --verify-tag --generate-notes --title "UsageBar $tag"
echo "Released $tag"
