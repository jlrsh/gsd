import Foundation
import SwiftSoup

/// Python string semantics that the Python app relies on implicitly.  Keys are
/// hashed from cleaned text, so these must match CPython byte-for-byte.
enum Py {
    /// `str.isspace()` for one scalar.
    static func isSpace(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    /// `str.split()` with no separator: runs of whitespace, no empty pieces.
    static func split(_ s: String) -> [String] {
        var out: [String] = []
        var buf = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if isSpace(u) {
                if !buf.isEmpty { out.append(String(buf)); buf = .init() }
            } else {
                buf.append(u)
            }
        }
        if !buf.isEmpty { out.append(String(buf)) }
        return out
    }

    /// `" ".join(s.split())`
    static func collapse(_ s: String) -> String { split(s).joined(separator: " ") }

    /// `str.strip()`
    static func strip(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        var lo = 0, hi = scalars.count
        while lo < hi, isSpace(scalars[lo]) { lo += 1 }
        while hi > lo, isSpace(scalars[hi - 1]) { hi -= 1 }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[lo..<hi])
        return String(view)
    }

    /// Python orders strings by code point; Swift's `<` does not.
    static func less(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars)
    }

    static func lower(_ s: String) -> String { s.lowercased() }

    /// `str.isprintable()` for one scalar.
    static func isPrintable(_ u: Unicode.Scalar) -> Bool {
        if u == " " { return true }
        switch u.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned,
             .lineSeparator, .paragraphSeparator, .spaceSeparator:
            return false
        default:
            return true
        }
    }

    /// `repr(str)` for the characters that realistically appear in ICS values.
    static func repr(_ s: String) -> String {
        let quote: Character = (s.contains("'") && !s.contains("\"")) ? "\"" : "'"
        var out = String(quote)
        for u in s.unicodeScalars {
            switch u {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if Character(u) == quote {
                    out += "\\" + String(quote)
                } else if isPrintable(u) {
                    out.unicodeScalars.append(u)
                } else if u.value < 0x100 {
                    out += String(format: "\\x%02x", u.value)
                } else if u.value < 0x10000 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out += String(format: "\\U%08x", u.value)
                }
            }
        }
        out.append(quote)
        return out
    }
}

/// CPython's `html.unescape`, entity table from SwiftSoup (the HTML5 set).
enum HTMLEntities {
    private static let invalidCharrefs: [UInt32: String] = [
        0x00: "\u{FFFD}", 0x0D: "\r", 0x80: "\u{20AC}", 0x81: "\u{81}", 0x82: "\u{201A}",
        0x83: "\u{0192}", 0x84: "\u{201E}", 0x85: "\u{2026}", 0x86: "\u{2020}", 0x87: "\u{2021}",
        0x88: "\u{02C6}", 0x89: "\u{2030}", 0x8A: "\u{0160}", 0x8B: "\u{2039}", 0x8C: "\u{0152}",
        0x8D: "\u{8D}", 0x8E: "\u{017D}", 0x8F: "\u{8F}", 0x90: "\u{90}", 0x91: "\u{2018}",
        0x92: "\u{2019}", 0x93: "\u{201C}", 0x94: "\u{201D}", 0x95: "\u{2022}", 0x96: "\u{2013}",
        0x97: "\u{2014}", 0x98: "\u{02DC}", 0x99: "\u{2122}", 0x9A: "\u{0161}", 0x9B: "\u{203A}",
        0x9C: "\u{0153}", 0x9D: "\u{9D}", 0x9E: "\u{017E}", 0x9F: "\u{0178}",
    ]

    private static func isInvalidCodepoint(_ n: UInt32) -> Bool {
        if (0x1...0x8).contains(n) || (0xE...0x1F).contains(n) || (0x7F...0x9F).contains(n)
            || (0xFDD0...0xFDEF).contains(n) || n == 0xB {
            return true
        }
        return (n & 0xFFFE) == 0xFFFE && n <= 0x10FFFF
    }

