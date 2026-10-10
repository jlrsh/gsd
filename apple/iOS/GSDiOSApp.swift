import GSDCore
import SwiftUI
import UIKit

@main
struct GSDiOSApp: App {
    @State private var model = AppModel(deviceName: UIDevice.current.name, platform: "iOS")
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ChecklistView()
                .environment(model)
                .task { await launch() }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                    model.tick()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // Checked rows file under Completed once the app is put away.
                model.sweep()
                model.flush()
            case .active:
                model.tick()
                if model.isStale { model.refresh() }
            default:
                break
            }
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
        model.refresh()
        // Re-render on each minute boundary so "overdue" flips at the due minute.
        while !Task.isCancelled {
            let wait = 60 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60) + 0.05
            try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            model.tick()
        }
    }
}
