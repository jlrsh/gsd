import Compression
import Foundation

extension ICS {
    /// Windows / Exchange TZIDs that zoneinfo rejects outright.
    static let windowsZones: [String: String] = [
        "eastern standard time": "America/New_York",
        "central standard time": "America/Chicago",
        "mountain standard time": "America/Denver",
        "pacific standard time": "America/Los_Angeles",
        "us mountain standard time": "America/Phoenix",
        "alaskan standard time": "America/Anchorage",
        "hawaiian standard time": "Pacific/Honolulu",
        "gmt standard time": "Europe/London",
        "w. europe standard time": "Europe/Berlin",
        "central europe standard time": "Europe/Budapest",
        "romance standard time": "Europe/Paris",
        "india standard time": "Asia/Kolkata",
        "china standard time": "Asia/Shanghai",
        "tokyo standard time": "Asia/Tokyo",
        "aus eastern standard time": "Australia/Sydney",
    ]

    /// An IANA zone like `ZoneInfo(name)`: Foundation also invents zones for
    /// "GMT+5"-style strings, which zoneinfo would reject.
    public static func ianaZone(_ name: String) -> TimeZone? {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.hasSuffix("/") else { return nil }
        if name.range(of: #"^(GMT|UTC)[+-]"#, options: .regularExpression) != nil { return nil }
        return TimeZone(identifier: name)
    }

    /// Resolve a TZID; unknown names fall back to the local zone.
    static func zone(for tzid: String?, local: TimeZone) -> TimeZone {
        guard let tzid, !tzid.isEmpty else { return local }
        let id = strip(Py.strip(tzid), ["\""])
        var candidates = [id]
        if id.hasPrefix("/") {
            // /mozilla.org/20070129_1/America/New_York -> America/New_York
            let parts = id.split(separator: "/").map(String.init)
            for i in parts.indices { candidates.append(parts[i...].joined(separator: "/")) }
        }
        if let mapped = windowsZones[id.lowercased()] { candidates.insert(mapped, at: 0) }
        for c in candidates { if let z = ianaZone(c) { return z } }
        return local
    }

    private static func digits(_ s: Substring) -> Int? {
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(s)
    }

    /// `parse_dt`: (datetime, all_day), or nil where Python raises ValueError.
    public static func parseDate(_ value: String, _ params: [(key: String, value: String)], local: TimeZone) -> (WallTime, Bool)? {
        let v = Py.strip(value)
        guard !v.isEmpty else { return nil }
        let isDateParam = params.last(where: { $0.key == "VALUE" })?.value == "DATE"
        if isDateParam || (v.count == 8 && v.allSatisfy { $0.isNumber }) {
            let s = Substring(v).prefix(8)
            guard s.count == 8, let y = digits(s.prefix(4)), let m = digits(s.dropFirst(4).prefix(2)),
                  let d = digits(s.dropFirst(6).prefix(2)), let day = Day(valid: y, m, d) else { return nil }
            return (WallTime(day, zone: local), true)
        }
        var body = Substring(v)
        var zone: TimeZone
        if body.hasSuffix("Z") {
            body = body.dropLast()
            zone = .utc
        } else {
            zone = self.zone(for: params.last(where: { $0.key == "TZID" })?.value, local: local)
        }
        guard body.count == 15, body[body.index(body.startIndex, offsetBy: 8)] == "T",
              let y = digits(body.prefix(4)), let mo = digits(body.dropFirst(4).prefix(2)),
              let d = digits(body.dropFirst(6).prefix(2)), let h = digits(body.dropFirst(9).prefix(2)),
              let mi = digits(body.dropFirst(11).prefix(2)), let se = digits(body.dropFirst(13).prefix(2)),
              let day = Day(valid: y, mo, d), h < 24, mi < 60, se < 60 else { return nil }
        if zone.identifier == "GMT" { zone = .utc }
        return (WallTime(day, h, mi, se, zone: zone), false)
    }
}

enum Gzip {
    /// Strip the gzip wrapper and inflate the raw DEFLATE body.
    static func decompress(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 {  // FEXTRA
            guard i + 2 <= b.count else { return nil }
            i += 2 + Int(b[i]) + Int(b[i + 1]) << 8
        }
        if flags & 0x08 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }  // FNAME
        if flags & 0x10 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }  // FCOMMENT
        if flags & 0x02 != 0 { i += 2 }  // FHCRC
        guard i < b.count - 8 else { return nil }
        let body = Data(b[i..<(b.count - 8)])
        return inflate(body)
    }

    private static func inflate(_ input: Data) -> Data? {
        var out = Data()
        let chunk = 1 << 16
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        var stream = compression_stream(dst_ptr: dst, dst_size: 0, src_ptr: dst, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&stream) }
        return input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            stream.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = src.count
            while true {
                stream.dst_ptr = dst
                stream.dst_size = chunk
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                out.append(dst, count: chunk - stream.dst_size)
                switch status {
                case COMPRESSION_STATUS_END: return out
                case COMPRESSION_STATUS_OK: continue
                default: return nil
                }
            }
        }
    }
}
