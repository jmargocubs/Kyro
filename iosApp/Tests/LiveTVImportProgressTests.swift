import Foundation
import XCTest
@testable import Silo

final class LiveTVImportProgressTests: XCTestCase {
    private let providerID = UUID(uuidString: "CA6D98E8-A020-42E0-B104-76D05C620DAA")!

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [LiveTVImportCount] = []
        func append(_ value: LiveTVImportCount) {
            lock.lock(); values.append(value); lock.unlock()
        }
        var snapshot: [LiveTVImportCount] {
            lock.lock(); defer { lock.unlock() }; return values
        }
    }

    func testThirtyThousandChannelFixtureReportsRealBoundedCounts() throws {
        let collector = Collector()
        let result = try LiveTVM3UParser.parseResult(
            data: KyroSyntheticCatalog.playlist(count: 30_000), providerID: providerID
        ) { count in collector.append(count) }
        let updates = collector.snapshot
        XCTAssertEqual(result.channels.count, 30_000)
        XCTAssertEqual(result.count, LiveTVImportCount(processed: 30_000, total: 30_000, accepted: 30_000))
        XCTAssertEqual(updates.first?.processed, 0)
        XCTAssertEqual(updates.last?.accepted, 30_000)
        XCTAssertTrue(updates.contains { $0.processed > 5_000 && $0.processed < 30_000 },
                      "fixture must report actual intermediate work, not only completion")
        XCTAssertTrue(updates.allSatisfy { $0.total == 30_000 && $0.accepted == $0.processed },
                      "every synthetic source record is a distinct valid channel")
        XCTAssertTrue(updates.allSatisfy { $0.accepted <= $0.processed && $0.processed <= 30_000 })
        XCTAssertTrue(zip(updates, updates.dropFirst()).allSatisfy { $0.processed <= $1.processed })
        XCTAssertLessThan(updates.count, 130, "publication is bounded, not one SwiftUI update per channel")
    }

    func testMalformedAndDuplicateRecordsAreProcessedButNotImported() throws {
        let data = Data("""
        #EXTM3U
        #EXTINF:-1,One
        https://example.test/1.ts
        #EXTINF:-1,One
        https://example.test/1.ts
        #EXTINF:-1,Bad
        ftp://example.test/bad.ts
        #EXTINF:-1,Two
        https://example.test/2.ts
        """.utf8)
        let result = try LiveTVM3UParser.parseResult(data: data, providerID: providerID)
        XCTAssertEqual(result.channels.count, 2)
        XCTAssertEqual(result.count.processed, 4)
        XCTAssertEqual(result.count.total, 4)
        XCTAssertEqual(result.count.rejected, 2)
        XCTAssertEqual(result.count.duplicate, 1)
        XCTAssertEqual(result.count.unsupported, 1)
        XCTAssertEqual(result.count.fraction, 1)
    }

    func testUnknownTotalHasNoPercentage() {
        let count = LiveTVImportCount(processed: 5_284, total: nil, accepted: 5_000)
        XCTAssertNil(count.fraction)
        XCTAssertEqual(count.rejected, 284)
    }

    func testPercentageNeverExceedsOneWhenTotalChanges() {
        XCTAssertEqual(LiveTVImportCount(processed: 12_450, total: 30_000, accepted: 12_000).fraction, 0.415)
        XCTAssertEqual(LiveTVImportCount(processed: 12_450, total: 12_000, accepted: 12_000).fraction, 1)
        XCTAssertNil(LiveTVImportCount(processed: 0, total: 0, accepted: 0).fraction)
    }

    func testCancelledParserDoesNotCompleteImport() async throws {
        let data = KyroSyntheticCatalog.playlist(count: 30_000)
        let providerID = self.providerID
        let task = Task.detached {
            try LiveTVM3UParser.parseResult(data: data, providerID: providerID)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled parse must not produce a completed catalog")
        } catch is CancellationError {
            // Expected.
        }
    }
}
