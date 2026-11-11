#!/bin/sh
# Installs Horizon on the iPhone from anywhere, over Tailscale: builds the app (as install.sh
# does), packs it as an .ipa signed with the development profile (which lists the phone), and
# serves it with a manifest at https://<this Mac>.<tailnet>.ts.net/horizon/ (tailscale serve,
# tailnet only, never the internet). On the phone, open that address in Safari and tap Install:
# iOS installs it over the air (itms-services), keeping worlds and settings, with the same
# entitlements as a cable install.
#
# Usage: ios/remote-install.sh [--stop]
#   --stop   stop serving (the build stays in ios/build/remote)
# Needs Tailscale running on the Mac and the phone (same tailnet) and HTTPS certificates turned on
# for the tailnet (admin console → DNS → HTTPS Certificates).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
app_dir="$here/App"
out="$here/build/remote"
tailscale=/Applications/Tailscale.app/Contents/MacOS/Tailscale
command -v tailscale >/dev/null 2>&1 && tailscale=$(command -v tailscale)
export PATH="/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:$HOME/.cargo/bin:$PATH"

port=8765
pidfile="$here/build/remote-server.pid"
stop_server() {
    if [ -f "$pidfile" ]; then
        kill "$(cat "$pidfile")" 2>/dev/null || true
        rm -f "$pidfile"
    fi
}

if [ "${1:-}" = --stop ]; then
    "$tailscale" serve --https=443 --set-path /horizon off 2>/dev/null || true
    stop_server
    echo "Stopped serving Horizon."
    exit 0
fi

# This Mac's tailnet name and whether it can have an HTTPS certificate.
status=$("$tailscale" status --json) || { echo "Tailscale isn't running on this Mac." >&2; exit 1; }
host=$(printf '%s' "$status" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')
certs=$(printf '%s' "$status" | python3 -I -c 'import json,sys; print(" ".join(json.load(sys.stdin).get("CertDomains") or []))')
case " $certs " in
    *" $host "*) ;;
    *)
        echo "HTTPS certificates aren't on for this tailnet, and iOS installs apps only over HTTPS." >&2
        echo "Turn them on: https://login.tailscale.com/admin/dns → HTTPS Certificates → Enable, then run this again." >&2
        exit 1 ;;
esac

echo "==> Building the app"
cd "$app_dir"
xcodegen --quiet
log="$app_dir/build.log"
if ! xcodebuild -project Horizon.xcodeproj -scheme Horizon -configuration Release \
    -destination 'generic/platform=iOS' -allowProvisioningUpdates -derivedDataPath build \
    CURRENT_PROJECT_VERSION="$(date +%y%m%d.%H%M)" build >"$log" 2>&1; then
    grep -E 'error:' "$log" | sort -u | head -20 >&2
    echo "Build failed; the whole log is in $log" >&2
    exit 1
fi
app="$app_dir/build/Build/Products/Release-iphoneos/Horizon.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Info.plist")
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")

echo "==> Packing Horizon.ipa"
rm -rf "$out"
mkdir -p "$out/Payload"
cp -R "$app" "$out/Payload/"
stamp=$(date +%s)
(cd "$out" && zip -qry "Horizon-$stamp.ipa" Payload && rm -rf Payload)
base="https://$host/horizon"
cat > "$out/manifest-$stamp.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>items</key>
	<array>
		<dict>
			<key>assets</key>
			<array>
				<dict>
					<key>kind</key>
					<string>software-package</string>
					<key>url</key>
					<string>$base/Horizon-$stamp.ipa</string>
				</dict>
			</array>
			<key>metadata</key>
			<dict>
				<key>bundle-identifier</key>
				<string>$bundle</string>
				<key>bundle-version</key>
				<string>$version</string>
				<key>kind</key>
				<string>software</string>
				<key>title</key>
				<string>Horizon</string>
			</dict>
		</dict>
	</array>
</dict>
</plist>
EOF
# The manifest's address goes in the link percent-encoded; iOS ignores a link it can't parse,
# without a word. A fresh file name per build keeps iOS from reusing an old download.
manifest_url=$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$base/manifest-$stamp.plist")
link="itms-services://?action=download-manifest&amp;url=$manifest_url"
cat > "$out/index.html" <<EOF
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Install Horizon</title>
<style>body{font:17px -apple-system,sans-serif;background:#140f3a;color:#fff;text-align:center;padding:48px 20px}
a{display:inline-block;margin:24px 0;padding:16px 40px;border-radius:14px;background:#f8ae34;color:#140f3a;font-weight:700;text-decoration:none;font-size:20px}
p{color:#c9c3ee}</style></head>
<body><h1>Horizon $version</h1><p>Build $build</p>
<a href="$link">Install</a>
<p>Built $(date '+%b %d, %H:%M'). Worlds and settings are kept.</p>
<p>Tap Install, then <b>Install</b> again in the box iOS shows. Then go to the home screen: Horizon updates there.</p>
</body></html>
EOF

echo "==> Serving on the tailnet"
# The Mac App Store Tailscale can't serve a folder (its sandbox), only forward to a local server:
# a small one on this Mac's loopback only, reachable from the tailnet through tailscale serve.
# horizon -> . : the files answer whether or not the forward keeps the /horizon prefix.
ln -sfn . "$out/horizon"
stop_server
nohup python3 -I -m http.server "$port" --bind 127.0.0.1 --directory "$out" >"$here/build/remote-server.log" 2>&1 &
echo $! > "$pidfile"
sleep 1
"$tailscale" serve --bg --https=443 --set-path /horizon "http://127.0.0.1:$port" >/dev/null
# Tailscale's forward can answer 502 for up to a minute after the server restarts.
tries=0
until [ "$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$base/")" = 200 ] || [ $tries -ge 12 ]; do
    tries=$((tries + 1))
    sleep 5
done
echo
echo "On the iPhone (Tailscale on), open in Safari:"
echo "    $base/"
echo "and tap Install. Stop serving afterwards with: ios/remote-install.sh --stop"
