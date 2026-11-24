#if os(tvOS)
import SwiftUI
import UIKit
import XCTest
@testable import Silo

/// Build 99: edge-to-edge page geometry.
///
/// Pure tests pin the shared metrics and the adaptive column counts. Rendered tests draw the Live
/// TV category page and the TV Guide twice in a hosted tvOS window, once with the Build 98
/// composition (copied here, since the app no longer contains it) and once with the shipping
/// components and modifiers, then measure the pixels. Renders are attached to the result bundle
/// and written to `KYRO_RENDER_DIR` for the workflow artifact. Each measurement is also printed
/// as a `KYRO-LAYOUT` line in the test log.
@MainActor
final class KyroTVEdgeToEdgeLayoutTests: XCTestCase {
    /// Full 1080p canvas, a smaller canvas the size of the 1080p safe area, and a 720p-sized stress case.
    private let canvases: [(name: String, size: CGSize)] = [
        ("1920x1080", CGSize(width: 1920, height: 1080)),
        ("1760x960", CGSize(width: 1760, height: 960)),
        ("1180x660", CGSize(width: 1180, height: 660)),
    ]

    // MARK: Shared metrics

    func testContentStartsCloserUnderTheMenuBarButStillClearsIt() {
        let barBottom = SiloTheme.Skyline.barTopInset + SiloTheme.Skyline.barHeight
        XCTAssertEqual(TVTopMenuLayout.contentTopInset, TVScreenLayout.contentTopInset)
        XCTAssertEqual(TVScreenLayout.contentTopInset, 148)
        XCTAssertGreaterThanOrEqual(TVScreenLayout.contentTopInset - barBottom, 24,
                                    "a focused chip's 1.06 lift stays clear of the bar")
        XCTAssertGreaterThanOrEqual(TVScreenLayout.pageHorizontalInset, TVScreenLayout.overscan.leading,
                                    "page text stays inside the side safe area")
    }

    func testScrollBottomMarginNeverParksContentInTheOverscanBand() {
        XCTAssertEqual(TVScreenLayout.scrollBottomMargin(measuredOverscan: 0),
                       TVScreenLayout.overscan.bottom + TVScreenLayout.focusRoom)
        XCTAssertEqual(TVScreenLayout.scrollBottomMargin(measuredOverscan: 60), 60 + TVScreenLayout.focusRoom)
        XCTAssertEqual(TVScreenLayout.scrollBottomMargin(measuredOverscan: 90), 90 + TVScreenLayout.focusRoom)
    }

    func testFocusRoomCoversTheCardLiftAndRing() {
        let lift = TVKyroFocus.scale(for: .card, focused: true, reduceMotion: false) - 1
        let card = CGSize(width: 460, height: TVLiveTVPageLayout.categoryCardHeight)
        XCTAssertGreaterThanOrEqual(TVScreenLayout.focusRoom, card.height * lift / 2 + TVKyroFocus.ringWidth + 8,
                                    "vertical lift + ring + shadow offset")
        XCTAssertGreaterThanOrEqual(TVScreenLayout.pageHorizontalInset, card.width * lift / 2 + TVKyroFocus.ringWidth,
                                    "the side bleed covers the widest card's lift")
        XCTAssertGreaterThanOrEqual(TVLiveTVGuideLayout.focusRoom,
                                    TVLiveTVGuideLayout.rowHeight(viewportHeight: 960) * lift / 2 + TVKyroFocus.ringWidth)
    }

    func testAdaptiveColumnsFollowTheWidthInsteadOfAssuming1080p() {
        // Width offered to each grid: the canvas minus the page's side insets.
        func width(_ canvas: CGSize) -> CGFloat { canvas.width - 2 * TVScreenLayout.pageHorizontalInset }
        let expected: [(canvas: String, liveTV: Int, sports: Int)] = [
            ("1920x1080", 5, 3),
            ("1760x960", 4, 3),
            ("1180x660", 3, 2),
        ]
        for (canvas, row) in zip(canvases, expected) {
            XCTAssertEqual(canvas.name, row.canvas)
            XCTAssertEqual(TVLiveTVPageLayout.columnCount(width: width(canvas.size)), row.liveTV, canvas.name)
            XCTAssertEqual(TVSportsLayout.columnCount(width: width(canvas.size)), row.sports, canvas.name)
        }
        XCTAssertEqual(TVScreenLayout.adaptiveColumnCount(width: 100, minimum: 300, spacing: 28), 1)
    }

