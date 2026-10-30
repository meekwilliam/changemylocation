#!/bin/zsh
# Builds imsomeeked.app next to this script. With --zip, also packs it as imsomeeked.zip for a release.
set -e
cd "$(dirname "$0")"
swift build -c release
APP="imsomeeked.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/imsomeeked "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "Built $APP"
if [ "$1" = "--zip" ]; then
  rm -f imsomeeked.zip
  # Leave out extended attributes and resource forks: other unzip tools turn them into ._ files inside the
  # bundle, which breaks its signature.
  ditto -c -k --norsrc --noextattr --keepParent "$APP" imsomeeked.zip
  echo "Packed imsomeeked.zip"
fi
