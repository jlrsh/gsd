import Foundation

/// A tiny TOML reader for gsd's config.toml: tables, arrays of tables, and
/// string / integer / boolean values with comments.  Anything fancier is skipped.
public enum TOML {
    public enum Value: Equatable, Sendable {
        case string(String), int(Int), bool(Bool)
        public var string: String? { if case .string(let s) = self { return s }; return nil }
        public var int: Int? { if case .int(let i) = self { return i }; return nil }
        public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    }

    public typealias Table = [String: Value]

    public struct Document: Sendable {
        public var tables: [String: Table] = [:]
        public var arrays: [String: [Table]] = [:]
    }

    public static func parse(_ text: String) -> Document {
        var doc = Document()
        var current: (name: String, array: Bool)? = nil
        func assign(_ k: String, _ v: Value) {
            guard let current else { doc.tables["", default: [:]][k] = v; return }
            if current.array {
                var list = doc.arrays[current.name] ?? [[:]]
                list[list.count - 1][k] = v
                doc.arrays[current.name] = list
            } else {
                doc.tables[current.name, default: [:]][k] = v
            }
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = Py.strip(raw)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[[") {
                guard let end = line.range(of: "]]") else { continue }
                let name = Py.strip(String(line[line.index(line.startIndex, offsetBy: 2)..<end.lowerBound]))
                doc.arrays[name, default: []].append([:])
                current = (name, true)
                continue
            }
            if line.hasPrefix("[") {
                guard let end = line.firstIndex(of: "]") else { continue }
                let name = Py.strip(String(line[line.index(after: line.startIndex)..<end]))
                current = (name, false)
                if doc.tables[name] == nil { doc.tables[name] = [:] }
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            var key = Py.strip(String(line[..<eq]))
            if key.count >= 2, key.first == "\"", key.last == "\"" { key = String(key.dropFirst().dropLast()) }
            let rest = Py.strip(String(line[line.index(after: eq)...]))
            if let v = value(rest) { assign(key, v) }
        }
        return doc
    }

    static func value(_ s: String) -> Value? {
        let u = Array(s.unicodeScalars)
        guard let first = u.first else { return nil }
        if first == "\"" {
            var out = String.UnicodeScalarView()
            var i = 1
            while i < u.count {
                let c = u[i]
                if c == "\"" { return .string(String(out)) }
                if c == "\\", i + 1 < u.count {
                    let n = u[i + 1]
                    i += 2
                    switch n {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "b": out.append("\u{08}")
                    case "f": out.append("\u{0C}")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "u", "U":
                        let len = n == "u" ? 4 : 8
                        guard i + len <= u.count else { return nil }
                        var hex = ""; hex.unicodeScalars.append(contentsOf: u[i..<(i + len)])
                        guard let cp = UInt32(hex, radix: 16), let sc = Unicode.Scalar(cp) else { return nil }
                        out.append(sc)
                        i += len
                    default: return nil
                    }
                    continue
                }
                out.append(c)
                i += 1
            }
            return nil
        }
        if first == "'" {
            guard let close = u.dropFirst().firstIndex(of: "'") else { return nil }
            return .string(String(String.UnicodeScalarView(u[1..<close])))
        }
        let bare = Py.strip(s.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "")
        if bare == "true" { return .bool(true) }
        if bare == "false" { return .bool(false) }
        if let i = Int(bare.replacingOccurrences(of: "_", with: "")) { return .int(i) }
        return nil
    }
}
