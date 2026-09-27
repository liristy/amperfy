#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p build/validation
device_id=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime, entries in devices.items():
    if "iOS-26" not in runtime:
        continue
    for device in entries:
        if device["name"].startswith("iPhone"):
            print(device["udid"])
            sys.exit(0)
raise SystemExit("No iOS 26 iPhone simulator is installed")
')

# Boot the throwaway simulator while Xcode compiles, instead of starting its
# first boot only after the build has finished.
(xcrun simctl boot "$device_id" || true) &
simulator_boot_pid=$!

test_arguments=(
  test
  -resultBundlePath build/validation/PlaylistTests.xcresult
  -parallel-testing-enabled NO
  -only-testing:AmperfyKitTests/SsPlaylistsParserTest
  -only-testing:AmperfyKitTests/SsPlaylistSongsParserTest
  -only-testing:AmperfyKitTests/PlaylistTest
  -only-testing:AmperfyKitTests/ArtworkTest
  -only-testing:AmperfyKitTests/MusicPlayerTest
  -only-testing:AmperfyKitTests/SsLyricsBySongId2ParserTest
)
# Run the regression suite for every deliverable. A preceding library-changing
# push may have been cancelled by workflow concurrency before its tests ran.

xcodebuild "${test_arguments[@]}" \
  -project Amperfy.xcodeproj \
  -scheme Amperfy \
  -destination "platform=iOS Simulator,id=$device_id" \
  -derivedDataPath build/validation/DerivedData \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee build/validation/test.log

app_path="build/validation/DerivedData/Build/Products/Debug-iphonesimulator/Amperfy.app"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app_path/Info.plist")
wait "$simulator_boot_pid"
xcrun simctl bootstatus "$device_id" -b
bash BuildTools/smoke-iphone-login.sh "$device_id" "$app_path" "$bundle_id"
