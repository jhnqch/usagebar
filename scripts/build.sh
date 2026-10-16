#!/bin/bash
# Builds UsageBar (release) and packages an ad-hoc-signed app bundle at
# ~/Applications/UsageBar.app. Set USAGEBAR_APP to package somewhere else.
# Needs only the Command Line Tools, not Xcode.
#
# The bundle also carries Claude Code's status line command at
# Contents/Helpers/usagebar-statusline: a stable absolute path for Claude
# Code's `statusLine` setting (`usagebar-statusline install` points it there).
#
# Info.plist also records where the app came from (scripts/build-info.sh):
# the source checkout's path, origin's GitHub owner/name and the
# `git describe --tags` version. The app checks that repo's latest release
# and updates itself from that checkout. The installed app is replaced only
# once everything has built and been signed.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${USAGEBAR_APP:-$HOME/Applications/UsageBar.app}"

swift build -c release --product UsageBar
swift build -c release --product usagebar-statusline
BIN_DIR="$(swift build -c release --show-bin-path)"

STAGE=".build/package/UsageBar.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Helpers" "$STAGE/Contents/Resources"
cp "$BIN_DIR/UsageBar" "$STAGE/Contents/MacOS/UsageBar"
cp "$BIN_DIR/usagebar-statusline" "$STAGE/Contents/Helpers/usagebar-statusline"
cp Packaging/Info.plist "$STAGE/Contents/Info.plist"

# Where this build came from, for updates.
version="" repository="" source=""
while IFS='=' read -r key value; do
  case "$key" in
    version) version="$value" ;;
    repository) repository="$value" ;;
    source) source="$value" ;;
  esac
done < <(scripts/build-info.sh)
PLIST="$STAGE/Contents/Info.plist"
plutil -replace UsageBarVersion -string "$version" "$PLIST"
plutil -replace UsageBarRepository -string "$repository" "$PLIST"
plutil -replace UsageBarSourcePath -string "$source" "$PLIST"
if [[ $version =~ ^v([0-9]+\.[0-9]+\.[0-9]+) ]]; then
  plutil -replace CFBundleShortVersionString -string "${BASH_REMATCH[1]}" "$PLIST"
fi
echo "Version ${version:-unknown}, repository ${repository:-none}, source ${source:-none}"

# Nested code first, then the bundle that seals it.
codesign --force --sign - "$STAGE/Contents/Helpers/usagebar-statusline"
codesign --force --sign - "$STAGE"
codesign --verify --strict "$STAGE"

mkdir -p "$(dirname "$APP")"
rm -rf "$APP"
mv "$STAGE" "$APP"
echo "Built $APP"
