import SwiftUI
import WatchConnectivity
import WatchKit
import WidgetKit

@main
struct GSDWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: WatchDelegate

    var body: some Scene {
        WindowGroup {
            SummaryScreen().environment(delegate.store)
        }
    }
}

/// The phone's latest snapshot, as last received.
@Observable
final class SnapshotStore {
    var snapshot = WidgetSnapshot.load()
}

/// Receives snapshots from the phone, even in the background (a complication
/// transfer wakes the app), and stores them where the complications look.
final class WatchDelegate: NSObject, WKApplicationDelegate, WCSessionDelegate {
    let store = SnapshotStore()

    func applicationDidFinishLaunching() {
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if !session.receivedApplicationContext.isEmpty { receive(session.receivedApplicationContext) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) { receive(context) }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) { receive(userInfo) }

    private func receive(_ payload: [String: Any]) {
        guard let data = payload[WidgetSnapshot.watchKey] as? Data,
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return }
        if WidgetSnapshot.save(snapshot) { WidgetCenter.shared.reloadAllTimelines() }
        DispatchQueue.main.async { self.store.snapshot = snapshot }
    }
}

struct SummaryScreen: View {
    @Environment(SnapshotStore.self) private var store
    @AppStorage("includeOverdue") private var includeOverdue = true

    var body: some View {
        TimelineView(.everyMinute) { context in
            if let snapshot = store.snapshot {
                let s = Summary(snapshot, now: context.date, includeOverdue: includeOverdue)
                ScrollView {
                    VStack(spacing: 10) {
                        ProgressRing(summary: s, lineWidth: 10, numberFont: .system(size: 40, weight: .bold, design: .rounded))
                            .frame(width: 110, height: 110)
                        Text(s.headline)
                            .font(.headline)
                            .foregroundStyle(s.overdue > 0 ? Color.red : Color.primary)
                        Toggle("Include Overdue", isOn: $includeOverdue)
                            .font(.footnote)
                    }
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "iphone").font(.title2)
                    Text("Open gsd on your iPhone").multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}
