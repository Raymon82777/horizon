#!/bin/sh
# Wraps a built game (libhorizon_ios.dylib) as ios/build/frameworks/NAME.framework, the form the
# app embeds and loads at Play (GameBridge.swift). Usage: ios/package-game.sh DYLIB NAME
set -eu
dylib=$1
name=$2
here=$(cd "$(dirname "$0")" && pwd)
. "$here/signing.sh"
out="$here/build/frameworks/$name.framework"

rm -rf "$out"
mkdir -p "$out"
cp "$dylib" "$out/$name"
# The app finds it in its Frameworks folder (LD_RUNPATH_SEARCH_PATHS @executable_path/Frameworks).
install_name_tool -id "@rpath/$name.framework/$name" "$out/$name"
# Frameworks' bundle identifiers: letters, digits, dots and hyphens only.
id=$(printf '%s' "$name" | tr -c 'A-Za-z0-9.\n-' '-' | tr 'A-Z' 'a-z')
cat > "$out/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>$name</string>
	<key>CFBundleIdentifier</key>
	<string>$HORIZON_IOS_BUNDLE_ID.$id</string>
	<key>CFBundleName</key>
	<string>$name</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>iPhoneOS</string>
	</array>
	<key>MinimumOSVersion</key>
	<string>17.0</string>
</dict>
</plist>
EOF
echo "packaged $out ($(du -sh "$out" | cut -f1))"
