# AudioStreaming local changes

Source: https://github.com/dimitris-c/AudioStreaming
Version: 1.4.4, revision `a729ee28fece29d80a749419d96df0693200f124`.
The upstream MIT license is retained in `LICENSE`. Only the runtime targets are
included; the upstream example app and test target/resources are omitted.

qMusic uses this local Swift package so both simulator and device builds contain
the same decoder fix. Do not replace it with the unmodified remote package.

Changes from upstream:

- FLAC seeking restarts the parser/converter at the file header, then discards
  decoded output frames until the requested sample. Average compressed bitrate
  is not a valid mapping from time to FLAC byte offsets. Skipped samples never
  enter the render ring or advance its playback clock. Other codecs retain their
  existing seek path.
- FLAC seeks can proceed even when Core Audio does not expose a usable bitrate.
- Every seek increments the request version under the request lock. Completing
  an older request cannot clear a newer request, and the decoder checks for
  superseding requests while discarding compressed input.
- `Package.swift` omits upstream tests that are not distributed here.

Tradeoff: FLAC seeks currently decode the prefix again. Local playback adds
decoder work; streaming also reads the prefix again and can take longer on a
slow connection. A future optimization must use verified FLAC sample/frame
positions, never reintroduce bitrate-based byte estimates.

Regression: `MusicPlayerTest.testFLACSeekMatchesActualDecodedSamplesAcrossVariableBitrateSections`
compares the actual renderer PCM against an unseeked decode, including forward,
backward, fractional-second and zero seeks with 1 KiB and 64 KiB input chunks.
The generated fixture contains silence, tones and noise with very different
compressed frame sizes. Run `bash BuildTools/test-iphone-changes.sh` on macOS/Xcode.
