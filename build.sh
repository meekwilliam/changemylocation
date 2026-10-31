#!/bin/zsh
# Builds imsomeeked.app next to this script, for Apple Silicon and Intel. With --zip, also packs it as
# imsomeeked.zip for a release. Needs Swift (Xcode or the Command Line Tools) and Rust (rustup).
set -e
cd "$(dirname "$0")"
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"

# The engine (core/) that talks to the iPhone, as one binary for both chip types.
for target in aarch64-apple-darwin x86_64-apple-darwin; do
  "$CARGO" build --release --manifest-path core/Cargo.toml --target $target
done
mkdir -p .build/engine
lipo -create -output .build/engine/imsomeeked-cli \
  core/target/aarch64-apple-darwin/release/imsomeeked-cli \
  core/target/x86_64-apple-darwin/release/imsomeeked-cli

SWIFT_ARGS=(-c release --arch arm64 --arch x86_64)
swift build $SWIFT_ARGS
BIN="$(swift build $SWIFT_ARGS --show-bin-path)"
APP="imsomeeked.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/imsomeeked" "$APP/Contents/MacOS/"
cp .build/engine/imsomeeked-cli "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP/Contents/MacOS/imsomeeked-cli"
codesign --force --sign - "$APP"
echo "Built $APP"
if [ "$1" = "--zip" ]; then
  rm -f imsomeeked.zip
  # Leave out extended attributes and resource forks: other unzip tools turn them into ._ files inside the
  # bundle, which breaks its signature.
  ditto -c -k --norsrc --noextattr --keepParent "$APP" imsomeeked.zip
  echo "Packed imsomeeked.zip"
fi
