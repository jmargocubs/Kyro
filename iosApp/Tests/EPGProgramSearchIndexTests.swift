import Foundation
import XCTest
@testable import Silo

final class EPGProgramSearchIndexTests: XCTestCase {
    private let provider = UUID(uuidString: "A1F4C8A0-CB4C-4B3D-9F73-9AA2BDA7C6B0")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testRankingMinimumLengthAndWhitespace() async throws {
        let guide = makeGuide([
            program("one", 0, "Abacus"), program("two", 60, "News About Cats"),
            program("three", 120, "Evening", subtitle: "Abacus special")
        ])
        let index = try await makeIndex(guide, channels: [channel("one", "One"), channel("two", "Two"), channel("three", "Three")])
        let short = await index.search(query: "a", now: now)
        XCTAssertEqual(short?.count, 0)
        let result = try unwrap(await index.search(query: "  ab  ", now: now))
        XCTAssertEqual(result.map(\.quality), [.titlePrefix, .titleWordPrefix, .subtitle])
        XCTAssertEqual(result.map(\.channelID), ["one", "two", "three"])
    }

    func testUnicodeAndLocaleUseFoundationOracle() async throws {
        let values = ["Café", "CAFE", "İstanbul", "ıstanbul", "Straße", "Ｗｉｄｅ", "😀 News"]
        let guide = makeGuide(values.enumerated().map { program("c\($0.offset)", TimeInterval($0.offset * 60), $0.element) })
        let channels = values.enumerated().map { channel("c\($0.offset)", "C\($0.offset)") }
        let index = try await makeIndex(guide, channels: channels, locale: Locale(identifier: "en_US"))
        for query in ["cafe", "istanbul", "strasse", "wide", "😀 n"] {
            let expected = values.enumerated().compactMap { values[$0.offset].localizedStandardContains(query) ? "c\($0.offset)" : nil }
            let actual = (await index.search(query: query, now: now) ?? []).map(\.channelID).sorted()
            XCTAssertEqual(actual, expected.sorted(), query)
        }
        let turkishGuide = makeGuide([program("tr", 0, "İstanbul")])
        let turkish = try await makeIndex(turkishGuide, channels: [channel("tr", "TR")], locale: Locale(identifier: "tr_TR"))
        let turkishResult = await turkish.search(query: "istanbul", now: now) ?? []
        XCTAssertEqual(turkishResult.count, "İstanbul".localizedStandardContains("istanbul") ? 1 : 0)
    }

    func testEndedProgramsAreExcludedAtQueryTimeAndLiveFirst() async throws {
        let guide = makeGuide([program("a", -120, "Alpha", duration: 60), program("a", 0, "Alpha Live"), program("a", 600, "Alpha Later")])
        let index = try await makeIndex(guide, channels: [channel("a", "A")])
        let result = try unwrap(await index.search(query: "alpha", now: now))
        XCTAssertEqual(result.map(\.title), ["Alpha Live", "Alpha Later"])
        XCTAssertEqual(result.map(\.isLive), [true, false])
        let repeatResult = await index.search(query: "alpha", now: now)
        XCTAssertEqual(result, repeatResult)
    }

    func testDeduplicatesRepresentativeAndNameMapping() async throws {
        let guide = makeGuide([program("guide", 0, "Show")], names: ["guide": "Display"])
        let channels = [channel("first", "First", guideID: "guide"), channel("second", "Second", guideID: "guide"), channel("named", "Display", guideID: "")]
        let index = try await makeIndex(guide, channels: channels)
        let results = try unwrap(await index.search(query: "show", now: now))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].channelID, "first")
    }

    func testIndexDoesNotRetainURLsOrChannels() async throws {
        let guide = makeGuide([program("a", 0, "News")])
        let index = try await makeIndex(guide, channels: [channel("a", "News")])
        let mirror = String(reflecting: index)
        XCTAssertFalse(mirror.contains("LiveTVChannel"))
        XCTAssertFalse(mirror.contains("URL"))
    }

    func testStoreReuseReplacementAndInvalidateGuard() async throws {
        let store = EPGProgramSearchIndexStore()
        let guide = makeGuide([program("a", 0, "News")])
        let input = EPGProgramSearchIndexStore.Input(identity: .init(providerID: provider, catalogRevision: 1, guideGeneration: 1), guide: guide, channels: [channel("a", "A")])
        let first = await store.search(query: "news", input: input, now: now)
        if case let .results(results) = first {
            XCTAssertEqual(results.map(\.title), ["News"])
        } else {
            XCTFail("expected results")
        }
        _ = await store.search(query: "news", input: input, now: now)
        #if DEBUG
        let buildCount = await store.buildCountForTesting
        XCTAssertEqual(buildCount, 1)
        #endif
        await store.invalidate(providerID: UUID())
        let activeIdentity = await store.currentIdentity
        XCTAssertNotNil(activeIdentity)
        await store.invalidate(providerID: provider)
        let clearedIdentity = await store.currentIdentity
        XCTAssertNil(clearedIdentity)
    }

    private func makeIndex(_ guide: EPGIndex, channels: [LiveTVChannel], locale: Locale = Locale(identifier: "en_US")) async throws -> EPGProgramSearchIndex {
        try unwrap(await EPGProgramSearchIndex.build(identity: .init(providerID: provider, catalogRevision: 1, guideGeneration: 1), guide: guide, channels: channels, now: now, locale: locale))
    }
    private func unwrap<T>(_ value: T?) throws -> T { try XCTUnwrap(value) }
    private func makeGuide(_ programs: [EPGProgram], names: [String: String] = [:]) -> EPGIndex {
        let grouped = Dictionary(grouping: programs, by: \.channelID)
        return EPGIndex(fetchedAt: now, programsByChannel: grouped,
                        channelIDsByName: names.reduce(into: [:]) { $0[EPGChannelKey.name($1.value)!] = $1.key }, statistics: .init())
    }
    private func program(_ channel: String, _ offset: TimeInterval, _ title: String, subtitle: String? = nil, duration: TimeInterval = 300) -> EPGProgram {
        EPGProgram(channelID: channel, start: now.addingTimeInterval(offset), end: now.addingTimeInterval(offset + duration), title: title, subtitle: subtitle)
    }
    private func channel(_ id: String, _ name: String, guideID: String? = nil) -> LiveTVChannel {
        LiveTVChannel(id: id, guideID: guideID == nil ? id : (guideID!.isEmpty ? nil : guideID), name: name, streamURL: URL(string: "https://invalid.example/\(id)")!, logoURL: nil, category: "TV")
    }
}
