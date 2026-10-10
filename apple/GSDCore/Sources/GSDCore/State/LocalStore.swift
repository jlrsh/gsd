import Foundation

/// `Application Support/gsd/state.json` plus raw ICS caches beside it.
public final class LocalStore: @unchecked Sendable {
    public let directory: URL
    public var stateURL: URL { directory.appendingPathComponent("state.json") }
    var cacheDir: URL { directory.appendingPathComponent("cache", isDirectory: true) }

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gsd", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(at: base.appendingPathComponent("cache"), withIntermediateDirectories: true)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return e
    }()

    public func load(deviceName: String, platform: String) -> StateDoc {
        if let data = try? Data(contentsOf: stateURL) {
            if let doc = try? JSONDecoder().decode(StateDoc.self, from: data) { return doc }
            // Quarantine a corrupt file rather than refusing to start.
            try? FileManager.default.removeItem(at: stateURL.appendingPathExtension("bad"))
            try? FileManager.default.moveItem(at: stateURL, to: stateURL.appendingPathExtension("bad"))
        }
        return StateDoc(device: DeviceInfo(id: UUID().uuidString, name: deviceName, platform: platform, wrote: 0))
    }

    public func save(_ doc: StateDoc) throws {
        var d = doc
        d.device.wrote = Clock.ms(Date())
        try LocalStore.encoder.encode(d).write(to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func cacheURL(_ feedID: String) -> URL {
        cacheDir.appendingPathComponent(feedID.replacingOccurrences(of: "ics:", with: "") + ".ics")
    }

    public func readCache(_ feedID: String) -> String? { try? String(contentsOf: cacheURL(feedID), encoding: .utf8) }

    public func writeCache(_ feedID: String, _ text: String) {
        try? Data(text.utf8).write(to: cacheURL(feedID), options: .atomic)
    }

    public func removeCache(_ feedID: String) { try? FileManager.default.removeItem(at: cacheURL(feedID)) }
}
