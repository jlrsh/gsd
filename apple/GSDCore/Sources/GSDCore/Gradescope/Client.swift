import Foundation
import SwiftSoup

public enum GradescopeError: Error, Equatable, CustomStringConvertible {
    case auth(String)
    case botCheck
    case failure(String)

    public var description: String {
        switch self {
        case .auth(let m), .failure(let m): return m
        case .botCheck: return "Gradescope presented a bot check; import browser cookies"
        }
    }

    var isFatal: Bool {
        switch self { case .auth, .botCheck: return true; case .failure: return false }
    }
}

/// A logged-in Gradescope session (`gsd.plugins.gradescope.Session`).
/// Cookies live in this session's private in-memory store; callers persist
/// them with `cookies` (session cookies included, like `ignore_discard`).
public final class GradescopeClient: @unchecked Sendable {
    public static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
    static let botMarkers = [
        "just a moment", "cf-browser-verification", "cf_chl_opt", "attention required! | cloudflare",
        "enable javascript and cookies to continue", "checking if the site connection is secure",
    ]

    let session: URLSession
    let store: HTTPCookieStorage
    let timeout: TimeInterval

    /// `userAgent` should match the browser that created the cookies:
    /// Cloudflare ties its clearance cookie to the agent string.
    public init(cookies: [HTTPCookie], timeout: TimeInterval = 25, userAgent: String? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = timeout
        config.httpAdditionalHeaders = [
            "User-Agent": userAgent ?? GradescopeClient.userAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
        ]
        store = config.httpCookieStorage!
        for c in cookies { store.setCookie(c) }
        session = URLSession(configuration: config)
        self.timeout = timeout
    }

    deinit { session.invalidateAndCancel() }

    public var cookies: [HTTPCookie] { store.cookies ?? [] }

    static func looksLikeBotCheck(_ html: String, _ response: HTTPURLResponse?) -> Bool {
        let lowered = String(html.prefix(4000)).lowercased()
        if botMarkers.contains(where: lowered.contains) { return true }
        return response?.value(forHTTPHeaderField: "cf-mitigated").map { !$0.isEmpty } ?? false
    }

    func open(_ request: URLRequest, attempts: Int = 3) async throws -> (URL, String) {
        var delay: Double = 1
        for attempt in 0..<attempts {
            let last = attempt + 1 >= attempts
            do {
                let (data, response) = try await session.data(for: request)
                let http = response as? HTTPURLResponse
                let body = String(decoding: data, as: UTF8.self)
                if GradescopeClient.looksLikeBotCheck(body, http) { throw GradescopeError.botCheck }
                let code = http?.statusCode ?? 200
                if code >= 400 {
                    if [408, 429, 500, 502, 503, 504].contains(code) && !last {
                        try await Task.sleep(nanoseconds: UInt64((delay + Double.random(in: 0...(delay / 2))) * 1e9))
                        delay *= 2
                        continue
                    }
                    throw GradescopeError.failure("Gradescope returned HTTP \(code)")
                }
                return (response.url ?? request.url!, body)
            } catch let error as GradescopeError {
                throw error
            } catch let error as URLError {
                if [.serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                    .serverCertificateHasUnknownRoot, .secureConnectionFailed].contains(error.code) {
                    throw GradescopeError.failure("TLS certificate verification failed")
                }
                if error.code == .cancelled { throw CancellationError() }
                if !last {
                    try await Task.sleep(nanoseconds: UInt64((delay + Double.random(in: 0...(delay / 2))) * 1e9))
                    delay *= 2
                    continue
                }
                throw GradescopeError.failure("could not reach Gradescope")
            }
        }
        throw GradescopeError.failure("could not reach Gradescope")
    }

    func get(_ url: String) async throws -> (URL, String) {
        try await open(URLRequest(url: URL(string: url)!, timeoutInterval: timeout))
    }

    func post(_ url: String, _ fields: [(String, String)]) async throws -> (URL, String) {
        // fields carry the password: never include them in errors or logs.
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(url, forHTTPHeaderField: "Referer")
        request.httpBody = Data(GradescopeClient.urlencode(fields).utf8)
        return try await open(request)
    }

    /// `urllib.parse.urlencode` (quote_plus).
    static func urlencode(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        allowed.insert(charactersIn: "_.-~ ")
        func q(_ s: String) -> String {
            (s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s).replacingOccurrences(of: " ", with: "+")
        }
        return fields.map { q($0.0) + "=" + q($0.1) }.joined(separator: "&")
    }

    static func isLogin(_ url: URL, _ html: String) -> Bool {
        if html.contains("name=\"session[email]\"") { return true }
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        return path == "/login"
    }

    public func login(email: String, password: String) async throws {
        let (_, html) = try await get("\(Gradescope.base)/login")
        let doc = try SwiftSoup.parse(html)
        guard let token = try doc.select("input[name=\"authenticity_token\"]").first() else {
            throw GradescopeError.auth("Gradescope login form was not found")
        }
        let (url, body) = try await post("\(Gradescope.base)/login", [
            ("utf8", "✓"),
            ("authenticity_token", (try? token.attr("value")) ?? ""),
            ("session[email]", email),
            ("session[password]", password),
            ("session[remember_me]", "1"),
            ("commit", "Log In"),
            ("session[remember_me_sso]", "0"),
        ])
        if GradescopeClient.isLogin(url, body) { throw GradescopeError.auth("Gradescope rejected that email/password") }
    }

