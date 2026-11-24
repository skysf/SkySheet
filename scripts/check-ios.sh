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
python3 - "$work/devices.json" "${SKYFOLIO_SIM_RUNTIME:-}" "${SKYFOLIO_SIM_FAMILY:-}" > "$work/selected" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))["devices"]
runtimes = sorted((key for key in devices if ".iOS-" in key),
                  key=lambda key: tuple(map(int, key.split(".iOS-")[1].split("-"))), reverse=True)
# 26.5 的模拟器偶发无法解析 Files 自己创建的文稿。两种尺寸用同一稳定 runtime；
# 仍用最新 SDK 编译真机，可指定 SKYFOLIO_SIM_RUNTIME=26.5 在 CI 环境复查系统提供方。
requested = sys.argv[2]
preferred = "com.apple.CoreSimulator.SimRuntime.iOS-" + (requested or "26.2").replace(".", "-")
if requested and preferred not in runtimes:
    sys.exit(f"Requested simulator runtime unavailable: {requested}")
if preferred in runtimes:
    runtimes = [preferred] if requested else [preferred] + [other for other in runtimes if other != preferred]
families = (sys.argv[3],) if sys.argv[3] else ("iPhone", "iPad")
if not set(families) <= {"iPhone", "iPad"}:
    sys.exit(f"Unknown device families: {families}")
for runtime in runtimes:
    selected = [next((d for d in devices[runtime] if d["name"].startswith(family) and d["isAvailable"]), None)
                for family in families]
    if all(selected):
        for family, device in zip(families, selected):
            print(family, device["deviceTypeIdentifier"], runtime)
            print(f"{family}: {device['name']} ({runtime})", file=sys.stderr)
        break
else:
    sys.exit("No runtime with both an iPhone and an iPad simulator")
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
  provider_file="$source_container/File Provider Storage/Picker Seed.csv"
  mkdir -p "$(dirname "$provider_file")"
  printf '31,93\n' > "$provider_file"
  mkdir -p "$container/Documents"
  cp Fixtures/IronCalc/arithmetic.xlsx "$container/Documents/Arithmetic.xlsx"
  if ! xcodebuild "${settings[@]}" -destination "id=$device" -parallel-testing-enabled NO \
    -only-testing:SkyFolioUITests/WorkbookUITests/testSelectExternalWorkbookFromFiles \
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
import csv, pathlib, sys
with pathlib.Path(sys.argv[1]).open(newline="", encoding="utf-8-sig") as file:
    assert list(csv.reader(file)) == [["31", "93"], ["", "47"]], "External provider did not receive the edit"
PY
  fi
  xcrun xcresulttool export attachments --path "$work/$family.xcresult" --output-path "$results/$family"
  xcrun simctl shutdown "$device"
  cleanup_device
  device=""
done 3< "$work/selected"
while read -r family hardware runtime; do test -d "$results/$family"; done < "$work/selected"
exit "$failed"
