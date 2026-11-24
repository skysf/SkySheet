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
for family, candidates in (("iPhone", reversed(runtimes)), ("iPad", runtimes)):
    match = next(((runtime, d) for runtime in candidates for d in devices[runtime]
                  if d["name"].startswith(family) and d["isAvailable"]), None)
    if not match:
        sys.exit(f"No available {family} simulator")
    runtime, device = match
    print(family, device["deviceTypeIdentifier"], runtime)
    print(f"{family}: {device['name']} ({runtime})", file=sys.stderr)
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
  xcrun simctl install "$device" "$app"
  container="$(xcrun simctl get_app_container "$device" ai.skylu.skyfolio data)"
  # 在系统 Files 自己的「我的 iPhone / iPad」放样本，和 SkyFolio 的 Documents 分开。
  xcrun simctl launch "$device" com.apple.DocumentsApp
  # 这个共享目录在部分 runtime 属于提供方扩展，Files 主应用的 get_app_container 查不到。
  source_container="$(python3 - "$container" <<'PY'
from pathlib import Path
import plistlib, sys, time

groups = Path(sys.argv[1]).parents[2] / "Shared/AppGroup"
providers = set()
for _ in range(30):
    for metadata in groups.glob("*/.com.apple.mobile_container_manager.metadata.plist"):
        identifier = plistlib.loads(metadata.read_bytes()).get("MCMMetadataIdentifier", "")
        if "fileprovider" in identifier.lower():
            providers.add(identifier)
        if "fileprovider.localstorage" in identifier.lower():
            print(metadata.parent)
            sys.exit(0)
    time.sleep(1)
sys.exit(f"Local File Provider group unavailable. Found {sorted(providers)}")
PY
)"
  provider_file="$source_container/File Provider Storage/From Files.csv"
  mkdir -p "$(dirname "$provider_file")"
  printf '31,93\n' > "$provider_file"
  mkdir -p "$container/Documents"
  cp Fixtures/IronCalc/arithmetic.xlsx "$container/Documents/Arithmetic.xlsx"
  if ! xcodebuild "${settings[@]}" -destination "id=$device" -parallel-testing-enabled NO \
    -collect-test-diagnostics never -resultBundlePath "$work/$family.xcresult" test-without-building; then
    failed=1
    container="$(xcrun simctl get_app_container "$device" ai.skylu.skyfolio data)"
    python3 - "$container" <<'PY'
import json, pathlib, sys
history = pathlib.Path(sys.argv[1]) / "Library/Application Support/ai.skylu.skyfolio/History"
for version in sorted(history.glob("*/*.json")):
    print("Simulator history", version.parent.name, json.loads(version.read_bytes())["title"])
PY
    xcrun simctl spawn "$device" log show --last 12m --info --style compact \
      --predicate '(subsystem BEGINSWITH "com.apple.FileProvider" OR subsystem BEGINSWITH "com.apple.DocumentManager") AND (messageType == error OR eventMessage CONTAINS[c] "pick" OR eventMessage CONTAINS[c] "materializ")' \
      > "$results/$family-files.log" || true
  else
    python3 - "$provider_file" <<'PY'
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
