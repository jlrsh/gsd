import Foundation
import GSDCore

// Debug tool: run the native pipeline over the terminal app's files and print
// rows in `gsd --list` format.  No network unless --fetch.
//   swift run gsd-dump [--fetch] [--now ISO] [--config PATH] [--state PATH] [--data DIR]
@MainActor
func run() async {
    let args = CommandLine.arguments
    func opt(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let config = opt("--config") ?? home.appendingPathComponent(".config/gsd/config.toml").path
    let state = opt("--state") ?? home.appendingPathComponent(".local/share/gsd/state.json").path
    let data = URL(fileURLWithPath: opt("--data") ?? home.appendingPathComponent(".local/share/gsd").path)
    let fixed = opt("--now").flatMap { ISODate.parse($0)?.date(naiveZone: .current) }

    // --write DIR keeps the imported native state (state.json + cache/), e.g.
    // to seed a simulator's Application Support/gsd.
    let keep = opt("--write").map { URL(fileURLWithPath: $0) }
    let tmp = keep ?? FileManager.default.temporaryDirectory.appendingPathComponent("gsd-dump-\(UUID().uuidString)")
    let store = LocalStore(directory: tmp)
    defer { if keep == nil { try? FileManager.default.removeItem(at: tmp) } }
    var files: [(name: String, data: Data, modified: Date?)] = []
    for path in [config, state, data.appendingPathComponent("plugins/gradescope/assignments.json").path] {
        guard let d = FileManager.default.contents(atPath: path) else { continue }
        let mod = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        files.append(((path as NSString).lastPathComponent, d, mod))
    }
    // Seed ICS caches under the ids the native app uses (same sha256 names).
    let cache = data.appendingPathComponent("cache")
    for name in (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? [] where name.hasSuffix(".ics") {
        let text = (try? String(contentsOf: cache.appendingPathComponent(name), encoding: .utf8)) ?? ""
        store.writeCache("ics:" + name.replacingOccurrences(of: ".ics", with: ""), text)
    }
    let model = AppModel(store: store, deviceName: "dump", platform: "macOS", clock: { fixed ?? Date() })
    let summary = model.importFiles(files, fetch: false)
    if let cookiePath = opt("--gradescope-cookies") {
        // Exercise the native client with an existing session; nothing is stored.
        let cookies = CookieJar.parseNetscape((try? String(contentsOfFile: cookiePath, encoding: .utf8)) ?? "")
        let client = GradescopeClient(cookies: cookies)
        do {
            let rows = try await client.fetch(.init(email: model.doc.gradescopeEmail, allTerms: model.doc.gradescopeAllTerms,
                                                    skipSubmitted: model.doc.gradescopeSkipSubmitted), password: { nil })
            FileHandle.standardError.write(Data("gradescope: \(rows.count) rows\n".utf8))
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try enc.encode(rows), as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data("gradescope error: \(error)\n".utf8))
        }
        return
    }
    if args.contains("--fetch") { await model.refreshAndWait() }
    model.tick()
    if keep != nil { model.flush() }
    FileHandle.standardError.write(Data("\(summary) · zone \(model.zone.identifier)\n\(model.statusLeft) | \(model.statusRight)\n".utf8))
    print(model.dumpRows(), terminator: "")
}

await run()
