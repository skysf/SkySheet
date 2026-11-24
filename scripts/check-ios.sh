#!/usr/bin/env bash
# iPhone 和 iPad 使用同一目标。编一次模拟器包，在同一台 CI 机器上依次运行两种尺寸的真界面测试。
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/skyfolio-mobile.XXXXXX")"
results="${SKYFOLIO_RESULTS:-$work/results}"
mkdir -p "$results"
settings=(-project Mobile/SkyFolio.xcodeproj -scheme SkyFolio -configuration Debug -derivedDataPath "$work/build" -jobs 4)
xcodebuild "${settings[@]}" -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild "${settings[@]}" -destination 'generic/platform=iOS Simulator' build-for-testing
app="$work/build/Build/Products/Debug-iphonesimulator/SkyFolio.app"
ditto -c -k --keepParent "$app" "$results/SkyFolio-Simulator.zip"

xcrun simctl list devices available --json > "$work/devices.json"
python3 - "$work/devices.json" > "$work/selected" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))["devices"]
runtimes = sorted((key for key in devices if ".iOS-" in key),
                  key=lambda key: tuple(map(int, key.split(".iOS-")[1].split("-"))), reverse=True)
for family in ("iPhone", "iPad"):
    device = next((d for runtime in runtimes for d in devices[runtime]
                   if d["name"].startswith(family) and d["isAvailable"]), None)
    if not device:
        sys.exit(f"No available {family} simulator")
    print(family, device["udid"])
    print(f"{family}: {device['name']}", file=sys.stderr)
PY

while read -r family device; do
  xcrun simctl bootstatus "$device" -b
  xcrun simctl install "$device" "$app"
  container="$(xcrun simctl get_app_container "$device" ai.skylu.skyfolio data)"
  mkdir -p "$container/Documents"
  cp Fixtures/IronCalc/arithmetic.xlsx "$container/Documents/Arithmetic.xlsx"
  xcodebuild "${settings[@]}" -destination "id=$device" -parallel-testing-enabled NO \
    -resultBundlePath "$work/$family.xcresult" test-without-building || {
    xcrun xcresulttool export attachments --path "$work/$family.xcresult" --output-path "$results/$family" || true
    exit 1
  }
  xcrun xcresulttool export attachments --path "$work/$family.xcresult" --output-path "$results/$family"
  xcrun simctl shutdown "$device"
done < "$work/selected"
