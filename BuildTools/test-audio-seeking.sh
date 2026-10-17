#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/validation/audio-seek
python3 BuildTools/make-seek-fixtures.py build/validation/audio-seek
export AUDIO_SEEK_FIXTURES="$PWD/build/validation/audio-seek"

# Exercise the shipped decoder directly. The original decoder's failure was
# already established; routine validation must not download or rebuild it.
swift test --package-path vendor/AudioStreaming --filter PreciseFlacSeekTests 2>&1 | tee build/validation/audio-seek-fixed.log
