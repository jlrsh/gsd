import Foundation
import Observation

/// Fetch status for one source, as the TUI's `FeedStatus`.
public struct SourceStatus: Hashable, Sendable {
    public var name: String
    public var pending = false
    public var error: String?
    public var fetchedAt: Date?
}

/// The app's single source of truth, shared by the iPhone (and later Mac) UI.
@MainActor @Observable
public final class AppModel {
    public private(set) var checklist: Checklist
    public private(set) var view: Checklist.View
    public private(set) var now: Date
    public private(set) var status: [String: SourceStatus] = [:]
    public private(set) var refreshing = false
    public var notice: String?

    @ObservationIgnored let store: LocalStore
    @ObservationIgnored var feedTexts: [String: String] = [:]
    @ObservationIgnored var parsed: [String: (sig: String, items: [Item])] = [:]
    @ObservationIgnored var live: [String: Item] = [:]
    @ObservationIgnored var saveTask: Task<Void, Never>?
    @ObservationIgnored var refreshTask: Task<Void, Never>?
    @ObservationIgnored let clock: () -> Date

    public init(store: LocalStore = LocalStore(), deviceName: String, platform: String,
                defaults: UserDefaults = .standard, clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.clock = clock
        self.defaults = defaults
        let doc = store.load(deviceName: deviceName, platform: platform)
        let now = clock()
        self.now = now
        self.checklist = Checklist(doc: doc)
        self.view = Checklist.View(main: [], completed: [], done: [], mainSections: [], completedSections: [], openCount: 0, overdueCount: 0)
        for (id, _) in doc.activeFeeds { feedTexts[id] = store.readCache(id) }
        rebuild()
        restoreSyncFolder()
    }

    public var doc: StateDoc { checklist.doc }
    public var zone: TimeZone { checklist.zone }

    // MARK: derived view

    func feedItems() -> [[Item]] {
        let zone = self.zone
        let day = Clock.day(now, zone).ordinal
        let horizon = doc.horizonDays
        var out: [[Item]] = []
        for (id, feed) in doc.activeFeeds where feed.enabled {
            guard let text = feedTexts[id] else { continue }
            let sig = "\(text.count)|\(text.hashValue)|\(day)|\(zone.identifier)|\(horizon)|\(feed.name)"
            if let hit = parsed[id], hit.sig == sig { out.append(hit.items); continue }
            let items = ICS.items(text, source: feed.name, horizonDays: horizon, now: now, zone: zone)
            parsed[id] = (sig, items)
            out.append(items)
        }
        if doc.gradescopeEnabled {
            out.append(Gradescope.items(checklist.gradescopeRows, zone: zone))
        }
        return out
    }

    public func rebuild() {
        let groups = feedItems()
        live = checklist.live(groups)
        var order: [String] = []
        var seen = Set<String>()
        for g in groups { for it in g where seen.insert(it.key).inserted { order.append(it.key) } }
        for key in doc.manual.keys.sorted() where live[key] != nil && seen.insert(key).inserted { order.append(key) }
        view = checklist.view(live, liveOrder: order, now: now)
        refreshStatusNames()
    }

    func refreshStatusNames() {
        var next: [String: SourceStatus] = [:]
        for (id, feed) in doc.activeFeeds where feed.enabled {
            var s = status[id] ?? SourceStatus(name: feed.name)
            s.name = feed.name
            s.error = s.pending ? nil : doc.sources[id]?.error
            s.fetchedAt = doc.sources[id]?.fetchedAt.map(Clock.date(ms:))
            next[id] = s
        }
        if doc.gradescopeEnabled {
            let id = StateDoc.gradescopeSource
            var s = status[id] ?? SourceStatus(name: "Gradescope")
            s.error = s.pending ? nil : doc.sources[id]?.error
            s.fetchedAt = doc.sources[id]?.fetchedAt.map(Clock.date(ms:))
            next[id] = s
        }
        if next != status { status = next }
    }

    public func isDone(_ item: Item) -> Bool { view.done.contains(item.key) }

    /// Re-render against the current time (minute tick, day rollover).
    public func tick() {
        now = clock()
        rebuild()
    }

    // MARK: status line

