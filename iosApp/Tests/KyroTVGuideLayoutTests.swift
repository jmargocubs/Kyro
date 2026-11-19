#if os(tvOS)
import SwiftUI
import UIKit
import XCTest
@testable import Silo

/// Build 98: TV Guide geometry. The pure tests pin the shared coordinate system; the rendered tests
/// draw the real toolbar, timeline header, grid and rows (the components `TVLiveTVGuideView`
/// composes) in a hosted tvOS window and check the pixels. PNGs are attached to the result bundle
/// and, when `KYRO_RENDER_DIR` is set, written there for the workflow artifact.
@MainActor
final class KyroTVGuideLayoutTests: XCTestCase {
    /// The 1080p tvOS safe area (Apple TV HD and 4K both lay out at 1920×1080 points), the full
    /// 1080p canvas, and a narrow 720p-sized stress case.
    private let viewports: [(name: String, size: CGSize)] = [
        ("1080p-safe-area", CGSize(width: 1760, height: 960)),
        ("1080p-full", CGSize(width: 1920, height: 1080)),
        ("720p-stress", CGSize(width: 1180, height: 660)),
    ]

    // MARK: Geometry

    func testChannelColumnTimelineAndCellsShareOneCoordinateSystem() {
        let anchor = Date(timeIntervalSince1970: 1_800_000_000)
        for viewport in viewports {
            let metrics = TVLiveTVGuideLayout.Metrics(viewport: viewport.size)
            let timeline = TVLiveTVGuideView.timeline(anchor: anchor, pointsPerMinute: metrics.pointsPerMinute)
            XCTAssertEqual(2 * metrics.horizontalInset + metrics.channelWidth + metrics.programViewportWidth,
                           viewport.size.width, accuracy: 0.5, viewport.name)
            // The header lays one slot per tick from x = channelWidth; rows place cells from the same x.
            XCTAssertEqual(CGFloat(timeline.ticks.count) * metrics.slotWidth, timeline.width, accuracy: 0.5, viewport.name)
            let program = EPGProgram(channelID: "c", start: timeline.start.addingTimeInterval(90 * 60),
                                     end: timeline.start.addingTimeInterval(120 * 60), title: "P")
            let cell = LiveTVGuideCell.cells(for: [program], in: timeline)[0]
            XCTAssertEqual(cell.x, 3 * metrics.slotWidth, accuracy: 0.5, "a 1:30 listing starts under the 4th tick")
            XCTAssertEqual(cell.width, metrics.slotWidth, accuracy: 0.5)
        }
    }

    func testVisibleWindowFillsTheProgramViewportAndKeepsHorizontalScrolling() {
        let anchor = Date(timeIntervalSince1970: 1_800_000_000)
        for viewport in viewports {
            let metrics = TVLiveTVGuideLayout.Metrics(viewport: viewport.size)
            let timeline = TVLiveTVGuideView.timeline(anchor: anchor, pointsPerMinute: metrics.pointsPerMinute)
            XCTAssertGreaterThanOrEqual(metrics.visibleMinutes, 150, "\(viewport.name): at least 2.5 h on screen")
            XCTAssertLessThanOrEqual(metrics.visibleMinutes, 200, "\(viewport.name): listings stay readable")
            XCTAssertGreaterThan(timeline.width, metrics.programViewportWidth,
                                 "\(viewport.name): later listings scroll in horizontally")
            XCTAssertGreaterThanOrEqual(metrics.slotWidth, 126, "\(viewport.name): 30 min at least as wide as Build 97")
        }
    }

    func testMarginsAreTightButInsideTheSafeAreaAndTextKeepsItsSize() {
        for viewport in viewports {
            let metrics = TVLiveTVGuideLayout.Metrics(viewport: viewport.size)
            XCTAssertGreaterThanOrEqual(metrics.horizontalInset, 12)
            XCTAssertLessThanOrEqual(metrics.horizontalInset, 24)
            XCTAssertGreaterThanOrEqual(metrics.channelWidth, 320, "logo + two-line 26 pt name fit")
            XCTAssertGreaterThanOrEqual(metrics.rowHeight, 108)
            XCTAssertLessThanOrEqual(metrics.channelWidth, metrics.contentWidth * 0.3)
        }
    }

    func testMetricsDependOnlyOnTheViewport() {
        // Build 97 measured the viewport from content that the timeline had widened. The metrics
        // are a pure function of the offered size, so content cannot feed back into them.
        let size = CGSize(width: 1760, height: 960)
        XCTAssertEqual(TVLiveTVGuideLayout.Metrics(viewport: size), TVLiveTVGuideLayout.Metrics(viewport: size))
    }

