import GSDCore
import WatchConnectivity
import WidgetKit

extension WidgetSnapshot {
    /// The main list's unchecked items.
    @MainActor
    init(_ model: AppModel) {
        let zone = model.zone
        let open = model.view.mainSections.flatMap(\.items).filter { !model.isDone($0) }
        tasks = open.map {
            Task(title: $0.title, due: $0.due, allDay: $0.allDay,
                 day: $0.day(zone)?.iso, source: $0.source)
        }
        self.zone = zone.identifier
        let checked = model.view.main.filter { model.isDone($0) } + model.view.completed
        // Only today onward matters; earlier days never come back into view.
        let today = WidgetSnapshot.iso(model.now, zone)
        doneDays = checked.compactMap { $0.day(zone)?.iso }.filter { $0 >= today }.sorted()
    }

    static func publish(_ snapshot: WidgetSnapshot) {
        guard save(snapshot) else { return }
        WidgetCenter.shared.reloadAllTimelines()
        WatchLink.shared.send(snapshot)
    }
}

/// Hands the snapshot to the watch, whose complications can't see the
/// phone's App Group.
final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ snapshot: WidgetSnapshot) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        let payload = [WidgetSnapshot.watchKey: data]
        // Latest wins; delivered whenever the watch app next wakes.
        try? session.updateApplicationContext(payload)
        // With a complication on the face this wakes the watch app now, out
        // of a budget of about 50 a day.
        if session.isComplicationEnabled, session.remainingComplicationUserInfoTransfers > 0 {
            session.transferCurrentComplicationUserInfo(payload)
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if state == .activated, let snapshot = WidgetSnapshot.load() { send(snapshot) }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) { session.activate() }  // switched watches
}
