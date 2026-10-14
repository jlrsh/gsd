import GSDCore
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
        if save(snapshot) { WidgetCenter.shared.reloadAllTimelines() }
    }
}
