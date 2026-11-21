#if os(tvOS) && (DEBUG || KYRO_FOCUS_DIAGNOSTICS)
import XCTest
@testable import Silo

/// Exercises the actual Network.framework listener with URLSession rather than testing only
/// JSON encoding. This catches Safari-facing request/response and attachment regressions.
@MainActor
final class TVFocusReportServerTests: XCTestCase {
    private let inspector = TVRemoteFocusInspector.shared
    private let server = TVFocusReportServer.shared

    override func tearDown() {
        server.stop()
        inspector.setEnabled(false)
        super.tearDown()
    }

    func testAuthenticatedDownloadReturnsCompleteJSONAttachmentForNonemptyReport() async throws {
        inspector.setEnabled(true)
        inspector.record("test", "inspector", "sample-event")
        server.start()
        let base = try await readyAddress()
        let code = server.code

        let landing = try await URLSession.shared.data(from: URL(string: base)!)
        XCTAssertEqual((landing.1 as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: landing.0, as: UTF8.self).contains("Eight-digit access code"))

        var request = URLRequest(url: URL(string: base + "/authenticate")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("code=\(code)".utf8)
        let confirmation = try await URLSession.shared.data(for: request)
        XCTAssertEqual((confirmation.1 as? HTTPURLResponse)?.statusCode, 200)
        let html = String(decoding: confirmation.0, as: UTF8.self)
        XCTAssertTrue(html.contains("Report ready"))
        XCTAssertTrue(html.contains("Download JSON"))
        let path = try XCTUnwrap(html.range(of: #"/download/[a-f0-9-]+"#, options: .regularExpression))
        let download = try await URLSession.shared.data(from: URL(string: base + String(html[path]))!)
        let response = try XCTUnwrap(download.1 as? HTTPURLResponse)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")
        XCTAssertTrue(response.value(forHTTPHeaderField: "Content-Disposition")?.contains("attachment") == true)
        XCTAssertEqual(Int(response.value(forHTTPHeaderField: "Content-Length") ?? ""), download.0.count)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Connection"), "close")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: download.0) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        // Enabling capture always records an intentional capture-start event first.
        XCTAssertEqual(events.count, 2)
        let details = events.compactMap { $0["detail"] as? String }
        XCTAssertTrue(details.contains("capture-start; identifiers stable only within this capture"))
        XCTAssertTrue(details.contains("sample-event"))
    }

    func testInvalidAuthenticationDoesNotExposeReport() async throws {
        inspector.setEnabled(true)
        inspector.record("test", "inspector", "private-event")
        server.start()
        let base = try await readyAddress()
        var request = URLRequest(url: URL(string: base + "/authenticate")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let wrongCode = server.code == "00000000" ? "00000001" : "00000000"
        request.httpBody = Data("code=\(wrongCode)".utf8)
        let response = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response.1 as? HTTPURLResponse)?.statusCode, 403)
        XCTAssertTrue(String(decoding: response.0, as: UTF8.self).contains("Incorrect access code"))
        XCTAssertFalse(String(decoding: response.0, as: UTF8.self).contains("private-event"))
    }

    func testEmptyCaptureStillDownloadsValidJSON() async throws {
        inspector.setEnabled(true)
        server.start()
        let base = try await readyAddress()
        var authentication = URLRequest(url: URL(string: base + "/authenticate")!)
        authentication.httpMethod = "POST"
        authentication.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        authentication.httpBody = Data("code=\(server.code)".utf8)
        let confirmation = try await URLSession.shared.data(for: authentication)
        let html = String(decoding: confirmation.0, as: UTF8.self)
        let path = try XCTUnwrap(html.range(of: #"/download/[a-f0-9-]+"#, options: .regularExpression))
        let download = try await URLSession.shared.data(from: URL(string: base + String(html[path]))!)
        XCTAssertEqual((download.1 as? HTTPURLResponse)?.statusCode, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: download.0) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        // No user events were recorded, but setEnabled(true) still emits capture-start.
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["detail"] as? String, "capture-start; identifiers stable only within this capture")
    }

    func testExpiredSessionReturnsGoneWithoutReportBytes() async throws {
        inspector.setEnabled(true)
        inspector.record("test", "inspector", "must-not-leak")
        server.start()
        let base = try await readyAddress()
        server.expireSession()
        var request = URLRequest(url: URL(string: base + "/authenticate")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("code=\(server.code)".utf8)
        let response = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response.1 as? HTTPURLResponse)?.statusCode, 410)
        XCTAssertTrue(String(decoding: response.0, as: UTF8.self).contains("sharing session expired"))
        XCTAssertFalse(String(decoding: response.0, as: UTF8.self).contains("must-not-leak"))
    }

    // MARK: Build 103: export after Stop, Start fresh, and backgrounding

    func testShareAfterStopCaptureServesTheStoppedCapture() async throws {
        inspector.setEnabled(true)
        inspector.record("test", "inspector", "before-stop")
        inspector.setEnabled(false)
        XCTAssertFalse(inspector.enabled)
        server.start()
        let json = try await downloadReport()
        let details = try XCTUnwrap(json["events"] as? [[String: Any]]).compactMap { $0["detail"] as? String }
        XCTAssertTrue(details.contains("before-stop"), "a stopped capture stays exportable")
        XCTAssertTrue(details.contains("capture-stop"))
        XCTAssertEqual(json["state"] as? String, "stopped")
    }

    func testStartFreshCaptureKeepsThePreviousCaptureShareable() async throws {
        inspector.setEnabled(true)
        inspector.record("test", "inspector", "earlier-failure")
        inspector.setEnabled(false)
        inspector.setEnabled(true) // Start fresh capture.
        XCTAssertGreaterThan(inspector.exportableEventCount(.previous), 0)
        server.start(.previous)
        let json = try await downloadReport()
        let details = try XCTUnwrap(json["events"] as? [[String: Any]]).compactMap { $0["detail"] as? String }
        XCTAssertTrue(details.contains("earlier-failure"), "a fresh start never destroys the replaced capture")
    }

    func testSavedCaptureSurvivesARelaunchAndExportsWithoutCapturing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TVFocusInspectorRelaunch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = TVRemoteFocusInspector(store: TVFocusCaptureStore(directory: directory))
        first.setEnabled(true)
        first.record("test", "inspector", "before-relaunch")
        first.setEnabled(false)
        // A second instance over the same directory stands in for the next launch.
        let relaunched = TVRemoteFocusInspector(store: TVFocusCaptureStore(directory: directory))
        XCTAssertFalse(relaunched.enabled)
        XCTAssertTrue(relaunched.hasExportableCapture)
        let data = try XCTUnwrap(relaunched.report(.latest))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("before-relaunch"))
        XCTAssertFalse(relaunched.enabled, "exporting never starts or resets a capture")
    }