    /// Reuse the cookie session when it is still good; otherwise log in.
    public func ensureLogin(email: String, password: () -> String?) async throws {
        do {
            let (url, html) = try await get("\(Gradescope.base)/")
            if !GradescopeClient.isLogin(url, html) { return }
        } catch GradescopeError.botCheck {
            throw GradescopeError.botCheck
        } catch let e as GradescopeError {
            _ = e
        }
        guard !email.isEmpty, let pw = password(), !pw.isEmpty else {
            throw GradescopeError.auth("logged out; log in again in Settings")
        }
        try await login(email: email, password: pw)
    }

    /// True when the cookie session reaches the dashboard.
    public func isLoggedIn() async throws -> Bool {
        let (url, html) = try await get("\(Gradescope.base)/")
        return !GradescopeClient.isLogin(url, html)
    }

    func page(_ url: String) async throws -> String {
        let (final, html) = try await get(url)
        if GradescopeClient.isLogin(final, html) { throw GradescopeError.auth("Gradescope session expired") }
        return html
    }

    public struct Options: Sendable {
        public var email: String
        public var allTerms = false
        public var skipSubmitted = false
        public var horizonDays = 120
        public init(email: String, allTerms: Bool = false, skipSubmitted: Bool = false, horizonDays: Int = 120) {
            self.email = email; self.allTerms = allTerms; self.skipSubmitted = skipSubmitted; self.horizonDays = horizonDays
        }
    }

    /// A complete, healthy scrape, or a throw so the caller keeps its old snapshot.
    public func fetch(_ options: Options, password: () -> String?, now: Date = Date()) async throws -> [Gradescope.Row] {
        try await ensureLogin(email: options.email, password: password)
        let courses = try Gradescope.parseCourses(try await page("\(Gradescope.base)/"), allTerms: options.allTerms)
        if courses.isEmpty { throw GradescopeError.failure("no courses found on the Gradescope dashboard") }

        var failures = 0
        var byIndex: [Int: [Gradescope.Row]] = [:]
        // Three at a time, like the Python ThreadPoolExecutor(max_workers=3).
        try await withThrowingTaskGroup(of: (Int, [Gradescope.Row]?).self) { group in
            var next = 0
            func add() {
                guard next < courses.count else { return }
                let i = next, course = courses[i]
                next += 1
                group.addTask {
                    do {
                        return (i, try Gradescope.parseAssignments(try await self.page(course.url), course: course))
                    } catch let e as GradescopeError where e.isFatal {
                        throw e
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (i, nil)
                    }
                }
            }
            for _ in 0..<3 { add() }
            while let (i, rows) = try await group.next() {
                if let rows { byIndex[i] = rows } else { failures += 1 }
                add()
            }
        }
        if failures > 0 { throw GradescopeError.failure("\(failures) course(s) failed; kept previous cache") }

        let floor = now.addingTimeInterval(-365 * 86400), ceiling = now.addingTimeInterval(Double(options.horizonDays) * 86400)
        let rows = courses.indices.flatMap { byIndex[$0] ?? [] }
        let kept = rows.filter { row in
            guard let due = ISODate.parse(row.dueISO.replacingOccurrences(of: "Z", with: "+00:00"))?.date(naiveZone: .utc) else { return false }
            return floor <= due && due <= ceiling && !(options.skipSubmitted && Gradescope.isSubmitted(row.status))
        }
        return kept.stableSorted { Py.less($0.dueISO, $1.dueISO) }
    }
}

/// Cookie persistence as a property-list blob (stored in the Keychain).
public enum CookieJar {
    public static func encode(_ cookies: [HTTPCookie]) -> Data? {
        let props: [[String: Any]] = cookies.compactMap { c in
            c.properties.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) }
        }
        return try? PropertyListSerialization.data(fromPropertyList: props, format: .binary, options: 0)
    }

    public static func decode(_ data: Data?) -> [HTTPCookie] {
        guard let data,
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            HTTPCookie(properties: Dictionary(uniqueKeysWithValues: d.map { (HTTPCookiePropertyKey($0.key), $0.value) }))
        }
    }

    /// Netscape / Mozilla cookies.txt (what the Python app saves).
    public static func parseNetscape(_ text: String) -> [HTTPCookie] {
        var out: [HTTPCookie] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw
            var httpOnly = false
            if line.hasPrefix("#HttpOnly_") { line.removeFirst("#HttpOnly_".count); httpOnly = true }
            if line.isEmpty || line.hasPrefix("#") { continue }
            let f = line.components(separatedBy: "\t")
            guard f.count >= 7 else { continue }
            var props: [HTTPCookiePropertyKey: Any] = [
                .domain: f[0], .path: f[2], .name: f[5], .value: f[6],
            ]
            if f[3].uppercased() == "TRUE" { props[.secure] = "TRUE" }
            if let exp = TimeInterval(f[4]), exp > 0 { props[.expires] = Date(timeIntervalSince1970: exp) }
            if httpOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let c = HTTPCookie(properties: props) { out.append(c) }
        }
        return out
    }
}