    // MARK: Rendered layout

    func testRenderedGuideFillsTheViewportWithoutClippingChannelsOrTimeline() throws {
        for viewport in viewports {
            let image = try render(viewport.size, scrollX: 0)
            save(image, name: "guide-\(viewport.name)")
            let metrics = TVLiveTVGuideLayout.Metrics(viewport: viewport.size)
            let pixels = try Pixels(image)
            let top = Int(metrics.verticalInset + 70)   // below the toolbar
            let bottom = Int(viewport.size.height - metrics.verticalInset - 4)

            // Nothing is drawn in the outer margins: no channel name is clipped on the left and no
            // timeline label or program runs past the right edge.
            let margin = Int(metrics.horizontalInset) - 3
            XCTAssertLessThan(pixels.brightFraction(x: 0..<margin, y: top..<bottom), 0.001,
                              "\(viewport.name): content in the left margin")
            XCTAssertLessThan(pixels.brightFraction(x: Int(viewport.size.width) - margin..<Int(viewport.size.width),
                                                    y: 0..<Int(viewport.size.height)), 0.001,
                              "\(viewport.name): content in the right margin")

            // Channel names are drawn inside the channel column.
            let channelColumn = Int(metrics.horizontalInset)..<Int(metrics.horizontalInset + metrics.channelWidth)
            XCTAssertGreaterThan(pixels.brightFraction(x: channelColumn, y: top..<bottom), 0.005,
                                 "\(viewport.name): channel names visible")

            // The program grid reaches the right edge of the viewport: no large empty region.
            let right = Int(viewport.size.width - metrics.horizontalInset)
            XCTAssertGreaterThan(pixels.litFraction(x: right - 140..<right - 10, y: top..<bottom), 0.25,
                                 "\(viewport.name): program cells fill the right side")
        }
    }

    func testRenderedTimelineHeaderStaysAlignedWhenTheGridScrollsHorizontally() throws {
        let size = viewports[0].size
        let metrics = TVLiveTVGuideLayout.Metrics(viewport: size)
        let start = try render(size, scrollX: 0)
        let scrolled = try render(size, scrollX: metrics.slotWidth * 4)
        save(scrolled, name: "guide-1080p-safe-area-scrolled-2h")
        // Header and grid shifted together: the header strip changed, and no tick label escaped
        // past the right edge.
        let headerY = Int(metrics.verticalInset + 64)..<Int(metrics.verticalInset + 64 + TVLiveTVGuideLayout.timelineHeaderHeight)
        let x = Int(metrics.horizontalInset + metrics.channelWidth)..<Int(size.width - metrics.horizontalInset)
        XCTAssertNotEqual(try Pixels(start).signature(x: x, y: headerY), try Pixels(scrolled).signature(x: x, y: headerY),
                          "the timeline header follows the grid's horizontal scroll")
        let margin = Int(metrics.horizontalInset) - 3
        XCTAssertLessThan(try Pixels(scrolled).brightFraction(x: Int(size.width) - margin..<Int(size.width),
                                                              y: 0..<Int(size.height)), 0.001)
    }

    // MARK: Rendering

