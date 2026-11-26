#!/usr/bin/env bash
# iPhone 和 iPad 使用同一目标，模拟器包只编一次。可以按设备和系统版本独立复查。
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
requested = sys.argv[2]
if requested:
    runtime = "com.apple.CoreSimulator.SimRuntime.iOS-" + requested.replace(".", "-")
    if runtime not in runtimes:
        sys.exit(f"Requested simulator runtime unavailable: {requested}")
    runtimes = [runtime]
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
    sys.exit(f"No simulator for {', '.join(families)} in {runtimes}")
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
  # 苹果自己的 Files 先建立副本，选文件那条排在最后，给提供方留出建索引的时间（它偶尔卡死，见下面的判定）。
  # 准备这条不重跑：重跑会再复制出一份。
  if ! xcodebuild "${settings[@]}" -destination "id=$device" -parallel-testing-enabled NO \
    -only-testing:SkyFolioUITests/WorkbookUITests/testPrepareFileUsingSystemProvider \
    -collect-test-diagnostics never -resultBundlePath "$work/$family-prepare.xcresult" test-without-building; then
    failed=1
    xcrun xcresulttool export attachments --path "$work/$family-prepare.xcresult" --output-path "$results/$family-preparation"
  fi
  # 失败的用例在同一台模拟器上再跑一次：Xcode 偶尔拉不起 App（2026-11-25 iPad「Timed out while launching」）。
  # 编辑与重开那条重跑时文件已被上一次改过，输入会接成「77」，必然再失败，真问题不会被洗成通过。
  tests="$work/$family-tests.log"
  if xcodebuild "${settings[@]}" -destination "id=$device" -parallel-testing-enabled NO \
    -skip-testing:SkyFolioUITests/WorkbookUITests/testPrepareFileUsingSystemProvider \
    -retry-tests-on-failure -test-iterations 2 \
    -collect-test-diagnostics never -resultBundlePath "$work/$family.xcresult" test-without-building 2>&1 | tee "$tests"; then
    status=0
  else
    status=1
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
  fi
  # 0：全过，重跑才过的标警告；3：只是模拟器「文件」交不出所选文件，记警告；其余都算失败。
  verdict=0
  python3 - "$family" "$status" "$tests" "$results/$family-files.log" <<'PY' || verdict=$?
import pathlib, re, sys
family, status = sys.argv[1], int(sys.argv[2])
output = pathlib.Path(sys.argv[3]).read_text(errors="replace")
cases = re.findall(r"Test Case '-\[SkyFolioUITests\.WorkbookUITests (\w+)\]' (passed|failed)", output)
failed = {name for name, result in cases if result == "failed"}
passed = {name for name, result in cases if result == "passed"}
for name in sorted(failed & passed):
    print(f"::warning title={family} UI test passed on retry::{name} failed once and passed when run again. The first failure is in the log.")
if status == 0:
    sys.exit(0)
# 模拟器本机「文件」提供方偶尔建索引卡死，被系统杀掉重启后查不到刚登记的文件（FP -1005），
# 选了交不出来，SkyFolio 根本收不到文件。只认这一种：只有选文件那条失败、每次都停在「表格没打开」、
# 系统日志里提供方说所选文件不存在。iPhone 和 iPad 走同一份代码，平时另一台照常验证这条路。
picker = "testSelectExternalWorkbookFromFiles"
messages = [message for name, message in re.findall(r"error: -\[SkyFolioUITests\.WorkbookUITests (\w+)\] : (.*)", output)
            if name == picker]
files = pathlib.Path(sys.argv[4])
system = files.read_text(errors="replace") if files.exists() else ""
lost = re.search(r"(Cannot get URL for item ID|Could not resolve bookmark).*NSFileProviderErrorNonExistentItemIdentifier", system)
if failed - passed == {picker} and messages and lost \
        and all(message.startswith("XCTAssertTrue failed - The workbook did not open") for message in messages):
    print(f"::warning title={family} Files provider lost the picked file::The simulator's Files provider could not hand over "
          f"the picked document (FP -1005), so SkyFolio never received it. Not counted as a failure; see {files.name}.")
    sys.exit(3)
sys.exit(1)
PY
  if [[ $verdict == 0 ]]; then
    python3 - "$provider_file" <<'PY'
import csv, pathlib, sys
seed = pathlib.Path(sys.argv[1])
assert seed.read_bytes() == b"31,93\n", "The seed itself was modified"
copies = [item for item in seed.parent.glob("Picker Seed*.csv") if item != seed]
assert len(copies) == 1, f"Expected one document created by Files, found {copies}"
with copies[0].open(newline="", encoding="utf-8-sig") as file:
    assert list(csv.reader(file)) == [["31", "93"], ["", "47"]], "External provider did not receive the edit"
PY
  elif [[ $verdict != 3 ]]; then
    failed=1
  fi
  xcrun xcresulttool export attachments --path "$work/$family.xcresult" --output-path "$results/$family"
  xcrun simctl shutdown "$device"
  cleanup_device
  device=""
done 3< "$work/selected"
while read -r family hardware runtime; do test -d "$results/$family"; done < "$work/selected"
exit "$failed"
