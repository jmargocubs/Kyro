import Foundation

protocol ESPNTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionESPNTransport: ESPNTransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw KyroSportsDataError.malformedResponse
            }
            return (data, http)
        } catch is CancellationError {
            throw KyroSportsDataError.cancelled
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw KyroSportsDataError.cancelled
            case .timedOut: throw KyroSportsDataError.timedOut
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                throw KyroSportsDataError.offline
            default: throw KyroSportsDataError.offline
            }
        }
    }
}

enum ESPNCachePolicy: Sendable {
    /// Full-year NFL schedule responses are roughly 3 MB. They are refreshed
    /// infrequently; the small current-day scoreboard overlays live changes.
    case schedule
    /// A selected day's scoreboard is the only response used for live polling.
    case liveScoreboard

    var maxAge: TimeInterval {
        switch self {
        case .schedule: 6 * 3600
        case .liveScoreboard: 20
        }
    }

    var staleIfErrorGrace: TimeInterval {
        switch self {
        case .schedule: 24 * 3600
        case .liveScoreboard: 15 * 60
        }
    }
}

struct ESPNScoreboardPayload: Sendable {
    let response: ESPNScoreboardResponse
    let refreshError: KyroSportsDataError?
}

/// ESPN transport, validated decoding, caching, ETag revalidation, and
/// duplicate-request coalescing. The actor keeps concurrent page loads from
/// starting the same request twice; response bytes are decoded before they can
/// enter the cache.
actor ESPNAPIClient {
    private struct Entry: Sendable {
        let response: ESPNScoreboardResponse
        let etag: String?
        let storedAt: Date
    }

    private struct NetworkResult: Sendable {
        let response: ESPNScoreboardResponse
        let etag: String?
    }

    private let baseURL: URL
    private let transport: any ESPNTransport
    private let timeout: TimeInterval
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<NetworkResult, Error>] = [:]

    init(
        baseURL: URL = URL(string: "https://site.api.espn.com")!,
        transport: any ESPNTransport = URLSessionESPNTransport(),
        timeout: TimeInterval = 12,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.timeout = timeout
        self.now = now
    }

    func fetchScoreboard(
        league: KyroSportLeague,
        dates: String,
        policy: ESPNCachePolicy,
        ignoreFreshness: Bool = false
    ) async throws -> ESPNScoreboardPayload {
        let key = cacheKey(league: league, dates: dates)
        let currentDate = now()
        let stored = entries[key]
        if !ignoreFreshness, let stored,
           currentDate.timeIntervalSince(stored.storedAt) < policy.maxAge {
            return ESPNScoreboardPayload(response: stored.response, refreshError: nil)
        }

        if let existing = inFlight[key] {
            do {
                let result = try await withTaskCancellationHandler {
                    try await existing.value
                } onCancel: {
                    existing.cancel()
                }
                return ESPNScoreboardPayload(response: result.response, refreshError: nil)
            } catch {
                if let stale = stalePayload(stored, policy: policy, at: currentDate, error: error) {
                    return stale
                }
                throw normalize(error)
            }
        }

        let request = try makeRequest(league: league, dates: dates, etag: stored?.etag)
        let transport = transport
        let task = Task<NetworkResult, Error> {
            let (data, response) = try await transport.send(request)
            try Task.checkCancellation()
            switch response.statusCode {
            case 200...299:
                let decoded: ESPNScoreboardResponse
                do {
                    decoded = try JSONDecoder().decode(ESPNScoreboardResponse.self, from: data)
                } catch {
                    throw KyroSportsDataError.malformedResponse
                }
                return NetworkResult(
                    response: decoded,
                    etag: response.value(forHTTPHeaderField: "ETag")
                )
            case 304:
                guard let stored else { throw KyroSportsDataError.malformedResponse }
                return NetworkResult(response: stored.response, etag: stored.etag)
            default:
                throw KyroSportsDataError.httpStatus(response.statusCode)
            }
        }
        inFlight[key] = task

        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            inFlight[key] = nil
            entries[key] = Entry(response: result.response, etag: result.etag, storedAt: now())
            return ESPNScoreboardPayload(response: result.response, refreshError: nil)
        } catch {
            inFlight[key] = nil
            if let stale = stalePayload(stored, policy: policy, at: currentDate, error: error) {
                return stale
            }
            throw normalize(error)
        }
    }

    func removeAllCachedResponses() {
        entries.removeAll()
    }

    func cachedResponseCount() -> Int { entries.count }

    private func makeRequest(
        league: KyroSportLeague,
        dates: String,
        etag: String?
    ) throws -> URLRequest {
        guard let endpoint = URL(string: ESPNMapping.path(for: league), relativeTo: baseURL),
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: true) else {
            throw KyroSportsDataError.malformedResponse
        }
        var items = [
            URLQueryItem(name: "dates", value: dates),
            URLQueryItem(name: "limit", value: league == .collegeFootball ? "500" : "1000")
        ]
        if league == .collegeFootball {
            // ESPN group 80 is FBS. Keeping it explicit avoids mixing FCS and
            // lower-division games into the future NCAA screen.
            items.append(URLQueryItem(name: "groups", value: "80"))
        }
        components.queryItems = items
        guard let url = components.url else { throw KyroSportsDataError.malformedResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return request
    }

    private func cacheKey(league: KyroSportLeague, dates: String) -> String {
        "\(league.rawValue)|\(dates)"
    }

    private func stalePayload(
        _ stored: Entry?,
        policy: ESPNCachePolicy,
        at currentDate: Date,
        error: Error
    ) -> ESPNScoreboardPayload? {
        let normalized = normalize(error)
        guard normalized != .cancelled, let stored else { return nil }
        let age = currentDate.timeIntervalSince(stored.storedAt)
        guard age < policy.maxAge + policy.staleIfErrorGrace else { return nil }
        return ESPNScoreboardPayload(response: stored.response, refreshError: normalized)
    }

    private func normalize(_ error: Error) -> KyroSportsDataError {
        if let error = error as? KyroSportsDataError { return error }
        if error is CancellationError { return .cancelled }
        return .offline
    }
}