    func testBackgroundingStopsCaptureAndSharingButKeepsTheCapture() async throws {
        inspector.setEnabled(true)
        inspector.record("test", "inspector", "kept-across-background")
        server.start()
        _ = try await readyAddress()
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        for _ in 0..<20 where inspector.enabled || !server.address.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(inspector.enabled)
        XCTAssertTrue(server.address.isEmpty, "sharing is foreground-only")
        let data = try XCTUnwrap(inspector.report(.latest))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("kept-across-background"))
    }

    func testPlayPauseHoldIsOfferedOnlyOutsidePlaybackAndPresentations() {
        XCTAssertTrue(tvDiagnosticExportHoldIsEligible(presentsController: false, liveTVPlaybackActive: false,
                                                       videoPlayerMounted: false))
        XCTAssertFalse(tvDiagnosticExportHoldIsEligible(presentsController: true, liveTVPlaybackActive: false,
                                                        videoPlayerMounted: false), "covers, sheets, Guide")
        XCTAssertFalse(tvDiagnosticExportHoldIsEligible(presentsController: false, liveTVPlaybackActive: true,
                                                        videoPlayerMounted: false), "inline Live TV and PiP")
        XCTAssertFalse(tvDiagnosticExportHoldIsEligible(presentsController: false, liveTVPlaybackActive: false,
                                                        videoPlayerMounted: true), "pushed player route")
    }

    private func downloadReport() async throws -> [String: Any] {
        let base = try await readyAddress()
        var authentication = URLRequest(url: URL(string: base + "/authenticate")!)
        authentication.httpMethod = "POST"
        authentication.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        authentication.httpBody = Data("code=\(server.code)".utf8)
        let confirmation = try await URLSession.shared.data(for: authentication)
        let html = String(decoding: confirmation.0, as: UTF8.self)
        let path = try XCTUnwrap(html.range(of: #"/download/[a-f0-9-]+"#, options: .regularExpression))
        let download = try await URLSession.shared.data(from: URL(string: base + String(html[path]))!)
        XCTAssertEqual((download.1 as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: download.0) as? [String: Any])
    }

    private func readyAddress() async throws -> String {
        for _ in 0..<100 {
            if !server.address.isEmpty { return server.address }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("LAN report listener did not become ready: \(server.status)")
        throw NSError(domain: "TVFocusReportServerTests", code: 1)
    }
}
#endif
