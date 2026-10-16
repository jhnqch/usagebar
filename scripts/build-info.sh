#!/bin/bash
# Prints what scripts/build.sh records in the app's Info.plist, as
# key=value lines, for the source folder this script is in:
#
#   version=     `git describe --tags` (v1.2.0, or v1.2.0-3-gabc1234 past it)
#   repository=  owner/name of `origin` when it's on github.com
#   source=      the checkout's physical path
#
# The app uses them to check for and install updates. Outside a git
# checkout (a tarball), source is empty, the repository is the upstream one
# and the version comes from a usagebar-X.Y.Z folder name, if any. Only
# owner/name is taken from the origin URL: credentials in it never are.
set -euo pipefail
cd "$(dirname "$0")/.."

UPSTREAM="jhnqch/usagebar"
here="$(pwd -P)"
version="" repository="" source=""

top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$top" ] && [ "$(cd "$top" && pwd -P)" = "$here" ]; then
  source="$here"
  version="$(git describe --tags --match 'v[0-9]*' 2>/dev/null || true)"
  url="$(git config --get remote.origin.url 2>/dev/null || true)"
  url="${url%/}"
  shopt -s nocasematch
  if [[ $url =~ ^(https://([^/@]+@)?github\.com/|ssh://([^/@]+@)?github\.com/|([^/@:]+@)?github\.com:)([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)$ ]]; then
    owner="${BASH_REMATCH[5]}"
    name="${BASH_REMATCH[6]}"
    name="${name%.git}"
    if [ -n "$name" ] && [ "$owner" != "." ] && [ "$owner" != ".." ] && [ "$name" != "." ] && [ "$name" != ".." ]; then
      repository="$owner/$name"
    fi
  fi
  shopt -u nocasematch
else
  repository="$UPSTREAM"
  folder="$(basename "$here")"
  if [[ $folder =~ ^usagebar-(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    version="v${folder#usagebar-}"
  fi
fi

echo "version=$version"
echo "repository=$repository"
echo "source=$source"
