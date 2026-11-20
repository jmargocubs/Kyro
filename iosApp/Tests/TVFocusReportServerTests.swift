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
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["detail"] as? String, "sample-event")
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
        XCTAssertEqual(try XCTUnwrap(json["events"] as? [Any]).count, 0)
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
