#!/bin/sh
# Generates ios/App/Horizon.xcodeproj with your signing settings (ios/signing.env), for opening it
# in Xcode: ios/generate.sh && open ios/App/Horizon.xcodeproj. The install scripts do this
# themselves. Run it again after changing ios/signing.env or ios/App/project.yml.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
. "$here/signing.sh"
cd "$here/App"
xcodegen --quiet
echo "Generated ios/App/Horizon.xcodeproj (team $HORIZON_IOS_TEAM, $HORIZON_IOS_BUNDLE_ID$([ "$HORIZON_IOS_PAID" = 0 ] && echo ', free account'))"