    func testGuideReachesIntoTheOverscanBandWithoutChangingItsTimeline() {
        let safe = TVLiveTVGuideLayout.Metrics(viewport: CGSize(width: 1760, height: 960))
        let extended = TVLiveTVGuideLayout.Metrics(viewport: CGSize(width: 1760, height: 1020), bottomOverscan: 60)
        XCTAssertEqual(extended.pointsPerMinute, safe.pointsPerMinute, "same timeline scale")
        XCTAssertEqual(extended.channelWidth, safe.channelWidth)
        XCTAssertEqual(extended.rowHeight, safe.rowHeight, "rows are sized from the safe height")
        XCTAssertEqual(extended.gridBottomMargin,
                       60 + extended.verticalInset + TVLiveTVGuideLayout.focusRoom, accuracy: 0.01)
        XCTAssertLessThan(extended.horizontalInset, 21, "tighter than Build 98's 21 pt")
    }

    // MARK: Rendered Live TV category page

    func testRenderedCategoryGridFitsMoreRowsAndTheLastRowScrollsFullyIntoView() throws {
        for canvas in canvases {
            let size = canvas.size
            let before = try render(LiveTVCategoryPageHarness(build98: true, canvas: size), size: size)
            let after = try render(LiveTVCategoryPageHarness(build98: false, canvas: size), size: size)
            let beforeEnd = try render(LiveTVCategoryPageHarness(build98: true, canvas: size), size: size, scrollToEnd: true)
            let afterEnd = try render(LiveTVCategoryPageHarness(build98: false, canvas: size), size: size, scrollToEnd: true)
            save(before, name: "livetv-categories-\(canvas.name)-build98")
            save(after, name: "livetv-categories-\(canvas.name)-build99")
            save(beforeEnd, name: "livetv-categories-\(canvas.name)-build98-end")
            save(afterEnd, name: "livetv-categories-\(canvas.name)-build99-end")

            // First column: Build 98 at x = 72, Build 99 at x = 80. Sample inside the card padding.
            let oldRuns = try Pixels(before).darkRuns(x: 72 + 8)
            let newRuns = try Pixels(after).darkRuns(x: 80 + 8)
            let oldEndRuns = try Pixels(beforeEnd).darkRuns(x: 72 + 8)
            let newEndRuns = try Pixels(afterEnd).darkRuns(x: 80 + 8)
            let oldFull = fullCards(oldRuns), newFull = fullCards(newRuns)
            let oldBottom = oldEndRuns.last?.upperBound ?? 0
            let newBottom = newEndRuns.last?.upperBound ?? 0
            let columns = try Pixels(after).darkRuns(y: (newRuns.first { $0.count > 100 }?.lowerBound ?? 0) + 8,
                                                     minimumLength: 150).count
            print("KYRO-LAYOUT livetv-categories \(canvas.name): full rows \(oldFull.count) -> \(newFull.count); "
                  + "card height \(oldFull.first?.count ?? 0) -> \(newFull.first?.count ?? 0) pt; "
                  + "last row bottom at end \(oldBottom) -> \(newBottom) of \(Int(size.height)); columns \(columns)")

            XCTAssertGreaterThan(newFull.count, oldFull.count, "\(canvas.name): more complete rows on screen")
            XCTAssertEqual(columns, TVLiveTVPageLayout.columnCount(width: size.width - 2 * TVScreenLayout.pageHorizontalInset),
                           "\(canvas.name): columns follow the width")
            // Scrolled to the end, the last row rests just above the bottom safe area: fully drawn,
            // not clipped, and nothing parked in the overscan band.
            let safeBottom = Int(size.height - TVScreenLayout.overscan.bottom)
            XCTAssertLessThanOrEqual(newBottom, safeBottom, "\(canvas.name): last row inside the safe area")
            XCTAssertGreaterThanOrEqual(newBottom, safeBottom - Int(TVScreenLayout.focusRoom) - 6,
                                        "\(canvas.name): last row reaches the safe area's bottom")
            XCTAssertGreaterThanOrEqual(newEndRuns.last?.count ?? 0, (newFull.first?.count ?? 1) - 6,
                                        "\(canvas.name): last row drawn at full height")
            XCTAssertLessThan(try Pixels(afterEnd).darkFraction(x: 80..<Int(size.width) - 80,
                                                                y: safeBottom + 2..<Int(size.height)), 0.001,
                              "\(canvas.name): nothing rests in the overscan band")
        }
    }

