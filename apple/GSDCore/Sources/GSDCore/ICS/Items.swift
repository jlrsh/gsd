import Foundation
import CryptoKit

extension ICS {
    static let urlRegex = try! NSRegularExpression(pattern: #"https?://[^\s<>"'\)\]]+"#)
    static let linkTrailing: Set<Unicode.Scalar> = [".", ",", ";", ":", ")", "]", ">", "\"", "'"]

    /// Undo HTML entities repeatedly; Canvas double-encodes `&amp;amp;`.
    static func deepUnescape(_ text: String) -> String {
        var t = text
        for _ in 0..<3 {
            let next = HTMLEntities.unescape(t)
            if next == t { break }
            t = next
        }
        return t
    }

    /// First usable link: URL, then DESCRIPTION / X-ALT-DESC / LOCATION / ...
    static func link(_ comp: Component) -> String? {
        if let got = comp.first("URL") {
            let candidate = GSDText.clean(unescape(got.value))
            if candidate.hasPrefix("http://") || candidate.hasPrefix("https://") { return candidate }
        }
        for name in ["DESCRIPTION", "X-ALT-DESC", "LOCATION", "COMMENT", "ATTACH"] {
            for p in comp.all(name) {
                let text = deepUnescape(unescape(p.value))
                let ns = text as NSString
                if let m = urlRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                    return rstrip(ns.substring(with: m.range), linkTrailing)
                }
            }
        }
        return nil
    }

    /// DUE for a VTODO, else DTSTART (falling back to the other).
    static func componentDate(_ comp: Component, local: TimeZone) -> (WallTime, Bool)? {
        let order = comp.kind == "VTODO" ? ["DUE", "DTSTART"] : ["DTSTART", "DUE"]
        for name in order {
            if let got = comp.first(name), let parsed = parseDate(got.value, got.params, local: local) {
                return parsed
            }
        }
        return nil
    }

    /// EXDATE / RDATE: comma-separated, possibly repeated.
    static func dateSet(_ comp: Component, _ name: String, local: TimeZone) -> [WallTime] {
        comp.all(name).flatMap { p in
            p.value.split(separator: ",", omittingEmptySubsequences: false)
                .compactMap { parseDate(String($0), p.params, local: local)?.0 }
        }
    }

    /// Python repr of `first(comp, 'DTSTART')`: `({'VALUE': 'DATE'}, '20260905')`.
    static func reprFirst(_ comp: Component, _ name: String) -> String {
        guard let p = comp.first(name) else { return "None" }
        let dict = p.params.map { "\(Py.repr($0.key)): \(Py.repr($0.value))" }.joined(separator: ", ")
        return "({\(dict)}, \(Py.repr(p.value)))"
    }

    static func uid(_ comp: Component, fallback: String) -> String {
        let uid = comp.first("UID").map { GSDText.clean(unescape($0.value)) } ?? ""
        return uid.isEmpty ? Keys.sha1Hex(fallback) : uid
    }

    static func isCancelled(_ comp: Component) -> Bool {
        guard let s = comp.first("STATUS") else { return false }
        return Py.strip(s.value).uppercased() == "CANCELLED"
    }

    private struct OverrideKey: Hashable { var uid: String; var day: Day }

    /// `items_from_ics`: one .ics document to a flat list of Items.
    public static func items(_ text: String, source: String, horizonDays: Int, now: Date, zone local: TimeZone) -> [Item] {
        let comps = components(text)
        let hi = WallTime(instant: now, zone: local).addingDays(horizonDays).instant
        // Recurring series look back 30 days; one-offs a year, so a long
        // overdue assignment never silently disappears.
        let nowWall = WallTime(instant: now, zone: local)
        let recurLo = nowWall.addingDays(-30).instant
        let singleLo = nowWall.addingDays(-365).instant

        var overrides: [OverrideKey: Component] = [:]
        var bases: [Component] = []
        for comp in comps {
            if let rid = comp.first("RECURRENCE-ID") {
                guard let (dt, _) = parseDate(rid.value, rid.params, local: local) else { bases.append(comp); continue }
                overrides[OverrideKey(uid: uid(comp, fallback: ""), day: Clock.day(dt.instant, local))] = comp
            } else {
                bases.append(comp)
            }
        }

        var items: [Item] = []
        var seen = Set<String>()
        for comp in bases {
            if isCancelled(comp) { continue }
            var title = comp.first("SUMMARY").map { GSDText.clean(unescape($0.value)) } ?? ""
            if title.isEmpty { title = "(untitled)" }
            let uid = uid(comp, fallback: title + reprFirst(comp, "DTSTART"))

            guard let (dtstart, allDay) = componentDate(comp, local: local) else {
                // An undated VTODO is still a real task.
                if comp.kind == "VTODO" {
                    let key = Keys.ics(uid: uid, occurrence: nil)
                    if seen.insert(key).inserted {
                        items.append(Item(key: key, title: title, due: nil, allDay: true, link: link(comp), source: source))
                    }
                }
                continue
            }

            var occurrences: [WallTime]
            if let rrule = comp.first("RRULE") {
                occurrences = expand(dtstart, parseRRule(rrule.value), lo: recurLo, hi: hi, local: local)
            } else {
                occurrences = (singleLo <= dtstart.instant && dtstart.instant <= hi) ? [dtstart] : []
            }
            for extra in dateSet(comp, "RDATE", local: local) where singleLo <= extra.instant && extra.instant <= hi {
                occurrences.append(extra)
            }
            let skip = Set(dateSet(comp, "EXDATE", local: local).map { Clock.day($0.instant, local) })

            for occ in occurrences {
                let occDay = Clock.day(occ.instant, local)
                if skip.contains(occDay) { continue }
                // Key on the ORIGINAL occurrence so a check survives a move.
                let key = Keys.ics(uid: uid, occurrence: occ.instant)
                if seen.contains(key) { continue }
                var shownDate = occ.instant, shownAllDay = allDay
                var shownTitle = title, shownComp = comp
                if let src = overrides[OverrideKey(uid: uid, day: occDay)] {
                    if isCancelled(src) { continue }
                    if let (moved, movedAllDay) = componentDate(src, local: local) {
                        shownDate = moved.instant; shownAllDay = movedAllDay
                    }
                    if let osumm = src.first("SUMMARY") {
                        let t = GSDText.clean(unescape(osumm.value))
                        shownTitle = t.isEmpty ? title : t
                    }
                    shownComp = link(src) == nil ? comp : src  // inherit the series' link
                }
                seen.insert(key)
                items.append(Item(key: key, title: shownTitle, due: shownDate, allDay: shownAllDay,
                                  link: link(shownComp), source: source))
            }
        }
        return items
    }
}