    public var statusLeft: String {
        if let notice { return notice }
        var bits = ["\(view.openCount) open"]
        if view.overdueCount > 0 { bits.append("\(view.overdueCount) overdue") }
        let feeds = doc.activeFeeds.filter { $0.feed.enabled }.compactMap { status[$0.id] }
        if !feeds.isEmpty {
            if feeds.contains(where: \.pending) {
                bits.append("fetching…")
            } else if let failed = feeds.first(where: { $0.error != nil }) {
                bits.append("\(failed.name): \(failed.error!)")
            } else {
                let newest = feeds.compactMap(\.fetchedAt).max()
                bits.append("updated \(GSDText.relTime(newest, now: now))")
            }
        } else if !doc.gradescopeEnabled {
            bits.append("no feeds — add one in Settings")
        }
        return bits.joined(separator: " · ")
    }

    public var statusRight: String {
        guard doc.gradescopeEnabled else { return "" }
        guard let s = status[StateDoc.gradescopeSource] else { return "Gradescope: never synced" }
        if s.pending { return "Gradescope: syncing…" }
        if let e = s.error { return "Gradescope: \(e)" }
        guard s.fetchedAt != nil else { return "Gradescope: never synced" }
        return "Gradescope synced \(GSDText.relTime(s.fetchedAt, now: now))"
    }

