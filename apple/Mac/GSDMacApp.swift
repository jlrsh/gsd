import AppKit
import GSDCore

@main
enum GSDMacApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// Command-line switches, mostly for checking the app without a screen:
///   GSD --store DIR [--import-terminal] [--no-fetch] [--sync DIR] [--now ISO]
///       [--dump-rows] [--snapshot PNG [--screen list|help|sources|add] [--keys SCRIPT]
///        [--size WxH] [--light]]
struct LaunchOptions {
    var store: URL?
    var dumpRows = false
    var snapshot: String?
    var screen = "list"
    var size = CGSize(width: 700, height: 480)
    var keys: String?
    var fetch = true
    var importTerminal = false
    var sync: URL?
    var now: Date?
    var light = false

    /// Runs, prints, and exits instead of living in the menu bar.
    var headless: Bool { dumpRows || snapshot != nil }

    init(_ args: [String]) {
        var it = args.dropFirst().makeIterator()
        func path(_ s: String?) -> URL? { s.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } }
        while let arg = it.next() {
            switch arg {
            case "--store": store = path(it.next())
            case "--dump-rows": dumpRows = true
            case "--snapshot": snapshot = it.next()
            case "--screen": screen = it.next() ?? "list"
            case "--keys": keys = it.next()
            case "--no-fetch": fetch = false
            case "--import-terminal": importTerminal = true
            case "--sync": sync = path(it.next())
            case "--now": now = it.next().flatMap { ISODate.parse($0)?.date(naiveZone: .current) }
            case "--light": light = true
            case "--size":
                let parts = (it.next() ?? "").split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { size = CGSize(width: parts[0], height: parts[1]) }
            default: break
            }
        }
    }
}
