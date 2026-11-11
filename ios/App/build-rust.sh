#!/bin/sh
# Xcode's pre-build step: the launcher's helpers (libhorizon_ios_tools.a, linked into the app) and
# the game without native mods (HorizonGame.framework, loaded at Play) for the device.
# Instances with native mods get frameworks of their own from ios/native-build.sh; every
# framework in ios/build/frameworks/ goes into the app.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
export IPHONEOS_DEPLOYMENT_TARGET=17.0
# Xcode's environment points the C compiler at its own SDK settings; cargo/cc pick their own.
unset SDKROOT
cargo build --release -p horizon-ios-tools -p horizon-ios --target aarch64-apple-ios

"$root/ios/package-game.sh" "$root/target/aarch64-apple-ios/release/libhorizon_ios.dylib" HorizonGame
