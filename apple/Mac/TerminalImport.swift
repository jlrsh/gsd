import Foundation
import GSDCore

/// The terminal gsd on this Mac: its files are read directly (see `gsd/paths.py`).
enum TerminalImport {
    static func xdg(_ variable: String, _ fallback: String) -> URL {
        let env = ProcessInfo.processInfo.environment[variable].flatMap { $0.isEmpty ? nil : $0 }
        let root = env.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(fallback)
        return root.appendingPathComponent("gsd", isDirectory: true)
    }

    static var configDir: URL { xdg("XDG_CONFIG_HOME", ".config") }
    static var dataDir: URL { xdg("XDG_DATA_HOME", ".local/share") }
    static var configFile: URL { configDir.appendingPathComponent("config.toml") }
    static var stateFile: URL { dataDir.appendingPathComponent("state.json") }

    static var available: Bool {
        FileManager.default.fileExists(atPath: configFile.path) || FileManager.default.fileExists(atPath: stateFile.path)
    }

    /// Import config, state and Gradescope files, seeding ICS caches under the
    /// ids the native app uses (same sha256 names), so rows show before any fetch.
    /// Returns a one-line summary.
    @MainActor
    static func run(_ model: AppModel, store: LocalStore, cookies: Bool = true, fetch: Bool = true) -> String {
        let fm = FileManager.default
        let plugin = dataDir.appendingPathComponent("plugins/gradescope")
        var urls = [configFile, stateFile, plugin.appendingPathComponent("assignments.json")]
        if cookies { urls.append(plugin.appendingPathComponent("cookies.txt")) }
        var files: [(name: String, data: Data, modified: Date?)] = []
        for url in urls {
            guard let data = fm.contents(atPath: url.path) else { continue }
            let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            files.append((url.lastPathComponent, data, modified))
        }
        guard !files.isEmpty else { return "nothing to import from \(abbreviate(configDir)) or \(abbreviate(dataDir))" }
        let cache = dataDir.appendingPathComponent("cache")
        for name in (try? fm.contentsOfDirectory(atPath: cache.path)) ?? [] where name.hasSuffix(".ics") {
            let id = "ics:" + name.dropLast(4)
            guard store.readCache(id) == nil,
                  let text = try? String(contentsOf: cache.appendingPathComponent(name), encoding: .utf8) else { continue }
            store.writeCache(id, text)
        }
        return model.importFiles(files, fetch: fetch)
    }

    static func abbreviate(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}