    // MARK: Rendered TV Guide

    func testRenderedGuideShowsMoreRowsAndTheLastRowScrollsAboveTheSafeArea() throws {
        let fixture = GuideLayoutFixture.make(channelCount: 14)
        let safe = CGSize(width: 1760, height: 960)
        let extended = CGSize(width: 1760, height: 1020)
        let overscan: CGFloat = 60
        let before = try render(GuideLayoutHarness(viewport: safe, fixture: fixture, build98Padding: true), size: safe)
        let after = try render(GuideLayoutHarness(viewport: extended, fixture: fixture, bottomOverscan: overscan),
                               size: extended)
        let afterEnd = try render(GuideLayoutHarness(viewport: extended, fixture: fixture, bottomOverscan: overscan),
                                  size: extended, scrollToEnd: true)
        save(after, name: "guide-1080p-build99-overscan")
        save(afterEnd, name: "guide-1080p-build99-overscan-end")

        let metrics = TVLiveTVGuideLayout.Metrics(viewport: extended, bottomOverscan: overscan)
        // Three columns across the program area, so a gap between two cells cannot split a row.
        let xs = [0.25, 0.5, 0.75].map { Int(metrics.horizontalInset + metrics.channelWidth
                                             + $0 * metrics.programViewportWidth) }
        let top = 114   // below the toolbar and timeline header
        let oldRows = try Pixels(before).litRuns(xs: xs, top: top)
        let newRows = try Pixels(after).litRuns(xs: xs, top: top)
        let endRows = try Pixels(afterEnd).litRuns(xs: xs, top: top)
        let oldFull = oldRows.filter { $0.count >= (oldRows.map(\.count).max() ?? 0) - 2 }.count
        let newVisibleRows = newRows.filter { $0.count >= 10 }.count
        let safeBottom = Int(extended.height - overscan)
        print("KYRO-LAYOUT guide 1760-wide: rows drawn \(oldRows.count) -> \(newVisibleRows) (full in Build 98: \(oldFull)); "
              + "visible height \(Int(safe.height - 2 * TVLiveTVGuideLayout.verticalInset(viewportHeight: 960))) -> "
              + "\(Int(extended.height - metrics.verticalInset)); last row bottom at end \(endRows.last?.upperBound ?? 0) of \(safeBottom) safe")

        XCTAssertGreaterThan(newVisibleRows, oldRows.count, "rows continue through the old bottom margin")
        let lastBottom = try XCTUnwrap(endRows.last?.upperBound)
        XCTAssertLessThanOrEqual(lastBottom, safeBottom, "the last row rests inside the safe area")
        XCTAssertGreaterThanOrEqual(lastBottom, safeBottom - Int(metrics.verticalInset + TVLiveTVGuideLayout.focusRoom) - 6)
        // Cells are drawn slightly shorter than the row, so compare with the tallest drawn row.
        let fullRow = try XCTUnwrap(endRows.map(\.count).max())
        XCTAssertGreaterThanOrEqual(endRows.last?.count ?? 0, fullRow - 2, "the last row is not clipped")
    }

    // MARK: Helpers

    private func fullCards(_ runs: [Range<Int>]) -> [Range<Int>] {
        guard let tallest = runs.map(\.count).max(), tallest > 60 else { return [] }
        return runs.filter { $0.count >= tallest - 6 }
    }

    private func render<V: View>(_ view: V, size: CGSize, scrollToEnd: Bool = false) throws -> UIImage {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: view)
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
        if scrollToEnd {
            let scroll = try XCTUnwrap(scrollViews(in: host.view).first { $0.contentSize.height > $0.bounds.height + 1 },
                                       "the page scrolls vertically")
            // Lazy stacks estimate their height and grow as rows load, so repeat until the end holds.
            var lastHeight: CGFloat = -1
            for _ in 0..<12 where abs(scroll.contentSize.height - lastHeight) > 0.5 {
                lastHeight = scroll.contentSize.height
                let maxY = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: maxY), animated: false)
                spin(0.5)
            }
            print("KYRO-LAYOUT scroll end: contentSize \(scroll.contentSize.height), inset bottom "
                  + "\(scroll.adjustedContentInset.bottom), offset \(scroll.contentOffset.y), bounds \(scroll.bounds.height)")
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

