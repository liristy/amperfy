#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo "This build requires macOS and Xcode 26. Use the Build iPhone IPA GitHub workflow on Windows." >&2
  exit 1
fi

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="$project_root/build/sideload"
mkdir -p "$output_dir"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/amperfy-sideload.XXXXXX")"
archive_path="$work_dir/Amperfy.xcarchive"

xcodebuild -version
echo "Build workspace: $work_dir"

# Disable signing for both the app and its embedded frameworks. In particular,
# do not embed the production Siri/CarPlay entitlements in a personal test IPA.
xcodebuild archive \
  -project "$project_root/Amperfy.xcodeproj" \
  -scheme Amperfy \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive_path" \
  -derivedDataPath "$work_dir/DerivedData" \
  -clonedSourcePackagesDirPath "$work_dir/SourcePackages" \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  CODE_SIGN_ENTITLEMENTS= \
  DEVELOPMENT_TEAM= \
  2>&1 | tee "$output_dir/build.log"

app_path="$archive_path/Products/Applications/Amperfy.app"
if [[ ! -f "$app_path/Amperfy" || ! -f "$app_path/Frameworks/AmperfyKit.framework/AmperfyKit" ]]; then
  echo "Archive is missing the app executable or its embedded AmperfyKit framework." >&2
  exit 1
fi
xcrun lipo "$app_path/Amperfy" -verify_arch arm64

mkdir -p "$work_dir/package/Payload"
ditto "$app_path" "$work_dir/package/Payload/Amperfy.app"

# Keep the personal test build separate from the App Store app and its data.
# Only modify the copied, unsigned payload; leave the source project untouched.
python3 - "$work_dir/package/Payload/Amperfy.app/Info.plist" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open("rb") as handle:
    info = plistlib.load(handle)
assert info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"], "Not a device build"
info["CFBundleIdentifier"] += ".sideload"
info["CFBundleDisplayName"] = "qMusic"
with path.open("wb") as handle:
    plistlib.dump(info, handle, fmt=plistlib.FMT_BINARY)
PY

# Give Windows re-signers an existing, Apple-generated signature layout instead
# of asking them to insert LC_CODE_SIGNATURE into every unsigned framework.
# This is certificate-free ad-hoc signing, not device installation authorization.
# Sign inside-out, then verify every framework explicitly (iOS bundle layout).
payload_app="$work_dir/package/Payload/Amperfy.app"
while IFS= read -r -d '' library; do
  codesign --force --sign - --timestamp=none "$library"
  codesign --verify --strict --verbose=2 "$library"
done < <(find "$payload_app/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0)
codesign --force --sign - --timestamp=none "$payload_app"
codesign --verify --deep --strict --verbose=2 "$payload_app"

ditto -c -k --keepParent "$work_dir/package/Payload" "$work_dir/Amperfy-unsigned.ipa"
unzip -tq "$work_dir/Amperfy-unsigned.ipa"
python3 "$project_root/BuildTools/verify_ipa.py" --require-signature "$work_dir/Amperfy-unsigned.ipa" \
  | tee "$output_dir/ipa-integrity.log"
cp "$work_dir/Amperfy-unsigned.ipa" "$output_dir/Amperfy-unsigned.ipa"
(
  cd "$output_dir"
  shasum -a 256 Amperfy-unsigned.ipa > SHA256SUMS
)
{
  echo "Source commit: $(git -C "$project_root" rev-parse HEAD)"
  echo "Built at (UTC): $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  xcodebuild -version
  echo "Device: iPhone / iPad, iOS 26 or newer, arm64"
  echo "Bundle ID: de.familie-zimba.amperfy-music.sideload"
  echo "Signing: Apple ad-hoc signature layout; personal signing still required before installing"
  echo "Siri / CarPlay entitlements: excluded"
} > "$output_dir/build-info.txt"

echo "IPA ready for personal signing: $output_dir/Amperfy-unsigned.ipa"
