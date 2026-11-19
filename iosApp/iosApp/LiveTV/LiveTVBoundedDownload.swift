import Foundation

/// Large playlist/catalog transfer to an ephemeral file. The byte cap is enforced while bytes
/// arrive, not after URLSession has allocated a complete response. Callers always remove the file.
enum LiveTVBoundedDownload {
    static func fetch(_ url: URL, session: URLSession, maximumBytes: Int) async throws -> URL {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/x-mpegURL, application/json, */*", forHTTPHeaderField: "Accept")
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do { (bytes, response) = try await session.bytes(for: request) }
        catch { if Task.isCancelled { throw CancellationError() }; throw LiveTVError.providerRejected }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LiveTVError.providerRejected
        }
        guard http.expectedContentLength <= 0 || http.expectedContentLength <= maximumBytes else {
            throw LiveTVError.responseTooLarge
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kyro-live-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: file) else { throw LiveTVError.providerRejected }
        do {
            var chunk = Data()
            chunk.reserveCapacity(64 * 1024)
            var received = 0
            for try await byte in bytes {
                received += 1
                if received > maximumBytes { throw LiveTVError.responseTooLarge }
                chunk.append(byte)
                if chunk.count == 64 * 1024 {
                    try handle.write(contentsOf: chunk)
                    chunk.removeAll(keepingCapacity: true)
                    try Task.checkCancellation()
                }
            }
            if !chunk.isEmpty { try handle.write(contentsOf: chunk) }
            try handle.close()
            return file
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: file)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}
