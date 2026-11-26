#if os(iOS)
import Foundation
import Observation

@MainActor @Observable
final class KyroPodcastDownloads {
    static let shared = KyroPodcastDownloads()
    enum Status: Equatable { case downloading(Double?), failed(String) }
    static let limit: Int64 = 512 * 1024 * 1024
    private(set) var status: [String: Status] = [:]
    private(set) var completed: [String: Int64] = [:]
    var storage: Int64 { completed.values.reduce(0, +) }
    @ObservationIgnored private var transfers: [String: Transfer] = [:]
    @ObservationIgnored private let location = PodcastDownloadLocation(
        root: URL.applicationSupportDirectory.appendingPathComponent("KyroPodcasts/Audio", isDirectory: true))

    private struct Transfer {
        let id: UUID
        let session: URLSession
        let delegate: PodcastDownloadDelegate
    }

    init() {
        let root = location.root
        Task { [weak self] in
            let files = await Task.detached(priority: .utility) {
                let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? []
                var result: [String: Int64] = [:]
                for url in urls {
                    let name = url.deletingPathExtension().lastPathComponent
                    guard name.count == 64, name.allSatisfy(\.isHexDigit),
                          let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                          values.isRegularFile == true, let size = values.fileSize else { continue }
                    result[name] = Int64(size)
                }
                return result
            }.value
            for (name, size) in files where self?.completed[name] == nil { self?.completed[name] = size }
        }
    }

    func hasDownload(_ entry: PodcastEntry) -> Bool { completed[key(entry)] != nil }

    func localURL(for entry: PodcastEntry) -> URL? {
        location.existing(for: entry.episode)
    }

    func start(_ entry: PodcastEntry, wifiOnly: Bool) {
        guard transfers[entry.id] == nil, localURL(for: entry) == nil else { return }
        guard transfers.count < 3 else { status[entry.id] = .failed("Wait for another download to finish."); return }
        guard let url = PodcastAddress.url(entry.episode.media.absoluteString),
              !["m3u", "m3u8"].contains(url.pathExtension.lowercased()) else {
            status[entry.id] = .failed("This episode is not offered as a downloadable audio file."); return
        }
        do {
            try FileManager.default.createDirectory(at: location.root, withIntermediateDirectories: true)
            var folder = location.root
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
        } catch {
            status[entry.id] = .failed("Kyro couldn’t prepare download storage."); return
        }
        KyroPodcastLibrary.shared.retain(entry)
        let id = UUID()
        let delegate = PodcastDownloadDelegate(location: location, episode: entry.episode, progress: { [weak self] ratio in
            guard self?.transfers[entry.id]?.id == id else { return }
            self?.status[entry.id] = .downloading(ratio)
        }, finish: { [weak self] result in
            guard let self, self.transfers[entry.id]?.id == id else { return }
            let transfer = self.transfers.removeValue(forKey: entry.id)
            transfer?.session.finishTasksAndInvalidate()
            switch result {
            case .success(let bytes):
                self.completed[self.key(entry)] = bytes
                self.status[entry.id] = nil
            case .failure(let error):
                self.status[entry.id] = .failed(error.localizedDescription)
            }
        })
        let configuration = PodcastRedirects.configuration(wifiOnly: wifiOnly)
        configuration.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: .main)
        transfers[entry.id] = Transfer(id: id, session: session, delegate: delegate)
        status[entry.id] = .downloading(nil)
        session.downloadTask(with: url).resume()
    }

    func cancel(_ entry: PodcastEntry) {
        guard let transfer = transfers.removeValue(forKey: entry.id) else { return }
        transfer.delegate.cancelled = true
        transfer.session.invalidateAndCancel()
        status[entry.id] = nil
    }

    func remove(_ entry: PodcastEntry) {
        guard let url = localURL(for: entry) else { completed[key(entry)] = nil; return }
        do {
            try FileManager.default.removeItem(at: url)
            completed[key(entry)] = nil
        } catch { status[entry.id] = .failed("Kyro couldn’t remove this download.") }
    }

    private func key(_ entry: PodcastEntry) -> String { PodcastAddress.fingerprint(entry.id) }
}

/// URLSession calls this delegate on the main operation queue. The temporary
/// file is moved before the callback returns; no media bytes are loaded in RAM.
private final class PodcastDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    @MainActor var cancelled = false
    private let downloadLocation: PodcastDownloadLocation
    private let episode: PodcastEpisode
    private let redirects = PodcastRedirects()
    private let progress: @MainActor (Double?) -> Void
    private let finish: @MainActor (Result<Int64, Error>) -> Void
    private var lastUpdate = Date.distantPast
    private var finished = false

    init(location: PodcastDownloadLocation, episode: PodcastEpisode, progress: @escaping @MainActor (Double?) -> Void,
         finish: @escaping @MainActor (Result<Int64, Error>) -> Void) {
        downloadLocation = location
        self.episode = episode
        self.progress = progress
        self.finish = finish
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        redirects.urlSession(session, task: task, willPerformHTTPRedirection: response,
                             newRequest: request, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            guard !cancelled, !finished else { return }
            if max(totalBytesWritten, totalBytesExpectedToWrite) > KyroPodcastDownloads.limit {
                conclude(.failure(PodcastError.tooLarge))
                downloadTask.cancel()
            } else if Date().timeIntervalSince(lastUpdate) >= 0.2 {
                lastUpdate = Date()
                progress(totalBytesExpectedToWrite > 0 ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil)
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        MainActor.assumeIsolated {
            guard !cancelled, !finished else { return }
            do {
                guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
                      PodcastAddress.url(response.url?.absoluteString) != nil,
                      let length = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize, length > 0 else {
                    throw PodcastError.unavailable
                }
                let mime = response.mimeType?.lowercased()
                guard mime == nil || mime?.hasPrefix("audio/") == true ||
                    ["application/octet-stream", "application/ogg", "video/mp4", "binary/octet-stream"].contains(mime ?? ""),
                      mime?.contains("mpegurl") != true else { throw PodcastError.unavailable }
                guard length <= KyroPodcastDownloads.limit else { throw PodcastError.tooLarge }
                try FileManager.default.moveItem(at: location, to: downloadLocation.url(for: episode, mime: mime))
                conclude(.success(Int64(length)))
            } catch { conclude(.failure(error)) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            if !cancelled && !finished { conclude(.failure(error ?? PodcastError.unavailable)) }
        }
    }

    @MainActor private func conclude(_ result: Result<Int64, Error>) {
        finished = true
        finish(result)
    }
}
#endif
