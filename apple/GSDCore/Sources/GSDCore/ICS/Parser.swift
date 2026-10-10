import Foundation

/// RFC 5545 content-line parsing (`gsd/ical.py`).
public enum ICS {
    public struct Prop: Sendable {
        public var params: [(key: String, value: String)]
        public var value: String

        public func param(_ name: String) -> String? {
            // Python dict: a repeated parameter keeps the last value.
            params.last { $0.key == name }?.value
        }
    }

    public struct Component: Sendable {
        public var kind: String
        public var props: [String: [Prop]] = [:]
        public func first(_ name: String) -> Prop? { props[name]?.first }
        public func all(_ name: String) -> [Prop] { props[name] ?? [] }
    }

    /// Byte-level unfold, then decode.  A fold can split a multi-byte
    /// character, and utf-8-sig strips a BOM.
    public static func decode(_ raw: Data) -> String {
        var bytes = [UInt8](raw)
        if bytes.count >= 2, bytes[0] == 0x1F, bytes[1] == 0x8B, let inflated = Gzip.decompress(raw) {
            bytes = [UInt8](inflated)
        }
        for fold: [UInt8] in [[13, 10, 32], [13, 10, 9], [10, 32], [10, 9], [13, 32], [13, 9]] {
            bytes = replace(bytes, fold)
        }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func replace(_ b: [UInt8], _ pat: [UInt8]) -> [UInt8] {
        guard b.count >= pat.count else { return b }
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var i = 0
        let n = pat.count
        while i < b.count {
            if b[i] == pat[0], i + n <= b.count, b[i..<(i + n)].elementsEqual(pat) {
                i += n
            } else {
                out.append(b[i]); i += 1
            }
        }
        return out
    }

    /// Reject login pages and error HTML before they replace a good cache.
    public static func looksLikeCalendar(_ text: String) -> Bool {
        let head = String(Py.strip(text).prefix(400)).lowercased()
        if head.hasPrefix("<!doctype") || head.hasPrefix("<html") || head.hasPrefix("<?xml") {
            return false
        }
        return String(text.prefix(4096)).lowercased().contains("begin:vcalendar")
    }

    static func unfold(_ text: String) -> [String] {
        let t = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        for raw in t.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            if let c = raw.first, c == " " || c == "\t", !lines.isEmpty {
                lines[lines.count - 1].unicodeScalars.append(contentsOf: raw.dropFirst())
            } else {
                lines.append(String(String.UnicodeScalarView(raw)))
            }
        }
        return lines
    }

    private static func splitSemis(_ head: Substring.UnicodeScalarView) -> [String] {
        var parts: [String] = []
        var buf = String.UnicodeScalarView()
        var quoted = false
        for ch in head {
            if ch == "\"" {
                quoted.toggle(); buf.append(ch)
            } else if ch == ";" && !quoted {
                parts.append(String(buf)); buf = .init()
            } else {
                buf.append(ch)
            }
        }
        parts.append(String(buf))
        return parts
    }

    /// `NAME;PARAM=VAL:VALUE` -> (name, params, value).
    public static func splitLine(_ line: String) -> (name: String, params: [(key: String, value: String)], value: String)? {
        let s = Substring(line).unicodeScalars
        var quoted = false
        var colon: Substring.UnicodeScalarView.Index?
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch == "\"" { quoted.toggle() } else if ch == ":" && !quoted { colon = i; break }
            i = s.index(after: i)
        }
        guard let colon else { return nil }
        let head = s[s.startIndex..<colon]
        let value = String(String.UnicodeScalarView(s[s.index(after: colon)...]))
        let parts = splitSemis(head)
        let name = Py.strip(parts[0]).uppercased()
        guard !name.isEmpty else { return nil }
        var params: [(key: String, value: String)] = []
        for p in parts.dropFirst() {
            guard let eq = p.firstIndex(of: "=") else { continue }
            let k = Py.strip(String(p[..<eq])).uppercased()
            var v = Py.strip(String(p[p.index(after: eq)...]))
            v = strip(v, ["\""])
            if let idx = params.firstIndex(where: { $0.key == k }) {
                params[idx].value = v  // dict assignment keeps the key's position
            } else {
                params.append((k, v))
            }
        }
        return (name, params, value)
    }

    /// Python `str.strip(chars)`.
    static func strip(_ s: String, _ chars: Set<Unicode.Scalar>) -> String {
        var u = Array(s.unicodeScalars)
        while let f = u.first, chars.contains(f) { u.removeFirst() }
        while let l = u.last, chars.contains(l) { u.removeLast() }
        return String(String.UnicodeScalarView(u))
    }

    static func rstrip(_ s: String, _ chars: Set<Unicode.Scalar>) -> String {
        var u = Array(s.unicodeScalars)
        while let l = u.last, chars.contains(l) { u.removeLast() }
        return String(String.UnicodeScalarView(u))
    }

    public static func unescape(_ value: String) -> String {
        let u = Array(value.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < u.count {
            if u[i] == "\\", i + 1 < u.count {
                switch u[i + 1] {
                case "n", "N": out.append("\n")
                default: out.append(u[i + 1])
                }
                i += 2
            } else {
                out.append(u[i]); i += 1
            }
        }
        return String(out)
    }

    /// VEVENT / VTODO blocks, properties harvested only at their own depth so
    /// a nested VALARM or VTIMEZONE never leaks into the event.
    public static func components(_ text: String) -> [Component] {
        var stack: [String] = []
        var comps: [Component] = []
        var current: Component?
        var depth = -1
        for line in unfold(text) {
            if Py.strip(line).isEmpty { continue }
            guard let (name, params, value) = splitLine(line) else { continue }
            if name == "BEGIN" {
                let kind = Py.strip(value).uppercased()
                stack.append(kind)
                if (kind == "VEVENT" || kind == "VTODO") && current == nil {
                    current = Component(kind: kind)
                    depth = stack.count
                }
                continue
            }
            if name == "END" {
                let kind = Py.strip(value).uppercased()
                if let c = current, stack.count == depth, kind == c.kind {
                    comps.append(c)
                    current = nil
                    depth = -1
                }
                if stack.last == kind { stack.removeLast() }
                continue
            }
            guard current != nil, stack.count == depth else { continue }
            current!.props[name, default: []].append(Prop(params: params, value: value))
        }
        return comps
    }
}
