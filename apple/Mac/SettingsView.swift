import AppKit
import Carbon.HIToolbox
import GSDCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(MacPrefs.self) private var prefs
    let store: LocalStore
    @State private var newURL = ""
    @State private var newName = ""
    @State private var renaming: Renaming?
    @State private var loggingIn = false
    @State private var importResult: String?
    @State private var syncError: String?
    @State private var timezone = ""

    struct Renaming: Identifiable {
        var id: String
        var name: String
    }

    var body: some View {
        Form {
            calendars
            gradescope
            sync
            general
            thisMac
            importSection
            about
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 480)
        .onAppear { timezone = model.doc.timezoneSetting }
        .sheet(isPresented: $loggingIn) { GradescopeLoginView() }
        .sheet(item: $renaming) { r in
            RenameSheet(name: r.name) { model.renameFeed(r.id, to: $0) }
        }
    }

    // MARK: sections

    private var calendars: some View {
        Section {
            ForEach(model.doc.activeFeeds, id: \.id) { entry in
                FeedRow(id: entry.id, feed: entry.feed, status: model.status[entry.id]) {
                    renaming = Renaming(id: entry.id, name: entry.feed.name)
                }
            }
            HStack {
                TextField("Feed URL", text: $newURL, prompt: Text("https://… or webcal://…"))
                TextField("Name", text: $newName, prompt: Text("Name (optional)"))
                    .frame(width: 150)
                Button("Add", action: addFeed).disabled(!validURL)
            }
            .labelsHidden()
            .onSubmit(addFeed)
        } header: {
            Text("Calendars")
        } footer: {
            Text("Paste an .ics or webcal:// link from Brightspace, Canvas, Outlook, …")
        }
    }

    private var validURL: Bool {
        guard let u = URL(string: FeedFetcher.normalize(newURL.trimmed)), let s = u.scheme?.lowercased() else { return false }
        return (s == "https" || s == "http") && u.host != nil
    }

    private func addFeed() {
        guard validURL else { return }
        model.addFeed(url: newURL.trimmed, name: newName.trimmed.isEmpty ? nil : newName.trimmed)
        newURL = ""
        newName = ""
    }

    private var gradescope: some View {
        Section {
            Toggle("Gradescope", isOn: Binding(get: { model.doc.gradescopeEnabled }, set: {
                model.set(SettingKey.gradescopeEnabled, .bool($0))
                if $0 { model.refresh(only: [StateDoc.gradescopeSource]) }
            }))
            if model.doc.gradescopeEnabled {
                Toggle("Include past terms", isOn: Binding(get: { model.doc.gradescopeAllTerms }, set: {
                    model.set(SettingKey.gradescopeAllTerms, .bool($0))
                }))
                Toggle("Skip submitted", isOn: Binding(get: { model.doc.gradescopeSkipSubmitted }, set: {
                    model.set(SettingKey.gradescopeSkipSubmitted, .bool($0))
                }))
                if !model.statusRight.isEmpty {
                    LabeledContent("Status", value: model.statusRight)
                }
            }
            HStack {
                Button(model.hasGradescopeSession ? "Log In Again…" : "Log In with Gradescope…") { loggingIn = true }
                Spacer()
                if model.hasGradescopeSession {
                    Button("Log Out", role: .destructive) { model.gradescopeLogout() }
                }
            }
        } header: {
            Text("Gradescope")
        } footer: {
            Text("Signs in on Gradescope's own page (school SSO works). Only the session cookie is kept, in this Mac's Keychain.")
        }
    }

    private var sync: some View {
        Section {
            if let folder = model.syncFolder {
                LabeledContent("Folder") {
                    Text(TerminalImport.abbreviate(folder.root)).truncationMode(.middle).lineLimit(1)
                }
                LabeledContent("Status", value: model.syncStatus)
                ForEach(model.syncPeers, id: \.id) { peer in
                    LabeledContent(peer.name) {
                        Text("\(peer.platform) · \(GSDText.relTime(peer.wrote, now: model.now))")
                    }
                }
                HStack {
                    Button("Sync Now") { model.sync() }
                    Button("Change Folder…", action: chooseSyncFolder)
                    Spacer()
                    Button("Stop Syncing", role: .destructive) { model.disconnectSync() }
                }
            } else {
                HStack {
                    if FileManager.default.fileExists(atPath: Self.iCloudGSD.path) {
                        Button("Use iCloud Drive/gsd") { connect(Self.iCloudGSD) }
                    }
                    Button("Choose Sync Folder…", action: chooseSyncFolder)
                }
            }
            if let syncError { Text(syncError).font(.caption).foregroundStyle(.red) }
        } header: {
            Text("Sync")
        } footer: {
            Text("Pick the same folder as on your iPhone (e.g. iCloud Drive/gsd). Each device writes its own file there and merges the others; checkmarks, manual items, feeds and settings sync. Logins never leave the device.")
        }
    }

    static let iCloudDrive = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    static let iCloudGSD = iCloudDrive.appendingPathComponent("gsd", isDirectory: true)

    private func chooseSyncFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose the gsd sync folder — the same one your iPhone uses."
        if FileManager.default.fileExists(atPath: Self.iCloudDrive.path) { panel.directoryURL = Self.iCloudDrive }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        connect(url)
    }

    private func connect(_ url: URL) {
        do {
            try model.connectSync(url)
            syncError = nil
        } catch {
            syncError = "Can't use that folder: \(error.localizedDescription)"
        }
    }

    private var general: some View {
        Section("General") {
            LabeledContent("Timezone") {
                HStack {
                    TextField("Timezone", text: $timezone, prompt: Text("auto"))
                        .labelsHidden()
                        .frame(width: 220)
                        .onSubmit(applyTimezone)
                    Button("Set", action: applyTimezone)
                }
            }
            Text("Due times and day groups use \(model.zone.identifier). An IANA name, or auto for this Mac's zone.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Stepper(value: intBinding(SettingKey.horizonDays, model.doc.horizonDays), in: 7...730, step: 7) {
                LabeledContent("Look ahead", value: "\(model.doc.horizonDays) days")
            }
            Stepper(value: intBinding(SettingKey.retentionDays, model.doc.retentionDays), in: 0...365) {
                LabeledContent("Keep completed", value: model.doc.retentionDays == 0 ? "forever" : "\(model.doc.retentionDays) days")
            }
            Stepper(value: intBinding(SettingKey.fetchTimeout, model.doc.fetchTimeout), in: 5...60, step: 5) {
                LabeledContent("Fetch timeout", value: "\(model.doc.fetchTimeout) s")
            }
        }
    }

    private func applyTimezone() {
        let v = timezone.trimmed
        if v.isEmpty || v.lowercased() == "auto" {
            model.set(SettingKey.timezone, .string("auto"))
            timezone = "auto"
        } else if ICS.ianaZone(v) != nil {
            model.set(SettingKey.timezone, .string(v))
        } else {
            model.notify("unknown IANA timezone: \(v)", seconds: 5)
            timezone = model.doc.timezoneSetting
        }
    }

    private func intBinding(_ key: String, _ value: Int) -> Binding<Int> {
        Binding(get: { value }, set: { model.set(key, .int($0)) })
    }

    private var thisMac: some View {
        Section {
            LabeledContent("Show gsd") { ShortcutRecorder() }
            if let error = prefs.hotKeyError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Toggle("Launch at login", isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.setLaunchAtLogin($0) }))
            if let note = prefs.loginNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("This Mac")
        } footer: {
            Text("The shortcut works from any app. Left-click the menu-bar icon to toggle gsd; right-click for this menu.")
        }
    }

    private var importSection: some View {
        Section {
            HStack {
                Button("Import from Terminal gsd") { importResult = TerminalImport.run(model, store: store) }
                    .disabled(!TerminalImport.available)
                Button("Choose Files…", action: chooseImportFiles)
            }
            if let importResult { Text(importResult).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Import")
        } footer: {
            Text("Reads \(TerminalImport.abbreviate(TerminalImport.configFile)), \(TerminalImport.abbreviate(TerminalImport.stateFile)) and the Gradescope plugin's files. Importing twice is harmless.")
        }
    }

    private func chooseImportFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        panel.message = "Select config.toml and state.json (optionally cookies.txt and assignments.json)."
        panel.directoryURL = TerminalImport.dataDir
        guard panel.runModal() == .OK else { return }
        var files: [(name: String, data: Data, modified: Date?)] = []
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            files.append((url.lastPathComponent, data, modified))
        }
        importResult = files.isEmpty ? "could not read the selected files" : model.importFiles(files)
    }

    private var about: some View {
        Section("About") {
            LabeledContent("Open", value: "\(model.view.openCount)")
            LabeledContent("Completed shown", value: "\(model.view.completed.count)")
            LabeledContent("Device", value: model.doc.device.name)
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
            LabeledContent("State") {
                Button(TerminalImport.abbreviate(store.stateURL)) {
                    NSWorkspace.shared.activateFileViewerSelecting([store.stateURL])
                }
                .buttonStyle(.link)
            }
        }
    }
}

