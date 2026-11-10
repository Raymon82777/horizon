#!/bin/sh
# Wraps the aarch64-apple-ios horizon-client binary in a signed Horizon.app and installs it.
# Usage: ios/package.sh [release|fast] [--install]
# Needs ios/embedded.mobileprovision (from the xcodegen stub in ios/stub, built once with
# -allowProvisioningUpdates) and the Apple Development identity below.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
profile_name=${1:-release}
identity=${HORIZON_IOS_IDENTITY:-9B2F4018D78D2357F4AFC896DD94737B0577C194}
device=${HORIZON_IOS_DEVICE:-00008150-000622400130401C}
bin="$root/target/aarch64-apple-ios/$profile_name/horizon-client"
app="$here/build/Horizon.app"

rm -rf "$app"
mkdir -p "$app"
# iOS 27 kills apps linked against its SDK that don't adopt the UIScene lifecycle
# (_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption), and winit 0.30's UIKit backend
# doesn't. Spike-only stopgap: stamp the binary as built with the iOS 26 SDK. The real fix is
# scene support in winit.
xcrun vtool -set-build-version ios 17.0 26.0 -replace -output "$app/Horizon" "$bin"
cp "$here/Info.plist" "$app/Info.plist"
cp "$here/embedded.mobileprovision" "$app/embedded.mobileprovision"

# The profile's entitlements, as signed into the app (memory limit, extended addressing,
# get-task-allow for the debugger and Instruments).
security cms -D -i "$here/embedded.mobileprovision" > "$here/build/profile.plist"
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$here/build/profile.plist" > "$here/build/entitlements.plist"
codesign --force --sign "$identity" --entitlements "$here/build/entitlements.plist" --timestamp=none "$app"
codesign --verify --verbose=1 "$app"

if [ "${2:-}" = "--install" ]; then
    xcrun devicectl device install app --device "$device" "$app"
fi
