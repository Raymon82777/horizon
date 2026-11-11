#!/bin/sh
# Builds the iOS app (the Rust game library and the SwiftUI launcher) and installs it on an iPhone
# or iPad, by cable or Wi-Fi.
#
# Usage: ios/install.sh [--launch] [--debug] [--device UDID|NAME]
#   --launch   open the app on the device once it's installed
#   --debug    a Debug build (slow game; Release is the default)
#   --device   which device (default: $HORIZON_IOS_DEVICE, else the first reachable iPhone, else iPad)
#
# Needs Xcode, xcodegen, rustup with the aarch64-apple-ios target, and the device paired with this
# Mac (Xcode → Window → Devices and Simulators; tick "Connect via network" there for Wi-Fi installs).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
app_dir="$here/App"
export PATH="/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:$HOME/.cargo/bin:$PATH"

launch=0
configuration=Release
device=${HORIZON_IOS_DEVICE:-}
while [ $# -gt 0 ]; do
    case "$1" in
        --launch) launch=1 ;;
        --debug) configuration=Debug ;;
        --device) device=$2; shift ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

for tool in xcodegen xcodebuild cargo; do
    command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 1; }
done
rustup target list --installed 2>/dev/null | grep -q aarch64-apple-ios ||
    rustup target add aarch64-apple-ios

# The device: the one asked for, else the first paired iPhone or iPad that's reachable.
list=$(mktemp)
trap 'rm -f "$list"' EXIT
xcrun devicectl list devices --quiet --json-output "$list" >/dev/null 2>&1 || true
pick=$(python3 - "$list" "$device" <<'EOF'
import json, sys
path, wanted = sys.argv[1], sys.argv[2]
try:
    devices = json.load(open(path))["result"]["devices"]
except Exception:
    devices = []
def fields(d):
    hw, props, conn = d.get("hardwareProperties", {}), d.get("deviceProperties", {}), d.get("connectionProperties", {})
    return (hw.get("udid", ""), props.get("name", ""), hw.get("deviceType", ""),
            conn.get("tunnelState", ""), hw.get("reality", ""))
rows = [fields(d) for d in devices]
for udid, name, kind, tunnel, reality in rows:
    if wanted and wanted in (udid, name):
        print(f"{udid}\t{name}\t{tunnel}")
        break
else:
    if not wanted:
        # An iPhone before an iPad.
        for wanted_kind in ("iPhone", "iPad"):
            found = [r for r in rows if r[4] == "physical" and r[2] == wanted_kind and r[3] != "unavailable"]
            if found:
                udid, name, kind, tunnel, reality = found[0]
                print(f"{udid}\t{name}\t{tunnel}")
                break
EOF
)
if [ -z "$pick" ]; then
    echo "No reachable iPhone or iPad${device:+ called $device}." >&2
    echo "Plug it in (or turn on Connect via network in Xcode's Devices window), unlock it, and try again." >&2
    exit 1
fi
udid=$(printf '%s' "$pick" | cut -f1)
name=$(printf '%s' "$pick" | cut -f2)
echo "==> Device: $name ($udid)"

echo "==> Building ($configuration): the game library, then the app"
cd "$app_dir"
xcodegen --quiet
log="$app_dir/build.log"
started=$(date +%s)
if ! xcodebuild -project Horizon.xcodeproj -scheme Horizon -configuration "$configuration" \
    -destination "id=$udid" -allowProvisioningUpdates -derivedDataPath build build >"$log" 2>&1; then
    grep -E 'error:|warning: .*(provision|sign)' "$log" | sort -u | head -20 >&2
    echo "Build failed; the whole log is in $log" >&2
    exit 1
fi
echo "    built in $(( $(date +%s) - started ))s"

app="$app_dir/build/Build/Products/$configuration-iphoneos/Horizon.app"
echo "==> Installing on $name"
attempt=1
until xcrun devicectl device install app --device "$udid" "$app" >"$log.install" 2>&1; do
    if [ $attempt -ge 3 ]; then
        grep -E 'ERROR|error' "$log.install" | head -5 >&2
        echo "Install failed. Is the device unlocked?" >&2
        exit 1
    fi
    echo "    the device didn't answer; retrying (unlock it if it's locked)"
    attempt=$((attempt + 1))
    sleep 5
done

if [ $launch -eq 1 ]; then
    echo "==> Opening Horizon"
    # A locked device keeps the launch waiting: give it 20 seconds.
    xcrun devicectl device process launch --device "$udid" com.raymcdonald.horizon >/dev/null 2>&1 &
    pid=$!
    waited=0
    while kill -0 "$pid" 2>/dev/null && [ $waited -lt 20 ]; do sleep 1; waited=$((waited + 1)); done
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        echo "    couldn't open it (locked?): tap Horizon on the device" >&2
    elif ! wait "$pid"; then
        echo "    couldn't open it: tap Horizon on the device" >&2
    fi
fi
echo "==> Done: Horizon $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist") is on $name"
