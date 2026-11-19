#if os(tvOS)
import Foundation
import XCTest
@testable import Silo

/// Build 95: Apple TV evidence showed 36,578 series imported and zero movies, with "The VOD
/// catalog exceeds the supported download limit". Build 94 buffered each catalog in memory and
/// failed above 96 MiB or 100,000 movies (50,000 series). These tests cover the streamed import
/// that replaced it. No real provider or credentials are used.
@MainActor
final class XtreamVODLargeCatalogTests: XCTestCase {
    private final class Secrets: LiveTVSecretStore {
        var values: [String: String] = [:]
        func read(account: String) -> String? { values[account] }
        func save(_ value: String, account: String) -> Bool { values[account] = value; return true }
        func remove(account: String) -> Bool { values[account] = nil; return true }
    }

    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var session: URLSession!
    private var live: LiveTVService!
    private var stores: [XtreamVODCatalogStore] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("VODLarge-\(UUID().uuidString)")
        suite = "VODLarge.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LargeCatalogStub.self]
        session = URLSession(configuration: config)
        live = LiveTVService(defaults: defaults, secretStore: Secrets(), session: session,
                             channelSnapshotStore: LiveTVChannelSnapshotStore(directory: directory.appendingPathComponent("live")))
        LargeCatalogStub.reset()
    }

    override func tearDown() async throws {
        live = nil
        for store in stores { await store.close() }
        stores.removeAll()
        LargeCatalogStub.reset()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private func service(limits: @escaping (XtreamVODKind) -> XtreamVODCatalogLimits = XtreamVODCatalogLimits.standard(for:),
                         freeSpace: @escaping () -> Int64? = { nil }) throws -> XtreamVODService {
        let store = try XtreamVODCatalogStore(directory: directory.appendingPathComponent("vod-\(stores.count)"))
        stores.append(store)
        return XtreamVODService(store: store, session: session, defaults: defaults, limits: limits,
                                availableDiskBytes: freeSpace, makeStore: { throw XtreamVODError.storage })
    }

    private func provider(movies: Bool = true, series: Bool = true) throws -> UUID {
        try live.saveXtreamConfiguration(name: "Large", serverURL: "https://vodlarge.test",
                                         username: "viewer", password: "fake-secret",
                                         selection: .init(liveTV: false, movies: movies, series: series))
    }

    private static func limits(records: Int = 400_000, bytes: Int = 384 * 1_048_576,
                               recordBytes: Int = 256 * 1024) -> (XtreamVODKind) -> XtreamVODCatalogLimits {
        { _ in .init(maximumDownloadBytes: bytes, maximumRecords: records, maximumRecordBytes: recordBytes,
                     reservedDiskBytes: 1_048_576) }
    }

    /// A realistic `get_vod_streams` / `get_series` body: one JSON array of `count` records.
    static func catalog(_ count: Int, kind: XtreamVODKind, startID: Int = 1) -> Data {
        var data = Data()
        data.reserveCapacity(count * 330)
        data.append(UInt8(ascii: "["))
        for offset in 0..<count {
            let id = startID + offset
            if offset > 0 { data.append(UInt8(ascii: ",")) }
            let record = kind == .movie
                ? #"{"num":\#(id),"name":"Movie \#(id) (2024)","stream_type":"movie","stream_id":\#(id),"stream_icon":"https://img.vodlarge.test/p/\#(id).jpg","rating":"7.1","rating_5based":3.6,"added":"1700000000","is_adult":"0","category_id":"1","category_ids":[1],"container_extension":"mp4","custom_sid":"","direct_source":""}"#
                : #"{"num":\#(id),"name":"Series \#(id)","series_id":\#(id),"cover":"https://img.vodlarge.test/s/\#(id).jpg","plot":"Season story \#(id).","genre":"Drama","rating":"8","category_id":"1"}"#
            data.append(contentsOf: record.utf8)
        }
        data.append(UInt8(ascii: "]"))
        return data
    }

    private func vodTemporaryFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
            .filter { $0.hasPrefix(XtreamVODHTTP.temporaryFilePrefix) }
    }

    // MARK: Large catalogs

    func testMovieCatalogLargerThanBuild94CapImportsCompletely() async throws {
        // 120,000 movies: above Build 94's 100,000-movie cap that produced the device error.
        let id = try provider(series: false)
        let vod = try service()
        LargeCatalogStub.bodies["get_vod_streams"] = Self.catalog(120_000, kind: .movie)
        let start = Date()
        await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(vod.progress?.stage, .ready, vod.progress?.message ?? "")
        XCTAssertEqual(vod.progress?.movieResult, .ready)
        XCTAssertEqual(vod.progress?.movies,
                       .init(processed: 120_000, total: 120_000, accepted: 120_000, malformed: 0, duplicate: 0))
        let stored = await vod.count(providerID: id, kind: .movie)
        XCTAssertEqual(stored, 120_000)
        let lastPage = await vod.page(providerID: id, kind: .movie, offset: 119_950)
        XCTAssertEqual(lastPage.count, 50)
        XCTAssertEqual(vod.progress?.message, "120,000 movies imported.")
        XCTAssertTrue(vodTemporaryFiles().isEmpty, "the transfer file is always removed")
        print("VOD-BENCH movies=120000 elapsed_s=\(String(format: "%.2f", Date().timeIntervalSince(start)))")
    }

    func testMoviesAndSeriesImportIndependentlyAtDeviceScale() async throws {
        // Device evidence: 36,578 series succeeded while movies failed. Both must now import.
        let id = try provider()
        let vod = try service()
        LargeCatalogStub.bodies["get_vod_streams"] = Self.catalog(105_000, kind: .movie)
        LargeCatalogStub.bodies["get_series"] = Self.catalog(55_000, kind: .series)
        await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(vod.progress?.movieResult, .ready)
        XCTAssertEqual(vod.progress?.seriesResult, .ready, "55,000 series is above Build 94's 50,000-series cap")
        let movies = await vod.count(providerID: id, kind: .movie)
        let series = await vod.count(providerID: id, kind: .series)
        XCTAssertEqual(movies, 105_000)
        XCTAssertEqual(series, 55_000)
        XCTAssertEqual(vod.progress?.message, "105,000 movies and 55,000 series imported.")
    }

    // MARK: Download-limit boundaries

    func testBodyExactlyAtTransferLimitImports() async throws {
        let id = try provider(series: false)
        let body = Self.catalog(40, kind: .movie)
        let vod = try service(limits: Self.limits(bytes: body.count))
        LargeCatalogStub.bodies["get_vod_streams"] = body
        await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(vod.progress?.movieResult, .ready)
        let movies = await vod.count(providerID: id, kind: .movie)
        XCTAssertEqual(movies, 40)
    }

    func testBodyOneByteOverTransferLimitFailsAndKeepsPreviousCatalog() async throws {
        let id = try provider(series: false)
        let body = Self.catalog(40, kind: .movie)
        let vod = try service(limits: Self.limits(bytes: body.count - 1))
        LargeCatalogStub.bodies["get_vod_streams"] = Self.catalog(3, kind: .movie)
        await vod.refresh(providerID: id, liveTV: live)
        let before = await vod.count(providerID: id, kind: .movie)
        XCTAssertEqual(before, 3)

        LargeCatalogStub.bodies["get_vod_streams"] = body
        await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(vod.progress?.movieResult, .failed)
        XCTAssertEqual(vod.progress?.failure, .downloadLimit(megabytes: 0))
        XCTAssertEqual(vod.progress?.failedStage, .download)
        XCTAssertEqual(vod.progress?.failure?.category, "response_too_large")
        let after = await vod.count(providerID: id, kind: .movie)
        XCTAssertEqual(after, 3, "an oversized catalog never replaces the working one")
        XCTAssertTrue(vodTemporaryFiles().isEmpty)
    }

    func testAdvertisedLengthOverLimitStopsBeforeReadingTheBody() async throws {
        let id = try provider(series: false)
        let vod = try service(limits: Self.limits(bytes: 2 * 1_048_576))
        LargeCatalogStub.bodies["get_vod_streams"] = Self.catalog(5, kind: .movie)
        LargeCatalogStub.advertisedLength["get_vod_streams"] = 3 * 1_048_576
        await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(vod.progress?.failure, .downloadLimit(megabytes: 2))
        XCTAssertTrue(vod.progress?.message?.contains("2 MB download limit") == true, vod.progress?.message ?? "")
    }

    func testRecordCapImportsFirstTitlesAndReportsTheRest() async throws {
        let id = try provider(series: false)
        let vod = try service(limits: Self.limits(records: 1_000))
        LargeCatalogStub.bodies["get_vod_streams"] = Self.catalog(1_250, kind: .movie)
        await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(vod.progress?.stage, .ready)
        XCTAssertEqual(vod.progress?.movieResult, .ready)
        XCTAssertEqual(vod.progress?.movies,
                       .init(processed: 1_000, total: 1_250, accepted: 1_000, malformed: 0, duplicate: 0, overLimit: 250))
        XCTAssertEqual(vod.progress?.movies.fraction, 1)
        let stored = await vod.count(providerID: id, kind: .movie)
        XCTAssertEqual(stored, 1_000)
        let message = try XCTUnwrap(vod.progress?.message)
        XCTAssertTrue(message.hasPrefix("1,000 movies imported."), message)
        XCTAssertTrue(message.contains("The provider lists 1,250 movies; Kyro keeps the first 1,000"), message)
    }

    func testCatalogExactlyAtRecordCapHasNothingOverLimit() async throws {
        let id = try provider(series: false)
        let vod = try service(limits: Self.limits(records: 1_000))
        LargeCatalogStub.bodies["get_vod_streams"] = Self.catalog(1_000, kind: .movie)
        await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(vod.progress?.movies.overLimit, 0)
        XCTAssertEqual(vod.progress?.message, "1,000 movies imported.")
    }

    func testOversizedRecordIsSkippedAsMalformedWithoutFailingTheCatalog() async throws {
        let id = try provider(series: false)
        let vod = try service(limits: Self.limits(recordBytes: 400))
        let long = String(repeating: "x", count: 600)
        LargeCatalogStub.bodies["get_vod_streams"] = Data(#"[{"stream_id":1,"name":"Short"},{"stream_id":2,"name":"Long","plot":"\#(long)"},{"stream_id":3,"name":"After"}]"#.utf8)
        await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(vod.progress?.movies, .init(processed: 3, total: 3, accepted: 2, malformed: 1, duplicate: 0))
        let titles = await vod.page(providerID: id, kind: .movie).map(\.title)
        XCTAssertEqual(titles, ["After", "Short"])
    }

    func testInsufficientDiskSpaceIsAStorageFailure() async throws {
        let id = try provider(series: false)
        let vod = try service(freeSpace: { 512 })
        LargeCatalogStub.bodies["get_vod_streams"] = Self.catalog(10, kind: .movie)
        await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(vod.progress?.failure, .storage)
        XCTAssertTrue(vodTemporaryFiles().isEmpty)
    }

    // MARK: Safe parsing and persistence

    func testTruncatedCatalogIsInvalidAndNeverPartiallyPromoted() async throws {
        let id = try provider(series: false)
        let vod = try service()
        LargeCatalogStub.bodies["get_vod_streams"] = Self.catalog(4, kind: .movie)
        await vod.refresh(providerID: id, liveTV: live)
        var cut = Self.catalog(2_000, kind: .movie)
        cut.removeLast(40)
        LargeCatalogStub.bodies["get_vod_streams"] = cut
        await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(vod.progress?.failure, .invalidResponse)
        XCTAssertEqual(vod.progress?.failedStage, .parsing)
        let movies = await vod.count(providerID: id, kind: .movie)
        XCTAssertEqual(movies, 4, "a cut-off transfer is not a smaller catalog")
    }

    func testKeyedObjectCatalogAndAccountRejectionStream() async throws {
        let id = try provider(series: false)
        let vod = try service()
        LargeCatalogStub.bodies["get_vod_streams"] = Data(#"{"10":{"stream_id":10,"name":"Ten"},"2":{"stream_id":2,"name":"Two"},"x":null}"#.utf8)
        await vod.refresh(providerID: id, liveTV: live)
        let stored = await vod.count(providerID: id, kind: .movie)
        XCTAssertEqual(stored, 2)
        LargeCatalogStub.bodies["get_vod_streams"] = Data(#"{"user_info":{"auth":0}}"#.utf8)
        await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(vod.progress?.movieResult, .authentication)
        let retained = await vod.count(providerID: id, kind: .movie)
        XCTAssertEqual(retained, 2)
    }

    func testScannerSplitsMembersAcrossEveryChunkBoundary() throws {
        let body = Array(#"[{"stream_id":1,"name":"One ] } [ {"},null,7,"s",{"stream_id":2,"name":"Two \"quoted\" \\ end","category_ids":[1,2]}]"#.utf8)
        for chunkSize in [1, 2, 3, 7, 64, body.count] {
            var scanner = XtreamVODCatalogScanner(maximumMemberBytes: 1024)
            var objects: [String] = []
            for start in stride(from: 0, to: body.count, by: chunkSize) {
                let chunk = Array(body[start..<min(start + chunkSize, body.count)])
                _ = try chunk.withUnsafeBufferPointer { buffer in
                    try scanner.consume(buffer) { member in
                        if member.isObject, let bytes = member.bytes { objects.append(String(decoding: bytes, as: UTF8.self)) }
                        return true
                    }
                }
            }
            try scanner.finish()
            XCTAssertEqual(objects.count, 2, "chunk size \(chunkSize)")
            XCTAssertEqual(objects.first, #"{"stream_id":1,"name":"One ] } [ {"}"#)
            XCTAssertTrue(objects.last?.hasSuffix(#""category_ids":[1,2]}"#) == true)
        }
    }

    func testScannerRejectsNonJSONAndTruncation() {
        for body in ["<html>", "nope", "[{\"stream_id\":1}", "{\"1\":{\"stream_id\":1}", "nul"] {
            XCTAssertThrowsError(try XtreamVODParser.records(Data(body.utf8)), body) {
                XCTAssertEqual($0 as? XtreamVODError, .invalidResponse, body)
            }
        }
    }

    func testCountPassMatchesImportAndIgnoresAccountObjects() throws {
        let file = directory.appendingPathComponent("count.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"user_info":{"auth":1},"server_info":{"url":"x"}}"#.utf8).write(to: file)
        XCTAssertEqual(try XtreamVODCatalogFile.countRecords(at: file, limits: .standard(for: .movie)), 0)
        try Self.catalog(3_000, kind: .series).write(to: file)
        XCTAssertEqual(try XtreamVODCatalogFile.countRecords(at: file, limits: .standard(for: .series)), 3_000)
    }

    func testStandardLimitsStayBounded() {
        for kind in XtreamVODKind.allCases {
            let limits = XtreamVODCatalogLimits.standard(for: kind)
            XCTAssertGreaterThan(limits.maximumRecords, kind == .movie ? 100_000 : 50_000, "above the Build 94 caps")
            XCTAssertLessThanOrEqual(limits.maximumRecords, 400_000)
            XCTAssertGreaterThan(limits.maximumDownloadBytes, 96 * 1_048_576)
            XCTAssertLessThanOrEqual(limits.maximumDownloadBytes, 384 * 1_048_576)
            XCTAssertLessThanOrEqual(limits.maximumRecordBytes, 256 * 1024)
        }
    }
}

/// Xtream stub that can serve multi-megabyte bodies and advertise a `Content-Length`.
private final class LargeCatalogStub: URLProtocol {
    private static let lock = NSLock()
    static var bodies: [String: Data] = [:]
    static var advertisedLength: [String: Int] = [:]

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        bodies = [:]
        advertisedLength = [:]
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "vodlarge.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "action" })?.value ?? "auth"
        Self.lock.lock()
        let body: Data
        switch action {
        case "auth": body = Data(#"{"user_info":{"auth":1,"status":"Active"}}"#.utf8)
        case "get_vod_categories", "get_series_categories": body = Data(#"[{"category_id":"1","category_name":"Featured"}]"#.utf8)
        default: body = Self.bodies[action] ?? Data("[]".utf8)
        }
        var headers: [String: String] = [:]
        if let length = Self.advertisedLength[action] { headers["Content-Length"] = String(length) }
        Self.lock.unlock()
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Deliver in 1 MiB pieces like a real transfer.
        var offset = 0
        while offset < body.count {
            let end = min(offset + 1_048_576, body.count)
            client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