struct FeedRow: View {
    @Environment(AppModel.self) private var model
    let id: String
    let feed: FeedEntry
    let status: SourceStatus?
    let rename: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(feed.name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(status?.error == nil ? Color.secondary : Color.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Toggle("Enabled", isOn: Binding(get: { feed.enabled }, set: { model.setFeedEnabled(id, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .contextMenu { actions }
    }

    @ViewBuilder private var actions: some View {
        Button("Rename…", action: rename)
        Button("Copy URL") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(feed.url, forType: .string)
        }
        Divider()
        Button("Delete", role: .destructive) { model.deleteFeed(id) }
    }

    private var detail: String {
        guard feed.enabled else { return "off" }
        if status?.pending == true { return "fetching…" }
        if let e = status?.error { return e }
        if let at = status?.fetchedAt { return "updated \(GSDText.relTime(at, now: model.now))" }
        return URL(string: FeedFetcher.normalize(feed.url))?.host ?? feed.url
    }
}

struct RenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var name: String
    let save: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Feed").font(.headline)
            TextField("Name", text: $name).onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: commit).keyboardShortcut(.defaultAction).disabled(name.trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func commit() {
        guard !name.trimmed.isEmpty else { return }
        save(name)
        dismiss()
    }
}

/// Click, then press the new shortcut (Esc cancels).
struct ShortcutRecorder: View {
    @Environment(MacPrefs.self) private var prefs
    @State private var recorder = Recorder()

    var body: some View {
        HStack {
            Button(recorder.active ? "Type a shortcut…" : prefs.shortcut.display) {
                if recorder.active { recorder.stop(prefs) } else { recorder.start(prefs) }
            }
            .frame(minWidth: 130)
            if !recorder.active, prefs.shortcut != .default {
                Button("Reset") { prefs.shortcut = .default }
            }
        }
        .onDisappear { recorder.stop(prefs) }
    }

    @MainActor @Observable
    final class Recorder {
        var active = false
        @ObservationIgnored private var monitor: Any?

        func start(_ prefs: MacPrefs) {
            guard !active else { return }
            active = true
            prefs.suspend()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let shortcut = Shortcut(event: event)
                let functionKey = Shortcut.named[Int(event.keyCode)]?.hasPrefix("F") == true
                let modified = !event.modifierFlags.intersection([.command, .option, .control]).isEmpty
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if Int(shortcut.keyCode) == kVK_Escape {
                        self.stop(prefs)
                    } else if functionKey || modified {
                        self.finish()
                        prefs.shortcut = shortcut  // registers it
                    } else {
                        NSSound.beep()
                    }
                }
                return nil
            }
        }

        func stop(_ prefs: MacPrefs) {
            guard active else { return }
            finish()
            prefs.apply()
        }

        private func finish() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            active = false
        }
    }
}
