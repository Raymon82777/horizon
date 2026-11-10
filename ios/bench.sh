#!/bin/sh
# Runs Horizon's own benchmark on the iPhone at a render distance, with Instruments' Activity
# Monitor and Thermal State attached, then copies the report and trace back. On iOS the app stays
# open after the benchmark (winit can't end the process), so this stops it once the report is out.
# Usage: ios/bench.sh RD
set -u
rd=$1
dev=${HORIZON_IOS_DEVICE:-00008150-000622400130401C}
out="$(cd "$(dirname "$0")/.." && pwd)/.mc/dev-out/bench"
mkdir -p "$out"
log="$out/rd$rd.console.log"
xcrun devicectl device process launch --console --terminate-existing --device "$dev" com.raymcdonald.horizon \
    --resources resources --home . --game-dir . --benchmark standard --render-distance "$rd" > "$log" 2>&1 &
launch=$!
pid=""
for _ in $(seq 1 30); do
    sleep 1
    pid=$(xcrun devicectl device info processes --device "$dev" 2>/dev/null | awk '/Horizon.app\/Horizon/ {print $1; exit}')
    [ -n "$pid" ] && break
done
rm -rf "$out/rd$rd.trace"
xcrun xctrace record --device "$dev" --template 'Activity Monitor' --instrument 'Thermal State' \
    --attach "$pid" --time-limit 300s --output "$out/rd$rd.trace" > "$out/rd$rd.xctrace.log" 2>&1 &
trace=$!
until grep -q 'benchmark report' "$log" || ! kill -0 $launch 2>/dev/null; do sleep 2; done
sleep 2
kill -INT $trace 2>/dev/null; wait $trace
kill $launch 2>/dev/null
report=$(grep -o 'Documents/benchmarks/[^ ]*\.json' "$log" | tail -1)
[ -n "$report" ] && xcrun devicectl device copy from --device "$dev" --domain-type appDataContainer \
    --domain-identifier com.raymcdonald.horizon --source "$report" --destination "$out/rd$rd.json" >/dev/null 2>&1
echo "rd$rd done (pid $pid): $(ls "$out" | grep "rd$rd" | tr '\n' ' ')"
