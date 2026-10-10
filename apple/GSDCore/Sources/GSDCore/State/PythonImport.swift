import Foundation

/// One-time import from the terminal app's `config.toml` / `state.json`
/// (plus, optionally, its Gradescope `cookies.txt` and `assignments.json`).
/// Stamps are deterministic (`at: 1`, or the completion time), so importing
/// the same files twice changes nothing and never overrides later edits.
public enum PythonImport {
    public static let by = "import"

    public struct Summary: Sendable, CustomStringConvertible {
        public var feeds = 0, settings = 0, manual = 0, completed = 0, checked = 0, gradescopeRows = 0, cookies = 0
        public var description: String {
            var bits: [String] = []
            if feeds > 0 { bits.append("\(feeds) feed\(feeds == 1 ? "" : "s")") }
            if settings > 0 { bits.append("\(settings) setting\(settings == 1 ? "" : "s")") }
            if manual > 0 { bits.append("\(manual) manual") }
            if completed > 0 { bits.append("\(completed) completed") }
            if checked > 0 { bits.append("\(checked) checked") }
            if gradescopeRows > 0 { bits.append("\(gradescopeRows) Gradescope rows") }
            if cookies > 0 { bits.append("Gradescope session") }
            return bits.isEmpty ? "nothing new" : "imported " + bits.joined(separator: ", ")
        }
    }

    /// Last-writer-wins guard: only apply when strictly newer than what's there.
    static func newer(_ at: Int64, than existing: Int64?) -> Bool { existing.map { at > $0 } ?? true }

    public static func importConfig(_ text: String, into doc: inout StateDoc, summary: inout Summary) {
        let toml = TOML.parse(text)
        for entry in toml.arrays["feed"] ?? [] {
            let url = Py.strip(entry["url"]?.string ?? "")
            guard !url.isEmpty else { continue }
            let id = Keys.feed(url: url)
            guard newer(1, than: doc.feeds[id]?.at) else { continue }
            let name = Py.strip(entry["name"]?.string ?? "")
            doc.feeds[id] = FeedEntry(at: 1, by: by, deleted: false, url: url,
                                      name: name.isEmpty ? FeedFetcher.defaultName(url) : name,
                                      enabled: entry["enabled"]?.bool != false)
            summary.feeds += 1
        }
        func put(_ key: String, _ v: SettingValue?) {
            guard let v, newer(1, than: doc.settings[key]?.at) else { return }
            doc.settings[key] = Setting(v: v, at: 1, by: by)
            summary.settings += 1
        }
        let settings = toml.tables["settings"] ?? [:]
        put(SettingKey.horizonDays, settings["horizon_days"]?.int.map(SettingValue.int))
        put(SettingKey.retentionDays, settings["retention_days"]?.int.map(SettingValue.int))
        put(SettingKey.fetchTimeout, settings["fetch_timeout"]?.int.map(SettingValue.int))
        put(SettingKey.timezone, settings["timezone"]?.string.map(SettingValue.string))
        if let grade = toml.tables["plugins.gradescope"] {
            put(SettingKey.gradescopeEnabled, .bool(grade["enabled"]?.bool == true))
            put(SettingKey.gradescopeEmail, grade["email"]?.string.map { .string(Py.strip($0)) })
            put(SettingKey.gradescopeAllTerms, .bool(grade["all_terms"]?.bool == true))
            put(SettingKey.gradescopeSkipSubmitted, .bool(grade["skip_submitted"]?.bool == true))
        }
    }

    public static func importState(_ data: Data, into doc: inout StateDoc, summary: inout Summary) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError("state.json is not an object")
        }
        let zone = doc.zone
        func snapshot(_ any: Any) -> Snapshot? {
            guard JSONSerialization.isValidJSONObject(any),
                  let d = try? JSONSerialization.data(withJSONObject: any) else { return nil }
            return try? JSONDecoder().decode(Snapshot.self, from: d)
        }
        for raw in root["manual"] as? [Any] ?? [] {
            guard var snap = snapshot(raw), snap.item(zone: zone) != nil else { continue }
            snap.manual = true
            guard newer(1, than: doc.manual[snap.key]?.at) else { continue }
            doc.manual[snap.key] = ManualEntry(at: 1, by: by, deleted: false, item: snap)
            summary.manual += 1
        }
        let completed = root["completed"] as? [String: Any] ?? [:]
        for (key, raw) in completed {
            guard var snap = snapshot(raw) else { continue }
            snap.key = key
            let completedAt = (raw as? [String: Any])?["completed_at"] as? String
            let at = completedAt.flatMap { ISODate.parse($0)?.date(naiveZone: zone) }.map(Clock.ms) ?? 1
            guard newer(at, than: doc.records[key]?.at) else { continue }
            doc.records[key] = Record(done: true, at: at, by: by, completedAt: completedAt,
                                      src: snap.manual ? "manual" : snap.source, due: snap.due, snap: snap)
            summary.completed += 1
        }
        for key in root["checked"] as? [String] ?? [] where completed[key] == nil {
            guard newer(1, than: doc.records[key]?.at) else { continue }
            doc.records[key] = Record(done: true, at: 1, by: by)
            summary.checked += 1
        }
    }

    /// The plugin's cached rows, so Gradescope shows up before the first fetch.
    public static func importGradescopeRows(_ data: Data, into doc: inout StateDoc, fetchedAt: Date?, summary: inout Summary) throws {
        let rows = try JSONDecoder().decode([Gradescope.Row].self, from: data)
        var snap = doc.sources[StateDoc.gradescopeSource] ?? SourceSnapshot()
        guard snap.rows == nil || (snap.fetchedAt ?? 0) < (fetchedAt.map(Clock.ms) ?? 0) else { return }
        snap.rows = rows
        snap.fetchedAt = fetchedAt.map(Clock.ms)
        doc.sources[StateDoc.gradescopeSource] = snap
        summary.gradescopeRows = rows.count
    }

    public enum Kind: Sendable { case config, state, cookies, gradescopeRows, calendar }

    /// Guess what a picked file is from its name, then its contents.
    public static func kind(name: String, data: Data) -> Kind? {
        let lower = name.lowercased()
        if lower.hasSuffix(".toml") { return .config }
        if lower.hasSuffix(".ics") { return .calendar }
        if lower.contains("cookie") { return .cookies }
        if lower.hasSuffix(".json") {
            let obj = try? JSONSerialization.jsonObject(with: data)
            if obj is [Any] { return .gradescopeRows }
            if obj is [String: Any] { return .state }
        }
        let text = String(decoding: data.prefix(4096), as: UTF8.self)
        if text.contains("Netscape HTTP Cookie File") || text.contains("gradescope.com\t") { return .cookies }
        if text.contains("[[feed]]") || text.contains("[settings]") { return .config }
        return nil
    }
}
