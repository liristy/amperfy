This is AudioStreaming 1.4.4, upstream revision a729ee28fece29d80a749419d96df0693200f124,
vendored under its MIT license so the same seek fix is compiled in local and CI builds.
The public player API and Ogg dependencies are unchanged.

Local changes:
- FLAC seeks start from a verified frame at/before the requested sample. Compressed
  packets before that sample are skipped, and the first decoded buffer is trimmed
  to the exact requested sample. Unindexed forward seeks scan compressed packets
  from the last known anchor; subsequent seeks reuse the in-memory index.
- Frame positions are verified against AudioFileStream packets before being used
  as anchors. The index is discarded when the stream changes.
- Seek requests are snapshotted/versioned so a new request cannot be cleared by an
  older in-flight seek.

FlacFrameHeader.swift is adapted from Minidoracat's MIT-licensed upstream PR #141,
revision 22d2babacf97fc629cd4bd8ec1ae967006ed1cad. Unlike that PR's clock-only fix,
this implementation also positions the decoded audio at the requested sample.
See https://github.com/dimitris-c/AudioStreaming/issues/133 and
https://github.com/dimitris-c/AudioStreaming/pull/141.

Run BuildTools/test-audio-seeking.sh from the repository root on macOS to compare
real decoded FLAC samples before/after the fix, including strongly varying bitrate,
fractional timestamps, forward/backward/repeated seeks and the final short frame.
