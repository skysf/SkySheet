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

# Apple 的本机 Files 提供方通过另一个应用的 Documents 授权；用一个只发布合成 CSV 的模拟器夹具。
source_app="$work/Picker Samples.app"
mkdir -p "$source_app"
cp Mobile/UITests/FileSource/Info.plist "$source_app/Info.plist"
xcrun --sdk iphonesimulator swiftc -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -target arm64-apple-ios18.0-simulator -module-name SkyFolioTestSource \
  Mobile/UITests/FileSource/main.swift -o "$source_app/FileSource"

xcrun simctl list devices available --json > "$work/devices.json"
python3 - "$work/devices.json" > "$work/selected" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))["devices"]
runtimes = sorted((key for key in devices if ".iOS-" in key),
                  key=lambda key: tuple(map(int, key.split(".iOS-")[1].split("-"))), reverse=True)
for family in ("iPhone", "iPad"):
    match = next(((runtime, d) for runtime in runtimes for d in devices[runtime]
                  if d["name"].startswith(family) and d["isAvailable"]), None)
    if not match:
        sys.exit(f"No available {family} simulator")
    runtime, device = match
    print(family, device["deviceTypeIdentifier"], runtime)
    print(f"{family}: {device['name']}", file=sys.stderr)
PY

device=""
cleanup_device() {
  if [[ -n "$device" ]]; then xcrun simctl delete "$device"; fi
}
trap cleanup_device EXIT
failed=0
while read -r family hardware runtime <&3; do
  device="$(xcrun simctl create "SkyFolio checks $family" "$hardware" "$runtime")"
  xcrun simctl bootstatus "$device" -b
  source_id=ai.skylu.skyfolio.tests.filesource
  xcrun simctl install "$device" "$source_app"
  xcrun simctl launch "$device" "$source_id"
  source_container="$(xcrun simctl get_app_container "$device" "$source_id" data)"
  for attempt in {1..30}; do
    [[ -f "$source_container/Documents/From Files.csv" ]] && break
    sleep 1
  done
  test -f "$source_container/Documents/From Files.csv"
  xcrun simctl install "$device" "$app"
  container="$(xcrun simctl get_app_container "$device" ai.skylu.skyfolio data)"
  mkdir -p "$container/Documents"
  cp Fixtures/IronCalc/arithmetic.xlsx "$container/Documents/Arithmetic.xlsx"
  if ! xcodebuild "${settings[@]}" -destination "id=$device" -parallel-testing-enabled NO \
    -resultBundlePath "$work/$family.xcresult" test-without-building; then
    failed=1
    container="$(xcrun simctl get_app_container "$device" ai.skylu.skyfolio data)"
    python3 - "$container" <<'PY'
import json, pathlib, sys
history = pathlib.Path(sys.argv[1]) / "Library/Application Support/ai.skylu.skyfolio/History"
for version in sorted(history.glob("*/*.json")):
    print("Simulator history", version.parent.name, json.loads(version.read_bytes())["title"])
PY
    xcrun simctl spawn "$device" log show --last 12m --info --style compact \
      --predicate '(process CONTAINS[c] "DocumentManager" OR process == "fileproviderd" OR process == "SkyFolio") AND (messageType == error OR eventMessage CONTAINS[c] "pick" OR eventMessage CONTAINS[c] "materializ")' \
      > "$results/$family-files.log" || true
  else
    python3 - "$source_container/Documents/From Files.csv" <<'PY'
import csv, sys
with open(sys.argv[1], newline="", encoding="utf-8-sig") as file:
    assert list(csv.reader(file)) == [["31", "93"], ["", "47"]], "External provider did not receive the edit"
PY
  fi
  xcrun xcresulttool export attachments --path "$work/$family.xcresult" --output-path "$results/$family"
  xcrun simctl shutdown "$device"
  cleanup_device
  device=""
done 3< "$work/selected"
test -d "$results/iPhone"
test -d "$results/iPad"
exit "$failed"
