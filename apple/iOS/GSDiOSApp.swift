import BackgroundTasks
import GSDCore
import SwiftUI
import UIKit

@main
struct GSDiOSApp: App {
    @State private var model = AppModel(deviceName: UIDevice.current.name, platform: "iOS")
    @State private var lastOpened = Date.distantPast
    @Environment(\.scenePhase) private var scenePhase

    init() { WatchLink.shared.activate() }

    var body: some Scene {
        WindowGroup {
            ChecklistView()
                .environment(model)
                .task { await launch() }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                    model.tick()
                }
                // Keep the Home and Lock Screen widgets on the current list.
                .onChange(of: WidgetSnapshot(model), initial: true) { _, snapshot in
                    WidgetSnapshot.publish(snapshot)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // Checked rows file under Completed once the app is put away.
                model.sweep()
                model.flush()
                GSDiOSApp.scheduleRefresh()
            case .active:
                model.tick()
                syncEverything()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(GSDiOSApp.refreshID)) {
            await backgroundRefresh()
        }
    }

    // MARK: background refresh

    static let refreshID = (Bundle.main.bundleIdentifier ?? "gsd") + ".refresh"

    /// Ask for the next run in an hour.  iOS treats this as "not before": it
    /// runs when it sees fit, less often for apps opened rarely, and not at
    /// all with Background App Refresh or Low Power Mode off.
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// iCloud sync plus every feed and Gradescope, then the widgets and watch.
    @MainActor
    private func backgroundRefresh() async {
        GSDiOSApp.scheduleRefresh()
        await model.backgroundRefresh()
        WidgetSnapshot.publish(WidgetSnapshot(model))
    }

    /// On open: pick up peers through iCloud, then fetch every source, fresh or not.
    @MainActor
    private func syncEverything() {
        // Launch delivers both the first task and the first .active.
        guard Date().timeIntervalSince(lastOpened) > 5 else { return }
        lastOpened = Date()
        Task {
            await model.syncAndWait()
            model.refresh(force: true)
        }
    }

    @MainActor
    private func launch() async {
        if ProcessInfo.processInfo.arguments.contains("--dump-rows") {
            // xcrun simctl launch --console booted <bundle-id> --dump-rows
            await model.refreshAndWait()
            model.tick()
            print(model.dumpRows(), terminator: "")
            print("# \(model.statusLeft) | \(model.statusRight)")
            fflush(stdout)
            exit(0)
        }
        syncEverything()
        // Re-render on each minute boundary so "overdue" flips at the due minute.
        while !Task.isCancelled {
            let wait = 60 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60) + 0.05
            try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            model.tick()
            model.sync()
        }
    }
}
