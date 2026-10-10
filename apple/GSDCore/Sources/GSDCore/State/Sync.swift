import Foundation

/// File-based sync through a shared folder (iCloud Drive, but any synced
/// folder works).  Each device writes its whole state to
/// `devices/<device-uuid>.json` and never touches anyone else's file, so the
/// file provider never sees conflicting edits.  Readers merge every key by
/// newest stamp (`at`, tie broken by device id).
public enum Sync {
    /// Peers silent this long are ignored: their tombstones may be GC'd already.
    public static let silentPeerDays = 90
    /// Skip fetching a source some device fetched this recently.
    public static let freshSeconds: TimeInterval = 600

    static let deviceFile = try! NSRegularExpression(pattern: #"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\.json$"#)

    static func isDeviceFile(_ name: String) -> Bool {
        deviceFile.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) != nil
    }

    // MARK: merge

    static func newer(_ a: (Int64, String), than b: (Int64, String)?) -> Bool {
        guard let b else { return true }
        return a.0 != b.0 ? a.0 > b.0 : a.1 > b.1
    }

    public struct MergeResult: Sendable {
        public var changed = false
        /// Peer ICS text to store for feeds whose newest fetch came from a peer.
        public var adoptedTexts: [String: String] = [:]
    }

    /// Merge peers into `local` in place.
    public static func merge(_ local: inout StateDoc, peers: [StateDoc], now: Date, lastSync: Date? = nil) -> MergeResult {
        var result = MergeResult()
        let silentCutoff = Clock.ms(now) - Int64(silentPeerDays) * 86_400_000
        let live = peers.filter { $0.device.id != local.device.id && $0.device.wrote >= silentCutoff }

        // Back after a long absence: whatever we saw at our last sync but no
        // peer lists any more was garbage-collected; don't resurrect it.
        if let lastSync, now.timeIntervalSince(lastSync) > Double(silentPeerDays) * 86400, !live.isEmpty {
            let seen = Clock.ms(lastSync)
            func prune<V>(_ map: inout [String: V], _ at: (V) -> Int64, _ peerHas: (StateDoc, String) -> Bool) {
                for (k, v) in map where at(v) <= seen && !live.contains(where: { peerHas($0, k) }) {
                    map[k] = nil
                    result.changed = true
                }
            }
            prune(&local.records, \.at) { $0.records[$1] != nil }
            prune(&local.manual, \.at) { $0.manual[$1] != nil }
            prune(&local.feeds, \.at) { $0.feeds[$1] != nil }
        }

        for peer in live {
            for (k, r) in peer.records where newer((r.at, r.by), than: local.records[k].map { ($0.at, $0.by) }) {
                local.records[k] = r
                result.changed = true
            }
            for (k, m) in peer.manual where newer((m.at, m.by), than: local.manual[k].map { ($0.at, $0.by) }) {
                local.manual[k] = m
                result.changed = true
            }
            for (k, f) in peer.feeds where newer((f.at, f.by), than: local.feeds[k].map { ($0.at, $0.by) }) {
                local.feeds[k] = f
                result.changed = true
            }
            for (k, s) in peer.settings where newer((s.at, s.by), than: local.settings[k].map { ($0.at, $0.by) }) {
                local.settings[k] = s
                result.changed = true
            }
            // Sources: newest successful fetch wins, whoever made it.
            for (id, snap) in peer.sources {
                guard let at = snap.fetchedAt, at > (local.sources[id]?.fetchedAt ?? 0) else { continue }
                if id != StateDoc.gradescopeSource {
                    guard let text = snap.text, local.feeds[id]?.deleted == false else { continue }
                    result.adoptedTexts[id] = text
                }
                local.sources[id] = SourceSnapshot(fetchedAt: at, error: nil, rows: snap.rows,
                                                   by: snap.by ?? peer.device.id, text: nil)
                result.changed = true
            }
        }
        return result
    }

    /// What this device publishes: its state, with only its own fetches.
    public static func publishable(_ doc: StateDoc, cachedText: (String) -> String?) -> StateDoc {
        var out = doc
        out.sources = [:]
        for (id, snap) in doc.sources where (snap.by ?? doc.device.id) == doc.device.id && snap.fetchedAt != nil {
            var s = snap
            s.error = nil
            s.by = doc.device.id
            if id != StateDoc.gradescopeSource {
                guard let text = cachedText(id) else { continue }
                s.text = text
            }
            out.sources[id] = s
        }
        return out
    }
}

/// The shared folder: `<root>/devices/<uuid>.json`.
public final class SyncFolder: @unchecked Sendable {
    public let root: URL
    var devices: URL { root.appendingPathComponent("devices", isDirectory: true) }
    var lastWritten: Data?

    public init(root: URL) { self.root = root }

    public struct Peer: Sendable, Hashable {
        public var id: String
        public var name: String
        public var platform: String
        public var wrote: Date
    }

    func withAccess<T>(_ body: () throws -> T) rethrows -> T {
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    /// Read every peer file, asking iCloud for any not downloaded yet.
    public func readPeers(excluding me: String) -> [StateDoc] {
        withAccess {
            let fm = FileManager.default
            guard let names = try? fm.contentsOfDirectory(atPath: devices.path) else { return [] }
            var out: [StateDoc] = []
            for name in names {
                // Not-yet-downloaded iCloud files show up as ".<name>.icloud".
                if name.hasPrefix("."), name.hasSuffix(".icloud") {
                    let real = String(name.dropFirst().dropLast(".icloud".count))
                    if Sync.isDeviceFile(real) {
                        try? fm.startDownloadingUbiquitousItem(at: devices.appendingPathComponent(real))
                    }
                    continue
                }
                // Conflict copies ("X 2.json") and stray files are skipped.
                guard Sync.isDeviceFile(name), name != "\(me).json" else { continue }
                let url = devices.appendingPathComponent(name)
                if let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus,
                   status == .notDownloaded {
                    try? fm.startDownloadingUbiquitousItem(at: url)
                }
                var data: Data?
                var error: NSError?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { data = try? Data(contentsOf: $0) }
                if let data, let doc = try? JSONDecoder().decode(StateDoc.self, from: data), doc.device.id == String(name.dropLast(5)) {
                    out.append(doc)
                }
            }
            return out
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// Write our file unless nothing but the timestamp would change.
    @discardableResult
    public func write(_ doc: StateDoc, now: Date) throws -> Bool {
        var probe = doc
        probe.device.wrote = 0
        let body = try SyncFolder.encoder.encode(probe)
        if body == lastWritten { return false }
        var stamped = doc
        stamped.device.wrote = Clock.ms(now)
        let data = try SyncFolder.encoder.encode(stamped)
        try withAccess {
            try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
            let url = devices.appendingPathComponent("\(doc.device.id).json")
            var coordError: NSError?
            var writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { target in
                do { try data.write(to: target, options: .atomic) } catch { writeError = error }
            }
            if let e = coordError ?? writeError { throw e }
        }
        lastWritten = body
        return true
    }

    public func peers(excluding me: String) -> [Peer] {
        readPeers(excluding: me).map {
            Peer(id: $0.device.id, name: $0.device.name, platform: $0.device.platform, wrote: Clock.date(ms: $0.device.wrote))
        }
    }

    // MARK: bookmarks

    public func bookmark() throws -> Data {
        try withAccess {
            #if os(macOS)
            try root.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            #else
            try root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            #endif
        }
    }

    public static func resolve(bookmark: Data) -> (SyncFolder, stale: Bool)? {
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = .withSecurityScope
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        return (SyncFolder(root: url), stale)
    }
}
