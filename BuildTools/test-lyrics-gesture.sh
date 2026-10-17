#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="$PWD/build/lyrics-gesture"
mkdir -p "$output"
device_id=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; print(next(d["udid"] for r,ds in json.load(sys.stdin)["devices"].items() if "iOS-26" in r for d in ds if d["name"].startswith("iPhone")))')
python3 -u BuildTools/subsonic-smoke-server.py > "$output/server.log" 2>&1 &
server_pid=$!
cleanup() {
  kill "$server_pid" 2>/dev/null || true
  xcrun simctl terminate "$device_id" de.familie-zimba.amperfy-music 2>/dev/null || true
}
trap cleanup EXIT
xcrun simctl boot "$device_id" 2>/dev/null || true
xcodebuild build -project Amperfy.xcodeproj -scheme Amperfy -configuration Debug \
  -destination "platform=iOS Simulator,id=$device_id" -derivedDataPath "$output/DerivedData" \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG LYRICS_GESTURE_CHECK' \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee "$output/build.log"
xcrun simctl bootstatus "$device_id" -b
xcrun simctl install "$device_id" "$output/DerivedData/Build/Products/Debug-iphonesimulator/Amperfy.app"
xcodebuild test -project BuildTools/PlayerTouchTests.xcodeproj -scheme PlayerTouchTests \
  -only-testing:PlayerTouchTests/PlayerTouchTests/testLyricsArtworkRegionHorizontalDrags \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 180 \
  -destination "platform=iOS Simulator,id=$device_id" -derivedDataPath "$output/TouchDerivedData" \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee "$output/touch.log"
