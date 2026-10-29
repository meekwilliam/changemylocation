#!/bin/zsh
# Builds imsomeeked.app next to this script.
set -e
cd "$(dirname "$0")"
swift build -c release
APP="imsomeeked.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/LocationSetter "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "Built $APP"
