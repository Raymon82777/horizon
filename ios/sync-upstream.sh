#!/bin/sh
# Brings the newest upstream Horizon into ios-main: fetch, merge (never rebase), check that the
# iOS layer still builds. Pushing stays a separate, deliberate step.
# Usage: ios/sync-upstream.sh [--no-check]
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"

git remote get-url upstream >/dev/null 2>&1 ||
    git remote add upstream https://github.com/horizon-rust/horizon.git
[ "$(git branch --show-current)" = ios-main ] || { echo "switch to ios-main first" >&2; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "commit or set aside local changes first" >&2; exit 1; }

git fetch upstream main
behind=$(git rev-list --count HEAD..upstream/main)
echo "upstream/main is $behind commits ahead of ios-main"
[ "$behind" -gt 0 ] || exit 0

if ! git merge --no-edit upstream/main; then
    echo
    echo "Merge conflicts. The iOS layer only touches upstream files at lines marked 'ios:' or"
    echo "inside cfg(target_os = \"ios\") / cfg(target_vendor = \"apple\") blocks; keep upstream's"
    echo "side and re-apply those. Files:"
    git diff --name-only --diff-filter=U
    exit 1
fi

[ "${1:-}" = --no-check ] && exit 0
IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo check -p horizon-ios --target aarch64-apple-ios
cargo test -q -p horizon-facts
echo "Merged and checked. Rebuild the app (ios/App) and push ios-main when ready."
