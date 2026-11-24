#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
mode=${1:-all}
case "$mode" in
  all|--library-only|--ui-only) ;;
  *) echo "Unknown validation mode: $mode" >&2; exit 2 ;;
esac
mkdir -p build/validation
# Older caches were touched by the project's recursive formatting build phase.
# Restore only dependency checkout files; keep compiled products for reuse.
echo "Checking cached package sources"
for package in build/validation/DerivedData/SourcePackages/checkouts/*; do
  if [[ -d "$package/.git" || -f "$package/.git" ]]; then
    if ! git -C "$package" diff --quiet; then
      git -C "$package" restore --worktree -- .
    fi
  fi
done
echo "Selecting an iPhone simulator (iOS 26 or later)"
device_selection=$(python3 -c '
import json, re, subprocess
devices = json.loads(subprocess.check_output(
    ["xcrun", "simctl", "list", "devices", "available", "-j"], timeout=120,
))["devices"]
candidates = []
for runtime, entries in devices.items():
    match = re.search(r"\.iOS-(\d+)(?:-(.*))?$", runtime)
    if not match or int(match[1]) < 26:
        continue
    major = int(match[1])
    for device in entries:
        if device["name"].startswith("iPhone"):
            candidates.append((major, device["name"] != "iPhone 17 Pro Max", device["udid"]))
if not candidates:
    raise SystemExit("No iPhone simulator with iOS 26 or later is installed")
major, _, device = min(candidates)
print(device, major)
')
read -r device_id runtime_major <<< "$device_selection"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'AMPERFY_VALIDATION_DEVICE=%s\nAMPERFY_VALIDATION_RUNTIME_MAJOR=%s\n' \
    "$device_id" "$runtime_major" >> "$GITHUB_ENV"
fi

# Boot the throwaway simulator while Xcode compiles, instead of starting its
# first boot only after the build has finished.
(xcrun simctl boot "$device_id" || true) &
simulator_boot_pid=$!

test_arguments=(
  test
  -resultBundlePath build/validation/PlaylistTests.xcresult
  -parallel-testing-enabled NO
  -test-timeouts-enabled YES
  -only-testing:AmperfyKitTests/SsPlaylistsParserTest
  -only-testing:AmperfyKitTests/SsPlaylistSongsParserTest
  -only-testing:AmperfyKitTests/PlaylistTest
  -only-testing:AmperfyKitTests/ArtworkTest
  -only-testing:AmperfyKitTests/UtilitiesTest
  -only-testing:AmperfyKitTests/ArtistTest
  -only-testing:AmperfyKitTests/MusicPlayerTest
  -only-testing:AmperfyKitTests/SsLyricsBySongId2ParserTest
  -only-testing:AmperfyKitTests/AlbumTest/testReleaseDateAndYearDisplay
)
# Run the regression suite for every deliverable. A preceding library-changing
# push may have been cancelled by workflow concurrency before its tests ran.
# Report a source location for pathological type inference instead of spending
# the entire simulator job in one expression. This does not affect the IPA build.

if [[ "$mode" != --ui-only ]]; then
xcodebuild "${test_arguments[@]}" \
  -project Amperfy.xcodeproj \
  -scheme Amperfy \
  -destination "platform=iOS Simulator,id=$device_id" \
  -derivedDataPath build/validation/DerivedData \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO \
  'OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -solver-expression-time-threshold=30 -Xfrontend -warn-long-function-bodies=1000 -Xfrontend -warn-long-expression-type-checking=1000' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee build/validation/test.log
fi

app_path="build/validation/DerivedData/Build/Products/Debug-iphonesimulator/Amperfy.app"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app_path/Info.plist")
wait "$simulator_boot_pid"
xcrun simctl bootstatus "$device_id" -b
if [[ "$mode" != --library-only ]]; then
  bash BuildTools/smoke-iphone-login.sh "$device_id" "$app_path" "$bundle_id"
fi