    public func notify(_ text: String, seconds: Double = 3) {
        notice = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            if self?.notice == text { self?.notice = nil }
        }
    }

    // MARK: actions

    public func toggle(_ item: Item) {
        checklist.toggle(item, live: live, now: clock())
        rebuild()
        scheduleSave()
    }

    /// File checked rows under Completed (on background / pull-to-refresh).
    public func sweep() {
        checklist.sweep(live: live, now: clock())
        rebuild()
        scheduleSave()
    }

    public func addManual(title: String, due: Date?, allDay: Bool) {
        let key = checklist.addManual(title: title, due: due, allDay: allDay, now: clock())
        rebuild()
        scheduleSave()
        if let due {
            notify("added for " + Rows.format(Clock.day(due, zone), Rows.dayFormatter))
        } else {
            notify("added")
        }
        _ = key
    }

    public func editManual(_ key: String, title: String, due: Date?, allDay: Bool) {
        checklist.editManual(key, title: title, due: due, allDay: allDay, now: clock())
        rebuild()
        scheduleSave()
    }

    public func deleteManual(_ key: String) {
        checklist.deleteManual(key, now: clock())
        rebuild()
        scheduleSave()
        notify("deleted")
    }

    public func manualItem(_ key: String) -> Item? { checklist.manualItem(key) }

    // MARK: settings & feeds

    public func addFeed(url: String, name: String?) {
        let id = checklist.addFeed(url: url, name: name, now: clock())
        feedTexts[id] = store.readCache(id)
        rebuild()
        scheduleSave()
        refresh(only: [id])
    }

    public func renameFeed(_ id: String, to name: String) {
        let n = Py.strip(name)
        guard !n.isEmpty else { return }
        checklist.updateFeed(id, now: clock()) { $0.name = n }
        rebuild(); scheduleSave()
    }

    public func setFeedEnabled(_ id: String, _ enabled: Bool) {
        checklist.updateFeed(id, now: clock()) { $0.enabled = enabled }
        rebuild(); scheduleSave()
        if enabled { refresh(only: [id]) }
    }

    public func deleteFeed(_ id: String) {
        checklist.deleteFeed(id, now: clock())
        feedTexts[id] = nil
        parsed[id] = nil
        store.removeCache(id)
        rebuild(); scheduleSave()
    }

    public func set(_ key: String, _ value: SettingValue) {
        checklist.doc.set(key, value, now: clock())
        parsed.removeAll()
        rebuild(); scheduleSave()
    }

    public var gradescopePassword: String? {
        let email = doc.gradescopeEmail
        return email.isEmpty ? nil : Keychain.password(email: email)
    }

    /// Log in with fresh credentials; on success store them and enable the source.
    public func gradescopeLogin(email: String, password: String) async throws {
        let e = Py.strip(email)
        let client = GradescopeClient(cookies: [], timeout: TimeInterval(max(10, doc.fetchTimeout)))
        try await client.login(email: e, password: password)
        Keychain.setPassword(password, email: e)
        Keychain.cookies = client.cookies
        set(SettingKey.gradescopeEmail, .string(e))
        set(SettingKey.gradescopeEnabled, .bool(true))
        refresh(only: [StateDoc.gradescopeSource])
    }

    public func gradescopeLogout() {
        let email = doc.gradescopeEmail
        if !email.isEmpty { Keychain.delete(service: Keychain.gradescopeService, account: email) }
        Keychain.cookies = []
        defaults.removeObject(forKey: AppModel.userAgentKey)
        set(SettingKey.gradescopeEnabled, .bool(false))
        notify("Gradescope credentials removed")
    }

    static let userAgentKey = "gsd.gradescope.userAgent"

    /// Agent of the browser that made the current session.
    public var gradescopeUserAgent: String? { defaults.string(forKey: AppModel.userAgentKey) }

    /// Adopt cookies from an in-app browser login (no password involved).
    public func gradescopeAdoptSession(cookies: [HTTPCookie], userAgent: String?) async throws {
        let ours = cookies.filter { $0.domain.contains("gradescope.com") }
        let client = GradescopeClient(cookies: ours, timeout: TimeInterval(max(10, doc.fetchTimeout)), userAgent: userAgent)
        guard try await client.isLoggedIn() else { throw GradescopeError.auth("that session isn't logged in") }
        Keychain.cookies = client.cookies
        if let userAgent { defaults.set(userAgent, forKey: AppModel.userAgentKey) }
        set(SettingKey.gradescopeEnabled, .bool(true))
        refresh(only: [StateDoc.gradescopeSource])
    }

    public var hasGradescopeSession: Bool { !Keychain.cookies.isEmpty || gradescopePassword != nil }

    // MARK: import

    /// Import terminal-gsd files; returns a one-line summary.
    @discardableResult
    public func importFiles(_ files: [(name: String, data: Data, modified: Date?)], fetch: Bool = true) -> String {
        var summary = PythonImport.Summary()
        var doc = checklist.doc
        var errors: [String] = []
        // Config first: state.json timestamps are read in its timezone.
        let ordered = files.sorted { a, b in
            let ka = PythonImport.kind(name: a.name, data: a.data), kb = PythonImport.kind(name: b.name, data: b.data)
            return (ka == .config ? 0 : 1) < (kb == .config ? 0 : 1)
        }
        for f in ordered {
            switch PythonImport.kind(name: f.name, data: f.data) {
            case .config?:
                PythonImport.importConfig(String(decoding: f.data, as: UTF8.self), into: &doc, summary: &summary)
            case .state?:
                do { try PythonImport.importState(f.data, into: &doc, summary: &summary) } catch { errors.append(f.name) }
            case .gradescopeRows?:
                do { try PythonImport.importGradescopeRows(f.data, into: &doc, fetchedAt: f.modified, summary: &summary) }
                catch { errors.append(f.name) }
            case .cookies?:
                let cookies = CookieJar.parseNetscape(String(decoding: f.data, as: UTF8.self))
                    .filter { $0.domain.contains("gradescope.com") }
                if cookies.isEmpty { errors.append(f.name) } else { Keychain.cookies = cookies; summary.cookies = cookies.count }
            case .calendar?, nil:
                errors.append(f.name)
            }
        }
        checklist.doc = doc
        for (id, _) in doc.activeFeeds where feedTexts[id] == nil { feedTexts[id] = store.readCache(id) }
        parsed.removeAll()
        rebuild()
        scheduleSave()
        if fetch { refresh() }
        let text = summary.description + (errors.isEmpty ? "" : " (skipped \(errors.joined(separator: ", ")))")
        notify(text, seconds: 6)
        return text
    }

    // MARK: refresh

    public var isStale: Bool {
        let times = status.values.compactMap(\.fetchedAt)
        guard let oldest = times.min(), times.count == status.count else { return true }
        return clock().timeIntervalSince(oldest) > 300
    }

    /// A source some device (maybe a peer, via sync) fetched in the last few minutes.
    func isFresh(_ id: String) -> Bool {
        guard let at = doc.sources[id]?.fetchedAt, doc.sources[id]?.error == nil else { return false }
        return clock().timeIntervalSince(Clock.date(ms: at)) < Sync.freshSeconds
    }

    /// Fetch every enabled source in parallel; each result lands as it comes in.
    /// Unless forced (or named in `only`), sources fetched recently are skipped.
    public func refresh(only: Set<String>? = nil, force: Bool = false) {
        let force = force || only != nil
        let feeds = doc.activeFeeds.filter { $0.feed.enabled && (only?.contains($0.id) ?? true) && (force || !isFresh($0.id)) }
        let wantGradescope = doc.gradescopeEnabled && (only?.contains(StateDoc.gradescopeSource) ?? true)
            && (force || !isFresh(StateDoc.gradescopeSource))
        guard !feeds.isEmpty || wantGradescope else { return }
        let timeout = TimeInterval(doc.fetchTimeout)
        let userAgent = gradescopeUserAgent
        for (id, _) in feeds { status[id]?.pending = true }
        if wantGradescope { status[StateDoc.gradescopeSource]?.pending = true }
        refreshing = true
        let options = GradescopeClient.Options(email: doc.gradescopeEmail, allTerms: doc.gradescopeAllTerms,
                                               skipSubmitted: doc.gradescopeSkipSubmitted, horizonDays: doc.horizonDays)
        let previous = refreshTask
        refreshTask = Task { [weak self] in
            _ = await previous?.value
            await withTaskGroup(of: Void.self) { group in
                for (id, feed) in feeds {
                    group.addTask {
                        let result: Result<String, Error>
                        do { result = .success(try await FeedFetcher.fetch(feed.url, timeout: timeout)) }
                        catch { result = .failure(error) }
                        await self?.landFeed(id, result)
                    }
                }
                if wantGradescope {
                    group.addTask {
                        let cookies = Keychain.cookies
                        let client = GradescopeClient(cookies: cookies, timeout: max(10, timeout) * 2.5, userAgent: userAgent)
                        let result: Result<[Gradescope.Row], Error>
                        do {
                            result = .success(try await client.fetch(options, password: { Keychain.password(email: options.email) }))
                        } catch {
                            result = .failure(error)
                        }
                        let after = client.cookies
                        if !after.isEmpty { Keychain.cookies = after }
                        await self?.landGradescope(result)
                    }
                }
            }
            self?.refreshing = false
        }
    }

    /// Pull-to-refresh: file checked rows, pick up peers, fetch everything.
    public func refreshAndWait() async {
        sweep()
        await syncAndWait()
        refresh(force: true)
        await refreshTask?.value
    }

    func landFeed(_ id: String, _ result: Result<String, Error>) {
        guard doc.feeds[id]?.deleted == false else { return }
        var snap = doc.sources[id] ?? SourceSnapshot()
        switch result {
        case .success(let text):
            feedTexts[id] = text
            parsed[id] = nil
            store.writeCache(id, text)
            snap.fetchedAt = Clock.ms(clock())
            snap.error = nil
            snap.by = doc.device.id
        case .failure(let e):
            snap.error = (e as? FetchError)?.description ?? String(describing: type(of: e))
        }
        checklist.doc.sources[id] = snap
        status[id]?.pending = false
        now = clock()
        rebuild()
        scheduleSave()
    }

    func landGradescope(_ result: Result<[Gradescope.Row], Error>) {
        let id = StateDoc.gradescopeSource
        var snap = doc.sources[id] ?? SourceSnapshot()
        switch result {
        case .success(let rows):
            snap.rows = rows
            snap.fetchedAt = Clock.ms(clock())
            snap.error = nil
            snap.by = doc.device.id
        case .failure(let e):
            snap.error = String(((e as? GradescopeError)?.description ?? String(describing: type(of: e))).prefix(60))
        }
        checklist.doc.sources[id] = snap
        status[id]?.pending = false
        now = clock()
        rebuild()
        scheduleSave()
    }

    // MARK: persistence

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        do { try store.save(checklist.doc) } catch { notify("could not save: \(error.localizedDescription)") }
        sync()
    }

    // MARK: sync

    /// The shared folder, if this device syncs.  Device-local, not synced.
    public private(set) var syncFolder: SyncFolder?
    public private(set) var syncPeers: [SyncFolder.Peer] = []
    public private(set) var syncError: String?
    public private(set) var lastSync: Date?
    @ObservationIgnored var syncTask: Task<Void, Never>?
    @ObservationIgnored let defaults: UserDefaults
    static let bookmarkKey = "gsd.sync.bookmark", lastSyncKey = "gsd.sync.lastSync"

    func restoreSyncFolder() {
        if let t = defaults.object(forKey: AppModel.lastSyncKey) as? Double { lastSync = Date(timeIntervalSince1970: t) }
        guard let data = defaults.data(forKey: AppModel.bookmarkKey), let (folder, stale) = SyncFolder.resolve(bookmark: data) else { return }
        syncFolder = folder
        if stale, let fresh = try? folder.bookmark() { defaults.set(fresh, forKey: AppModel.bookmarkKey) }
    }

    /// Start syncing through `url` (a folder picked by the user).
    public func connectSync(_ url: URL) throws {
        let folder = SyncFolder(root: url)
        defaults.set(try folder.bookmark(), forKey: AppModel.bookmarkKey)
        syncFolder = folder
        syncError = nil
        sync()
    }

    /// Use a folder directly (no bookmark), e.g. from a command-line tool.
    public func useSyncFolder(_ url: URL) {
        syncFolder = SyncFolder(root: url)
    }

    public func disconnectSync() {
        defaults.removeObject(forKey: AppModel.bookmarkKey)
        defaults.removeObject(forKey: AppModel.lastSyncKey)
        syncFolder = nil
        syncPeers = []
        syncError = nil
        lastSync = nil
    }

    public var syncStatus: String {
        guard syncFolder != nil else { return "off" }
        if let syncError { return syncError }
        guard let lastSync else { return "syncing…" }
        let others = syncPeers.count
        return "synced \(GSDText.relTime(lastSync, now: now)) · \(others) other device\(others == 1 ? "" : "s")"
    }

    /// Read peers, merge, then publish our own file.  Serialized.
    public func sync() {
        guard let folder = syncFolder else { return }
        let previous = syncTask
        syncTask = Task { [weak self] in
            _ = await previous?.value
            guard let self else { return }
            let me = self.doc.device.id
            let peers = await Task.detached { folder.readPeers(excluding: me) }.value
            self.applyPeers(peers)
            let store = self.store
            let outgoing = Sync.publishable(self.doc) { store.readCache($0) }
            let now = self.clock()
            let error: String? = await Task.detached { () -> String? in
                do { try folder.write(outgoing, now: now); return nil } catch { return "can't write: \(error.localizedDescription)" }
            }.value
            self.syncError = error
            if error == nil {
                self.lastSync = now
                self.defaults.set(now.timeIntervalSince1970, forKey: AppModel.lastSyncKey)
            }
        }
    }

    public func syncAndWait() async {
        sync()
        await syncTask?.value
    }

    func applyPeers(_ peers: [StateDoc]) {
        syncPeers = peers.map {
            SyncFolder.Peer(id: $0.device.id, name: $0.device.name, platform: $0.device.platform, wrote: Clock.date(ms: $0.device.wrote))
        }.sorted { $0.wrote > $1.wrote }
        var doc = checklist.doc
        let result = Sync.merge(&doc, peers: peers, now: clock(), lastSync: lastSync)
        guard result.changed else { return }
        checklist.doc = doc
        for (id, text) in result.adoptedTexts {
            feedTexts[id] = text
            parsed[id] = nil
            store.writeCache(id, text)
        }
        for (id, feed) in doc.activeFeeds where feedTexts[id] == nil { feedTexts[id] = store.readCache(id); _ = feed }
        parsed.removeAll()
        rebuild()
        // Persist locally; the debounced flush republishes our merged file.
        scheduleSave()
    }

    // MARK: debugging

    /// `gsd --list` output, for comparing against the terminal app.
    public func dumpRows() -> String {
        Rows.plainDump(completed: view.completed, main: view.main, now: now, zone: zone)
    }
}
