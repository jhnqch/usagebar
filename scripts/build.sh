#!/bin/bash
# Builds UsageBar (release) and packages an ad-hoc-signed app bundle at
# ~/Applications/UsageBar.app. Set USAGEBAR_APP to package somewhere else.
# Needs only the Command Line Tools, not Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${USAGEBAR_APP:-$HOME/Applications/UsageBar.app}"

swift build -c release --product UsageBar
BIN_DIR="$(swift build -c release --show-bin-path)"

STAGE=".build/package/UsageBar.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN_DIR/UsageBar" "$STAGE/Contents/MacOS/UsageBar"
cp Packaging/Info.plist "$STAGE/Contents/Info.plist"
# Sample readings shown until live sources replace them.
cp Fixtures/sample.json "$STAGE/Contents/Resources/sample.json"

codesign --force --sign - "$STAGE"
codesign --verify --strict "$STAGE"

mkdir -p "$(dirname "$APP")"
rm -rf "$APP"
mv "$STAGE" "$APP"
echo "Built $APP"