    /// html5[name] where `name` may end with ';' (full set) or not (legacy set).
    private static func lookup(_ name: [Unicode.Scalar]) -> String? {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: name)
        let s = String(view)
        if s.hasSuffix(";") {
            let bare = String(s.dropLast())
            guard !bare.isEmpty else { return nil }
            return Entities.getByName(name: bare)
        }
        guard !s.isEmpty, Entities.isBaseNamedEntity(ArraySlice(s.utf8)) else { return nil }
        return Entities.getByName(name: s)
    }

    private static func isHex(_ u: Unicode.Scalar) -> Bool {
        switch u { case "0"..."9", "a"..."f", "A"..."F": return true; default: return false }
    }

    private static func isDigit(_ u: Unicode.Scalar) -> Bool { ("0"..."9").contains(u) }

    static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let u = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < u.count {
            guard u[i] == "&" else { out.append(u[i]); i += 1; continue }
            let start = i + 1
            // Numeric: #[0-9]+;? or #[xX][0-9a-fA-F]+;?
            if start < u.count, u[start] == "#" {
                var j = start + 1
                var hex = false
                if j < u.count, u[j] == "x" || u[j] == "X" { hex = true; j += 1 }
                let digitsStart = j
                while j < u.count, hex ? isHex(u[j]) : isDigit(u[j]) { j += 1 }
                if j > digitsStart {
                    var digits = ""
                    digits.unicodeScalars.append(contentsOf: u[digitsStart..<j])
                    if j < u.count, u[j] == ";" { j += 1 }
                    // Python ints are unbounded; anything huge is > 0x10FFFF.
                    let num = UInt64(digits, radix: hex ? 16 : 10).map { min($0, 0x110000) } ?? 0x110000
                    let n = UInt32(num)
                    if let mapped = invalidCharrefs[n] {
                        out.append(contentsOf: mapped.unicodeScalars)
                    } else if (0xD800...0xDFFF).contains(n) || n > 0x10FFFF {
                        out.append("\u{FFFD}")
                    } else if !isInvalidCodepoint(n), let scalar = Unicode.Scalar(n) {
                        out.append(scalar)
                    }
                    i = j
                    continue
                }
                // "&#" followed by nothing numeric: the regex's third branch
                // excludes '#', so no match: emit '&' literally.
                out.append("&"); i += 1
                continue
            }
            // Named: [^\t\n\f <&#;]{1,32};?
            var j = start
            while j < u.count, j - start < 32 {
                let c = u[j]
                if c == "\t" || c == "\n" || c == "\u{0C}" || c == " " || c == "<" || c == "&" || c == "#" || c == ";" { break }
                j += 1
            }
            guard j > start else { out.append("&"); i += 1; continue }
            if j < u.count, u[j] == ";" { j += 1 }
            let name = Array(u[start..<j])
            if let full = lookup(name) {
                out.append(contentsOf: full.unicodeScalars)
            } else {
                var matched = false
                var x = name.count - 1
                while x > 1 {
                    if let got = lookup(Array(name[0..<x])) {
                        out.append(contentsOf: got.unicodeScalars)
                        out.append(contentsOf: name[x...])
                        matched = true
                        break
                    }
                    x -= 1
                }
                if !matched {
                    out.append("&")
                    out.append(contentsOf: name)
                }
            }
            i = j
        }
        return String(out)
    }
}

public enum GSDText {
    /// `gsd.ical.clean_text`: entities decoded, no controls, whitespace collapsed.
    public static func clean(_ value: String) -> String {
        let v = HTMLEntities.unescape(value)
        var view = String.UnicodeScalarView()
        for u in v.unicodeScalars {
            switch u.value {
            case 0x09, 0x0A: view.append(" ")
            case 0x00...0x08, 0x0B...0x1F, 0x7F: continue
            default: view.append(u)
            }
        }
        return Py.collapse(String(view))
    }

    /// `rel_time` from gsd/text.py.
    public static func relTime(_ then: Date?, now: Date = Date()) -> String {
        guard let then, then.timeIntervalSince1970 != 0 else { return "never" }
        let secs = max(0, Int(now.timeIntervalSince(then)))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }
}
