# Sourced by the ios/ scripts: reads ios/signing.env (see signing.env.example) and exports the
# signing settings XcodeGen and the scripts use. Values already exported in the shell win.
# Callers set $here to the ios/ folder first.
signing_file="$here/signing.env"
if [ -f "$signing_file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        key=${line%%=*}
        value=${line#*=}
        value=${value%%#*}
        value=$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/')
        case "$key" in
            HORIZON_IOS_TEAM|HORIZON_IOS_BUNDLE_ID|HORIZON_IOS_PAID|HORIZON_IOS_DEVICE|HORIZON_IOS_IDENTITY|HORIZON_SOURCE_URL)
                eval "current=\${$key:-}"
                [ -n "$current" ] || eval "$key=\$value" ;;
        esac
    done < "$signing_file"
fi

signing_missing() {
    echo "$1" >&2
    echo "Set up signing first: cp ios/signing.env.example ios/signing.env and fill it in (ios/README.md, \"Set up signing\")." >&2
    exit 1
}
[ -n "${HORIZON_IOS_TEAM:-}" ] || signing_missing "No Apple Team ID (HORIZON_IOS_TEAM)."
[ -n "${HORIZON_IOS_BUNDLE_ID:-}" ] || signing_missing "No bundle ID (HORIZON_IOS_BUNDLE_ID)."
case "$HORIZON_IOS_TEAM" in ABCDE12345) signing_missing "ios/signing.env still has the example Team ID." ;; esac
case "$HORIZON_IOS_BUNDLE_ID" in com.example.*) signing_missing "ios/signing.env still has the example bundle ID." ;; esac
HORIZON_IOS_PAID=${HORIZON_IOS_PAID:-1}

# A free account can't sign the memory entitlements: its builds go without them.
if [ "$HORIZON_IOS_PAID" = 0 ]; then
    HORIZON_IOS_ENTITLEMENTS=../Horizon-free.entitlements
else
    HORIZON_IOS_ENTITLEMENTS=../Horizon.entitlements
fi

# The repository this build came from, for the app's About section (empty: no link): the remote
# the checked-out branch tracks, else origin. HORIZON_SOURCE_URL in signing.env overrides it.
if [ -z "${HORIZON_SOURCE_URL:-}" ]; then
    source_remote=$(git -C "$here" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null | cut -d/ -f1)
    HORIZON_SOURCE_URL=$(git -C "$here" remote get-url "${source_remote:-origin}" 2>/dev/null |
        sed -e 's#^git@github\.com:#https://github.com/#' -e 's#\.git$##' | grep '^https://' || true)
fi

export HORIZON_IOS_TEAM HORIZON_IOS_BUNDLE_ID HORIZON_IOS_PAID HORIZON_IOS_ENTITLEMENTS HORIZON_SOURCE_URL
[ -z "${HORIZON_IOS_DEVICE:-}" ] || export HORIZON_IOS_DEVICE
[ -z "${HORIZON_IOS_IDENTITY:-}" ] || export HORIZON_IOS_IDENTITY
