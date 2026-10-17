import Foundation

/// Only offsets subsequently confirmed by AudioFileStream's packet callback are seek anchors.
/// This avoids using a sync-like sequence inside a compressed audio payload as an index entry.
final class FlacSeekIndex {
    private var candidates: [UInt64: Int] = [:]
    private var anchors: [UInt64: Int] = [:]
    private var tail = Data()
    private var nextOffset = 0
    private var nominalBlockSize: UInt32 = 0

    func resetInput(to offset: Int) {
        nextOffset = offset
        tail.removeAll(keepingCapacity: true)
        candidates.removeAll(keepingCapacity: true)
    }

    func scan(_ data: Data) {
        let bytes = tail + data
        let base = nextOffset - tail.count
        // STREAMINFO can span network chunks or follow an ID3 tag. Its maximum
        // block size remains valid when the final fixed-size frame is shorter.
        if nominalBlockSize == 0, let magic = bytes.range(of: Data("fLaC".utf8)) {
            let start = magic.lowerBound
            if bytes.count - start >= 12, bytes[start + 4] & 0x7F == 0,
               bytes[start + 5] == 0, bytes[start + 6] == 0, bytes[start + 7] == 34 {
                nominalBlockSize = UInt32(bytes[start + 10]) << 8 | UInt32(bytes[start + 11])
            }
        }
        bytes.withUnsafeBytes { raw in
            guard raw.count >= 6 else { return }
            for index in 0 ..< raw.count - 5 where raw[index] == 0xFF {
                let frame = UnsafeRawBufferPointer(rebasing: raw[index...])
                if let sample = FlacFrameHeader.firstSampleNumber(in: frame, nominalBlockSize: nominalBlockSize) {
                    candidates[sample] = base + index
                }
            }
        }
        nextOffset += data.count
        tail = Data(bytes.suffix(32))
    }

    func sampleNumber(in bytes: UnsafeRawBufferPointer) -> UInt64? {
        FlacFrameHeader.firstSampleNumber(in: bytes, nominalBlockSize: nominalBlockSize)
    }

    func frameInfo(in bytes: UnsafeRawBufferPointer) -> (sample: UInt64, count: UInt32)? {
        FlacFrameHeader.frameInfo(in: bytes, nominalBlockSize: nominalBlockSize)
    }

    func confirm(_ sample: UInt64) {
        if let offset = candidates.removeValue(forKey: sample) { anchors[sample] = offset }
    }

    func offset(atOrBefore sample: UInt64, dataOffset: Int) -> Int {
        guard let anchor = anchors.keys.filter({ $0 <= sample }).max() else { return dataOffset }
        return anchors[anchor] ?? dataOffset
    }
}