    private func render(_ size: CGSize, scrollX: CGFloat) throws -> UIImage {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: GuideLayoutHarness(viewport: size, fixture: .make()))
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.frame = window.bounds
        spin(0.8)
        if scrollX > 0 {
            let scroll = try XCTUnwrap(scrollViews(in: host.view).first { $0.contentSize.width > $0.bounds.width + 1 },
                                       "the guide grid scrolls horizontally")
            scroll.setContentOffset(CGPoint(x: scrollX - scroll.adjustedContentInset.left, y: scroll.contentOffset.y),
                                    animated: false)
            spin(0.6)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        let own: [UIScrollView] = (view as? UIScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap(scrollViews(in:))
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func save(_ image: UIImage, name: String) {
        guard let data = image.pngData() else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["KYRO_RENDER_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? data.write(to: url.appendingPathComponent("\(name).png"))
        }
    }
}

/// Fixture listings that cover the whole timeline, so an empty region can only be a layout fault.
@MainActor
private struct GuideLayoutFixture {
    let anchor: Date
    let channels: [LiveTVChannel]
    let programs: [String: [EPGProgram]]

    static func make() -> GuideLayoutFixture {
        let anchor = Date()
        let names = ["NFHS Network Championship Coverage East", "City News", "Arena Sports 1",
                     "Weather Now", "Classic Movies", "Kids Channel", "World Music", "Science Today"]
        let timeline = TVLiveTVGuideView.timeline(anchor: anchor, pointsPerMinute: 1)
        var channels: [LiveTVChannel] = []
        var programs: [String: [EPGProgram]] = [:]
        for (index, name) in names.enumerated() {
            let id = "fixture-\(index)"
            channels.append(LiveTVChannel(id: id, guideID: id, name: name,
                                          streamURL: URL(string: "https://example.invalid/\(id)")!,
                                          logoURL: nil, category: index.isMultiple(of: 2) ? "Sports" : "News"))
            var start = timeline.start
            var listings: [EPGProgram] = []
            var part = 0
            while start < timeline.end {
                let minutes = [30, 60, 90][(index + part) % 3]
                let end = min(timeline.end, start.addingTimeInterval(TimeInterval(minutes * 60)))
                listings.append(EPGProgram(channelID: id, start: start, end: end, title: "\(name) Program \(part + 1)"))
                start = end
                part += 1
            }
            programs[id] = listings
        }
        return GuideLayoutFixture(anchor: anchor, channels: channels, programs: programs)
    }
}

/// The same composition as `TVLiveTVGuideView.body`: toolbar, then the shared grid, inside the
/// metrics' insets. A plain black background keeps the pixel checks unambiguous.
private struct GuideLayoutHarness: View {
    let viewport: CGSize
    let fixture: GuideLayoutFixture
    @FocusState private var focus: TVLiveTVGuideFocus?

    var body: some View {
        let metrics = TVLiveTVGuideLayout.Metrics(viewport: viewport)
        let timeline = TVLiveTVGuideView.timeline(anchor: fixture.anchor, pointsPerMinute: metrics.pointsPerMinute)
        VStack(alignment: .leading, spacing: TVLiveTVGuideLayout.rowSpacing) {
            TVLiveTVGuideToolbar(categoryTitle: nil, categories: ["News", "Sports"], favoritesOnly: false,
                                 focus: $focus, onBack: {}, onSelectCategory: { _ in },
                                 onToggleFavorites: {}, onRefresh: {})
            TVLiveTVGuideGrid(metrics: metrics, timeline: timeline, rows: fixture.channels) { channel in
                TVLiveTVGuideRow(channel: channel, programs: fixture.programs[channel.id] ?? [],
                                 metrics: metrics, timeline: timeline, isPlaying: false, focus: $focus,
                                 onWatch: {}, onProgram: { _ in })
            }
        }
        .padding(.horizontal, metrics.horizontalInset)
        .padding(.vertical, metrics.verticalInset)
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }
}

/// RGBA8 pixel access for layout assertions.
private struct Pixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: UIImage) throws {
        let cgImage = try XCTUnwrap(image.cgImage)
        width = cgImage.width
        height = cgImage.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = buffer
    }

    private func luminance(_ x: Int, _ y: Int) -> Double {
        let i = (y * width + x) * 4
        return (0.2126 * Double(bytes[i]) + 0.7152 * Double(bytes[i + 1]) + 0.0722 * Double(bytes[i + 2])) / 255
    }

    private func fraction(x: Range<Int>, y: Range<Int>, where predicate: (Double) -> Bool) -> Double {
        let xs = x.clamped(to: 0..<width), ys = y.clamped(to: 0..<height)
        guard !xs.isEmpty, !ys.isEmpty else { return 0 }
        var hits = 0
        for row in ys { for column in xs where predicate(luminance(column, row)) { hits += 1 } }
        return Double(hits) / Double(xs.count * ys.count)
    }

    /// Text-bright pixels (labels, names).
    func brightFraction(x: Range<Int>, y: Range<Int>) -> Double { fraction(x: x, y: y) { $0 > 0.6 } }
    /// Anything drawn over the black background (cells, surfaces, text).
    func litFraction(x: Range<Int>, y: Range<Int>) -> Double { fraction(x: x, y: y) { $0 > 0.04 } }

    func signature(x: Range<Int>, y: Range<Int>) -> [Bool] {
        let xs = x.clamped(to: 0..<width), ys = y.clamped(to: 0..<height)
        return ys.flatMap { row in xs.map { luminance($0, row) > 0.5 } }
    }
}
#endif
