#!/bin/sh
# Builds horizon-client for iPhone.
# - The deployment target must be set for rustc and cc alike, or rustc links for iOS 10.0 against
#   C objects built for the SDK's version (___chkstk_darwin).
# - iOS gives the main thread 1 MiB of stack (macOS 8 MiB); winit runs the game on it, and the
#   renderer's start overflows that. -stack_size (LC_MAIN) raises it, on the final link only.
set -eu
export IPHONEOS_DEPLOYMENT_TARGET=17.0
exec cargo rustc --target aarch64-apple-ios -p horizon-client --bin horizon-client --profile "${1:-release}" \
    -- -C link-arg=-Wl,-stack_size,0x4000000
