import Foundation

enum AlbumFileDate {
  private static let flacSignature = Data("fLaC".utf8)
  private static let dateFields = ["RELEASEDATE", "RELEASE_DATE", "ORIGINALDATE", "ORIGINAL_DATE", "DATE"]
  private static let remoteByteLimit = 256 * 1024

  static func sharedFLACDate(in files: [URL]) -> Date? {
    var shared: Date?
    for file in files {
      guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
      defer { try? handle.close() }
      let date = flacDate { offset, count in
        do {
          try handle.seek(toOffset: UInt64(offset))
          return try handle.read(upToCount: count)
        } catch {
          return nil
        }
      }
      guard let date, shared == nil || shared == date else { return nil }
      shared = date
    }
    return shared
  }

  static func remoteFLACDate(at url: URL, headers: [String: String]) async -> Date? {
    var request = URLRequest(url: url, timeoutInterval: 5)
    request.allHTTPHeaderFields = headers
    request.setValue("bytes=0-\(remoteByteLimit - 1)", forHTTPHeaderField: "Range")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForResource = 8
    let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    do {
      let (bytes, response) = try await session.bytes(for: request)
      guard let response = response as? HTTPURLResponse else { return nil }
      guard response.statusCode == 200 || (response.statusCode == 206 &&
        response.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes 0-") == true) else { return nil }

      var prefix = Data()
      for try await byte in bytes {
        prefix.append(byte)
        if prefix.count == flacSignature.count, prefix != flacSignature { return nil }
        if prefix.count == remoteByteLimit { break }
      }
      return flacDate { offset, count in
        guard offset <= prefix.count, count <= prefix.count - offset else { return nil }
        return prefix.subdata(in: offset ..< offset + count)
      }
    } catch {
      return nil
    }
  }

  private static func flacDate(read: (Int, Int) -> Data?) -> Date? {
    guard read(0, flacSignature.count) == flacSignature else { return nil }
    var offset = flacSignature.count
    // FLAC metadata blocks let us skip embedded cover art without decoding it.
    for _ in 0 ..< 128 {
      guard let header = read(offset, 4), header.count == 4 else { return nil }
      let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
      offset += header.count
      if header[0] & 0x7f == 4 {
        guard let comments = read(offset, length), comments.count == length else { return nil }
        return vorbisDate(in: comments)
      }
      if header[0] & 0x80 != 0 { return nil }
      offset += length
    }
    return nil
  }

  private static func vorbisDate(in comments: Data) -> Date? {
    var offset = 0
    func readLength() -> Int? {
      guard comments.count - offset >= 4 else { return nil }
      let length = Int(comments[offset]) | Int(comments[offset + 1]) << 8 |
        Int(comments[offset + 2]) << 16 | Int(comments[offset + 3]) << 24
      offset += 4
      return length
    }

    guard let vendorLength = readLength(), vendorLength <= comments.count - offset else { return nil }
    offset += vendorLength
    guard let fieldCount = readLength(), fieldCount <= (comments.count - offset) / 4 else { return nil }
    var dates: [String: Date] = [:]
    for _ in 0 ..< fieldCount {
      guard let length = readLength(), length <= comments.count - offset else { return nil }
      let start = offset
      offset += length
      guard length <= 128, let field = String(data: comments[start ..< offset], encoding: .utf8),
            let separator = field.firstIndex(of: "=") else { continue }
      let name = field[..<separator].uppercased()
      guard dateFields.contains(name), dates[name] == nil else { continue }
      dates[name] = Album.completeReleaseDateTag(String(field[field.index(after: separator)...]))
    }
    return dateFields.lazy.compactMap { dates[$0] }.first
  }

  private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
      _ session: URLSession,
      task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest,
      completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
      completionHandler(nil)
    }
  }
}
