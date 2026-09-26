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

xcodebuild test \
  -project Amperfy.xcodeproj \
  -scheme Amperfy \
  -destination "platform=iOS Simulator,id=$device_id" \
  -derivedDataPath build/validation/DerivedData \
  -resultBundlePath build/validation/PlaylistTests.xcresult \
  -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO \
  -only-testing:AmperfyKitTests/SsPlaylistsParserTest \
  -only-testing:AmperfyKitTests/SsPlaylistSongsParserTest \
  -only-testing:AmperfyKitTests/PlaylistTest \
  -only-testing:AmperfyKitTests/ArtworkTest \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee build/validation/test.log

app_path="build/validation/DerivedData/Build/Products/Debug-iphonesimulator/Amperfy.app"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app_path/Info.plist")
xcrun simctl boot "$device_id" || true
xcrun simctl bootstatus "$device_id" -b
xcrun simctl install "$device_id" "$app_path"
for language in zh-Hans en; do
  xcrun simctl terminate "$device_id" "$bundle_id" || true
  xcrun simctl launch "$device_id" "$bundle_id" -AppleLanguages "($language)"
  sleep 5
  xcrun simctl io "$device_id" screenshot "build/validation/login-$language.png"
done