/// The Live TV category page: header, control row and category grid, composed the way
/// `TVLiveTVRootView` composes them. Build 99 uses the shipping card label, columns and
/// `tvEdgeToEdgeScroll`; `build98` reproduces the previous paddings, fixed columns and card.
/// A white page makes the near-black cards measurable. The 60 pt bottom safe area is supplied with
/// `safeAreaPadding`, since the host window has none of its own.
private struct LiveTVCategoryPageHarness: View {
    let build98: Bool
    let canvas: CGSize
    private let categories = (1...40).map { "Category \($0)" + ($0.isMultiple(of: 3) ? " Network Extra" : "") }

    var body: some View {
        Group {
            if build98 { build98Page } else { build99Page }
        }
        // Inside the fixed frame: outside it, the padding would grow the page past the window.
        .safeAreaPadding(.bottom, TVScreenLayout.overscan.bottom)
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .dark)
    }

    private var chips: some View {
        HStack(spacing: 14) {
            ForEach(["All Channels", "Favorites", "Categories", "TV Guide", "Providers"], id: \.self) { title in
                Button(title) {}.buttonStyle(TVKyroChipStyle())
            }
        }
    }

    private var build99Page: some View {
        VStack(alignment: .leading, spacing: TVScreenLayout.sectionSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 22) {
                Text("Live TV").font(.system(size: 46, weight: .bold))
                Text("Provider · 4,000 channels").font(.system(size: 24, weight: .medium))
            }
            chips
            ScrollView {
                LazyVGrid(columns: TVLiveTVPageLayout.categoryColumns, alignment: .leading,
                          spacing: TVLiveTVPageLayout.rowSpacing) {
                    ForEach(categories, id: \.self) { title in
                        TVLiveTVCategoryCardLabel(title: title, count: 120, isAllChannels: false)
                    }
                }
            }
            .tvEdgeToEdgeScroll(horizontalBleed: TVScreenLayout.pageHorizontalInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, TVScreenLayout.pageHorizontalInset)
        .padding(.top, TVTopMenuLayout.contentTopInset)
    }

    private var build98Page: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Live TV").font(.system(size: 52, weight: .bold))
                Text("Provider · 4,000 channels").font(.system(size: 24, weight: .medium))
            }
            chips
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 250, maximum: 340), spacing: 34), count: 5),
                          alignment: .leading, spacing: 28) {
                    ForEach(categories, id: \.self) { title in
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "square.grid.2x2").font(.system(size: 38, weight: .semibold))
                            Text(title).font(.system(size: 27, weight: .semibold)).lineLimit(2)
                            Text("120 channels").font(.system(size: 20))
                        }
                        .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
                        .padding(24)
                        .background(Color.siloSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                }
                .padding(.vertical, 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 72)
        .padding(.top, 188)
        .padding(.bottom, 38)
    }
}

/// RGBA8 pixel access for layout measurements.
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

    private func runs(_ count: Int, minimumLength: Int, _ isOn: (Int) -> Bool) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start: Int?
        for index in 0...count {
            let on = index < count && isOn(index)
            if on, start == nil { start = index }
            if !on, let begin = start {
                if index - begin >= minimumLength { result.append(begin..<index) }
                start = nil
            }
        }
        return result
    }

    /// Vertical runs of near-black card surface on the white harness page.
    func darkRuns(x: Int, minimumLength: Int = 20) -> [Range<Int>] {
        runs(height, minimumLength: minimumLength) { luminance(min(x, width - 1), $0) < 0.2 }
    }

    /// Horizontal runs of card surface along one row.
    func darkRuns(y: Int, minimumLength: Int) -> [Range<Int>] {
        runs(width, minimumLength: minimumLength) { luminance($0, min(max(y, 0), height - 1)) < 0.2 }
    }

    /// Vertical runs of drawn guide cells over the black harness page, below `top`.
    func litRuns(xs: [Int], top: Int) -> [Range<Int>] {
        runs(height, minimumLength: 10) { y in
            y >= top && xs.contains { luminance(min($0, width - 1), y) > 0.04 }
        }
    }

    func darkFraction(x: Range<Int>, y: Range<Int>) -> Double {
        let xs = x.clamped(to: 0..<width), ys = y.clamped(to: 0..<height)
        guard !xs.isEmpty, !ys.isEmpty else { return 0 }
        var hits = 0
        for row in ys { for column in xs where luminance(column, row) < 0.2 { hits += 1 } }
        return Double(hits) / Double(xs.count * ys.count)
    }
}
#endif
