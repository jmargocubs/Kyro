#if os(tvOS)
import XCTest
@testable import Silo

/// Build 103: a stopped, backgrounded or relaunched capture must stay exportable,
/// and a fresh capture must never destroy the one it replaces.
final class TVFocusCaptureStoreTests: XCTestCase {
    private var directory: URL!
    private var store: TVFocusCaptureStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TVFocusCaptureStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = TVFocusCaptureStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func archive(_ details: [String], state: TVFocusCaptureArchive.State = .stopped) -> TVFocusCaptureArchive {
        var buffer = TVFocusDiagnosticBuffer()
        for detail in details { buffer.append(kind: "test", component: "store", detail: detail) }
        return TVFocusCaptureArchive(build: "103", state: state, savedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                     buffer: buffer)
    }

    func testSavedCaptureRoundTripsAfterRelaunch() throws {
        let saved = archive(["press-down", "movement-failed"])
        try store.save(saved.encoded(), to: .latest)
        // A new store over the same directory stands in for a relaunched process.
        let reloaded = try XCTUnwrap(TVFocusCaptureStore(directory: directory).load(.latest))
        XCTAssertEqual(reloaded.events.map(\.detail), ["press-down", "movement-failed"])
        XCTAssertEqual(reloaded.state, .stopped)
        XCTAssertEqual(reloaded.schema, 2)
    }

    func testFreshCaptureKeepsTheReplacedCaptureAsPrevious() throws {
        try store.save(archive(["the-failure"]).encoded(), to: .latest)
        try store.rotateLatestToPrevious()
        XCTAssertEqual(store.load(.previous)?.events.map(\.detail), ["the-failure"])
    }

    func testEmptyLatestNeverReplacesAUsefulPrevious() throws {
        try store.save(archive(["the-failure"]).encoded(), to: .previous)
        try store.save(archive([]).encoded(), to: .latest)
        try store.rotateLatestToPrevious()
        XCTAssertEqual(store.load(.previous)?.events.map(\.detail), ["the-failure"])
    }

    func testCorruptOrOversizedFilesReadAsAbsent() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url(for: .latest))
        XCTAssertNil(store.load(.latest))
        let oversized = Data(repeating: 0x20, count: TVFocusCaptureStore.maximumFileBytes + 1)
        try store.save(oversized, to: .previous)
        XCTAssertNil(store.load(.previous), "oversized writes are skipped, never served")
    }

    func testArchiveKeepsTheRingBoundAndDropCount() {
        var buffer = TVFocusDiagnosticBuffer(capacity: 3)
        for index in 0..<5 { buffer.append(kind: "k", component: "c", detail: "\(index)") }
        let archive = TVFocusCaptureArchive(build: "103", state: .recording, savedAt: Date(), buffer: buffer)
        XCTAssertEqual(archive.events.map(\.detail), ["2", "3", "4"])
        XCTAssertEqual(archive.dropped, 2)
        XCTAssertEqual(buffer.appendedCount, 5)
    }
}
#endif
