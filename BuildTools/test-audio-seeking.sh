#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/validation/audio-seek
python3 BuildTools/make-seek-fixtures.py build/validation/audio-seek
export AUDIO_SEEK_FIXTURES="$PWD/build/validation/audio-seek"

# Keep an untouched copy while demonstrating the failure in the pinned upstream
# decoder. Only adapt its method signature to the snapshotted request argument.
processor='vendor/AudioStreaming/AudioStreaming/Streaming/AudioPlayer/Processors/AudioFileStreamProcessor.swift'
cp -p "$processor" build/validation/audio-seek/patched-processor.swift
restore_processor() { cp -p build/validation/audio-seek/patched-processor.swift "$processor"; }
trap restore_processor EXIT
python3 - "$processor" <<'PY'
import hashlib
from pathlib import Path
import sys
import urllib.request
url = 'https://raw.githubusercontent.com/dimitris-c/AudioStreaming/a729ee28fece29d80a749419d96df0693200f124/AudioStreaming/Streaming/AudioPlayer/Processors/AudioFileStreamProcessor.swift'
data = urllib.request.urlopen(url).read()
assert hashlib.sha256(data).hexdigest() == 'cb4bdd4d459f88205b951ca16b23c6eb603d070b21b32df294057dafa8c20a7c'
source = data.decode().replace('func processSeek() {', 'func processSeek(to requestedTime: Double) {')
source = source.replace('readingEntry.seekRequest.time', 'requestedTime')
Path(sys.argv[1]).write_text(source)
PY
if swift test --package-path vendor/AudioStreaming --filter PreciseFlacSeekTests 2>&1 | tee build/validation/audio-seek-baseline.log; then
  echo 'Expected the original proportional seek to fail the decoded-sample comparison.' >&2
  exit 1
fi
if ! grep -q 'Decoded audio is at a different time' build/validation/audio-seek-baseline.log; then
  echo 'Baseline failed before the decoded-sample assertion; this is not a reproduced seek regression.' >&2
  exit 1
fi
# Give SwiftPM a fresh timestamp for the changed decoder, then let the EXIT
# trap restore the original stamp so the subsequent iOS build can reuse it.
cp build/validation/audio-seek/patched-processor.swift "$processor"
swift test --package-path vendor/AudioStreaming --filter PreciseFlacSeekTests 2>&1 | tee build/validation/audio-seek-fixed.log
