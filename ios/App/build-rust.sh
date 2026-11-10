#!/bin/sh
# Xcode's pre-build step: builds libhorizon_ios.a (the game) for the device.
set -eu
cd "$(dirname "$0")/../.."
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
export IPHONEOS_DEPLOYMENT_TARGET=17.0
# Xcode's environment points the C compiler at its own SDK settings; cargo/cc pick their own.
unset SDKROOT
cargo build --release -p horizon-ios --target aarch64-apple-ios
