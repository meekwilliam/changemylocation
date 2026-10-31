#!/bin/zsh
# Builds changemylocation.app next to this script, for Apple Silicon and Intel. With --zip, also packs it as
# changemylocation.zip for a release. Needs Swift (Xcode or the Command Line Tools) and Rust (rustup).
set -e
cd "$(dirname "$0")"
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
# Keep this machine's folder names (the username, the checkout) out of the engine binary.
export RUSTFLAGS="--remap-path-prefix=$HOME/.cargo/registry/src=crates --remap-path-prefix=$HOME/.cargo/git/checkouts=git --remap-path-prefix=$HOME/.rustup=rustup --remap-path-prefix=$PWD=changemylocation"

# The engine (core/) that talks to the iPhone, as one binary for both chip types.
for target in aarch64-apple-darwin x86_64-apple-darwin; do
  "$CARGO" build --release --manifest-path core/Cargo.toml --target $target
done
mkdir -p .build/engine
lipo -create -output .build/engine/changemylocation-cli \
  core/target/aarch64-apple-darwin/release/changemylocation-cli \
  core/target/x86_64-apple-darwin/release/changemylocation-cli

SWIFT_ARGS=(-c release --arch arm64 --arch x86_64)
swift build $SWIFT_ARGS
BIN="$(swift build $SWIFT_ARGS --show-bin-path)"
APP="changemylocation.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp icon/AppIcon.icns "$APP/Contents/Resources/"
cp "$BIN/changemylocation" "$APP/Contents/MacOS/"
cp .build/engine/changemylocation-cli "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
# Drop debug symbols, which record the folders the app was built in.
strip -x "$APP/Contents/MacOS/changemylocation" "$APP/Contents/MacOS/changemylocation-cli"
codesign --force --sign - "$APP/Contents/MacOS/changemylocation-cli"
codesign --force --sign - "$APP"
echo "Built $APP"
if [ "$1" = "--zip" ]; then
  rm -f changemylocation.zip
  # Leave out extended attributes and resource forks: other unzip tools turn them into ._ files inside the
  # bundle, which breaks its signature.
  ditto -c -k --norsrc --noextattr --keepParent "$APP" changemylocation.zip
  echo "Packed changemylocation.zip"
fi
