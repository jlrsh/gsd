import Foundation

public struct FetchError: Error, CustomStringConvertible {
    public var description: String
    public init(_ d: String) { description = d }
}

/// Calendar feed download (`gsd.sources.fetch_text`), on a cookie-less session.
public enum FeedFetcher {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.httpAdditionalHeaders = [
            // Default agents get 403'd by the CDNs in front of some LMSes.
            "User-Agent": "gsd/1.0",
            "Accept": "text/calendar, text/plain, */*",
        ]
        return URLSession(configuration: config)
    }()

    public static func normalize(_ url: String) -> String {
        let u = Py.strip(url)
        for scheme in ["webcal://", "webcals://"] where u.lowercased().hasPrefix(scheme) {
            return "https://" + u.dropFirst(scheme.count)
        }
        return u
    }

    /// Returns decoded ICS text or throws a short, URL-free error.
    public static func fetch(_ url: String, timeout: TimeInterval) async throws -> String {
        guard let u = URL(string: normalize(url)), let scheme = u.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { throw FetchError("bad URL") }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: URLRequest(url: u, timeoutInterval: timeout))
        } catch let e as URLError {
            if e.code == .cancelled { throw CancellationError() }
            throw FetchError(short(e))
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw FetchError("HTTP \(http.statusCode)")
        }
        let text = ICS.decode(data)
        guard ICS.looksLikeCalendar(text) else { throw FetchError("not a calendar (login page?)") }
        return text
    }

    static func short(_ e: URLError) -> String {
        switch e.code {
        case .notConnectedToInternet: return "offline"
        case .timedOut: return "timed out"
        case .cannotFindHost, .dnsLookupFailed: return "host not found"
        case .cannotConnectToHost: return "connection refused"
        case .networkConnectionLost: return "connection lost"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid: return "TLS error"
        default: return "network error \(e.code.rawValue)"
        }
    }

    /// Default display name: first label of the host (`_feed_name_from_url`).
    public static func defaultName(_ url: String) -> String {
        let stripped = url.replacingOccurrences(of: #"^\w+://"#, with: "", options: .regularExpression)
        let host = stripped.split(separator: "/", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let first = host.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return first.isEmpty ? "feed" : first
    }
}
