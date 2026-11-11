#!/bin/sh
# Builds the iOS app (the Rust game library and the SwiftUI launcher) and installs it on an iPhone
# or iPad, by cable or Wi-Fi.
#
# Usage: ios/install.sh [--launch] [--debug] [--device UDID|NAME] [--native [--trust-native-code]]
#   --launch   open the app on the device once it's installed
#   --debug    a Debug build (slow game; Release is the default)
#   --device   which device (default: $HORIZON_IOS_DEVICE, else the first reachable iPhone, else iPad)
#   --native   build the native mods each instance on the device chose (ios/native-build.py); with
#              no --trust-native-code it only lists them: native mods aren't sandboxed, so building
#              them is your decision
#
# Needs ios/signing.env (ios/README.md, "Set up signing"), Xcode, xcodegen, rustup with the aarch64-apple-ios target, and the device paired with this
# Mac (Xcode → Window → Devices and Simulators; tick "Connect via network" there for Wi-Fi installs).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
app_dir="$here/App"
export PATH="/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:$HOME/.cargo/bin:$PATH"
# Your team and bundle ID (ios/signing.env).
. "$here/signing.sh"

launch=0
native=0
trust=""
configuration=Release
device=${HORIZON_IOS_DEVICE:-}
while [ $# -gt 0 ]; do
    case "$1" in
        --launch) launch=1 ;;
        --debug) configuration=Debug ;;
        --device) device=$2; shift ;;
        --native) native=1 ;;
        --trust-native-code) native=1; trust=--trust-native-code ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
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

if [ $native -eq 1 ]; then
    echo "==> Native mods the instances on $name chose"
    # shellcheck disable=SC2086
    if ! python3 "$here/native-build.py" --device "$udid" $trust; then
        echo "Native mods didn't all build; the app is installed with what did." >&2
    fi
fi

# This Mac's tailnet name, if Tailscale runs here: the app asks build-server.py there for builds
# of its native mods when the phone is away from the Mac.
tailscale=/Applications/Tailscale.app/Contents/MacOS/Tailscale
command -v tailscale >/dev/null 2>&1 && tailscale=$(command -v tailscale)
build_host=$("$tailscale" status --json 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null || true)

echo "==> Building ($configuration): the game library, then the app"
cd "$app_dir"
xcodegen --quiet
log="$app_dir/build.log"
started=$(date +%s)
if ! xcodebuild -project Horizon.xcodeproj -scheme Horizon -configuration "$configuration" \
    -destination "id=$udid" -allowProvisioningUpdates -derivedDataPath build \
    CURRENT_PROJECT_VERSION="$(date +%y%m%d.%H%M)" HORIZON_BUILD_HOST="$build_host" build >"$log" 2>&1; then
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
    xcrun devicectl device process launch --device "$udid" "$HORIZON_IOS_BUNDLE_ID" >/dev/null 2>&1 &
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
