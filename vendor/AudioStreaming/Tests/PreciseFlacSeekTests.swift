import AVFoundation
import XCTest
@testable import AudioStreaming

final class PreciseFlacSeekTests: XCTestCase {
    /// Exercises the production AudioFileStream + AudioConverter pipeline. Expected samples
    /// come from independently reading the original PCM file, not from the reported clock.
    func testDecodedSamplesMatchRequestedTimeAfterForwardBackwardAndRepeatedSeeks() throws {
        let directory = try XCTUnwrap(ProcessInfo.processInfo.environment["AUDIO_SEEK_FIXTURES"])
        let reference = try AVAudioFile(forReading: URL(fileURLWithPath: directory + "/markers.wav"))
        let compressed = try Data(contentsOf: URL(fileURLWithPath: directory + "/markers.flac"))
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100,
                                                channels: 2, interleaved: true))
        let context = AudioPlayerContext()
        let renderer = AudioRendererContext(configuration: AudioPlayerConfiguration(bufferSizeInSeconds: 120),
                                             outputAudioFormat: format)
        defer { renderer.clean() }
        let source = SeekTestSource(length: compressed.count)
        let entry = AudioEntry(source: source, entryId: AudioEntryId(id: "time-markers"), outputAudioFormat: format)
        context.audioReadingEntry = entry
        context.audioPlayingEntry = entry
        context.setInternalState(to: .playing)
        let processor = AudioFileStreamProcessor(playerContext: context, rendererContext: renderer,
                                                 outputAudioFormat: format.basicStreamDescription)
        defer { processor.closeFileStreamIfNeeded() }
        var errors: [String] = []
        processor.fileStreamCallback = { effect in
            if case let .raiseError(error) = effect { errors.append(String(describing: error)) }
        }
        XCTAssertEqual(processor.openFileStream(with: kAudioFileFLACType), noErr)
        func feed() throws {
            let end = min(source.position + 65536, compressed.count)
            guard end > source.position else { return }
            let bytes = compressed.subdata(in: source.position ..< end)
            source.position = end
            XCTAssertEqual(processor.parseFileStreamBytes(data: bytes), noErr)
            XCTAssertTrue(errors.isEmpty, errors.joined(separator: ", "))
        }
        try feed()
        XCTAssertEqual(entry.audioStreamFormat.mFormatID, kAudioFormatFLAC)
        for time in [61.001, 3.002, 80.005, 22.25, 95.9, 0, 40.123, 40.123] {
            processor.processSeek(to: time)
            let seekOffset = source.position
            while renderer.bufferContext.frameUsedCount < 2048, source.position < compressed.count {
                try feed()
            }
            if source.position == compressed.count { _ = processor.flushRemainingPackets() }
            XCTAssertGreaterThanOrEqual(renderer.bufferContext.frameUsedCount, 2048, "No audio at \(time)")
            guard renderer.bufferContext.frameUsedCount >= 2048 else { continue }
            let frame = AVAudioFramePosition((time * 44100).rounded())
            reference.framePosition = frame
            let expected = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: reference.processingFormat, frameCapacity: 2048))
            try reference.read(into: expected, frameCount: 2048)
            let actual = try XCTUnwrap(renderer.audioBuffer.mData).assumingMemoryBound(to: Float.self)
            let expectedChannels = try XCTUnwrap(expected.floatChannelData)
            var maximumError: Float = 0
            for index in 0 ..< Int(expected.frameLength) {
                for channel in 0 ..< 2 {
                    maximumError = max(maximumError, abs(actual[index * 2 + channel] - expectedChannels[channel][index]))
                }
            }
            XCTAssertLessThan(maximumError, 0.00004, "Decoded audio is at a different time: target=\(time), byte=\(seekOffset), maxSampleError=\(maximumError)")
            XCTAssertEqual(entry.progress, Double(frame) / 44100, accuracy: 1.0 / 44100)
            if time == 3.002 { XCTAssertGreaterThan(seekOffset, Int(entry.audioStreamState.dataOffset), "Backward seek should reuse a verified frame anchor") }
            print("PreciseFlacSeek: target=\(time) byte=\(seekOffset) maxSampleError=\(maximumError)")
        }
    }
}

private final class SeekTestSource: CoreAudioStreamSource {
    var position = 0
    let length: Int
    weak var delegate: AudioStreamSourceDelegate?
    let audioFileHint: AudioFileTypeID = kAudioFileFLACType
    let underlyingQueue = DispatchQueue(label: "seek-test")
    init(length: Int) { self.length = length }
    func close() {}
    func suspend() {}
    func resume() {}
    func seek(at offset: Int) { position = offset }
}
