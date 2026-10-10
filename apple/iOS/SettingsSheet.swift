import GSDCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var addingFeed = false
    @State private var renaming: (id: String, name: String)?
    @State private var importing = false
    @State private var importResult: String?

    var body: some View {
        NavigationStack {
            Form {
                calendars
                GradescopeSection()
                general
                importSection
                about
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $addingFeed) { AddFeedSheet() }
            .alert("Rename", isPresented: renameBinding) {
                TextField("Name", text: Binding(get: { renaming?.name ?? "" }, set: { renaming?.name = $0 }))
                Button("Save") { if let r = renaming { model.renameFeed(r.id, to: r.name) } }
                Button("Cancel", role: .cancel) {}
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                importResult = handleImport(result)
            }
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    // MARK: sections

    private var calendars: some View {
        Section {
            ForEach(model.doc.activeFeeds, id: \.id) { entry in
                FeedRow(id: entry.id, feed: entry.feed, status: model.status[entry.id])
                    .swipeActions {
                        Button(role: .destructive) { model.deleteFeed(entry.id) } label: { Label("Delete", systemImage: "trash") }
                        Button { renaming = (entry.id, entry.feed.name) } label: { Label("Rename", systemImage: "pencil") }
                            .tint(.blue)
                    }
                    .contextMenu {
                        Button { renaming = (entry.id, entry.feed.name) } label: { Label("Rename", systemImage: "pencil") }
                        Button { UIPasteboard.general.string = entry.feed.url } label: { Label("Copy URL", systemImage: "doc.on.doc") }
                        Button(role: .destructive) { model.deleteFeed(entry.id) } label: { Label("Delete", systemImage: "trash") }
                    }
            }
            Button { addingFeed = true } label: { Label("Add Calendar Feed", systemImage: "plus") }
        } header: {
            Text("Calendars")
        } footer: {
            Text("Paste an .ics or webcal:// link from Brightspace, Canvas, Outlook, …  Swipe a feed to rename or delete it.")
        }
    }

    private var general: some View {
        Section("General") {
            TimezoneRow()
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

    private var importSection: some View {
        Section {
            Button { importing = true } label: { Label("Import from terminal gsd…", systemImage: "square.and.arrow.down") }
            if let importResult { Text(importResult).font(.footnote).foregroundStyle(.secondary) }
        } footer: {
            Text("Select config.toml and state.json together (e.g. from iCloud Drive). Optional: Gradescope cookies.txt and assignments.json. Importing twice is harmless.")
        }
    }

    private var about: some View {
        Section("About") {
            LabeledContent("Open", value: "\(model.view.openCount)")
            LabeledContent("Completed shown", value: "\(model.view.completed.count)")
            LabeledContent("Device", value: model.doc.device.name)
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
        }
    }

    private func intBinding(_ key: String, _ value: Int) -> Binding<Int> {
        Binding(get: { value }, set: { model.set(key, .int($0)) })
    }

    private func handleImport(_ result: Result<[URL], Error>) -> String {
        guard case .success(let urls) = result else { return "import cancelled" }
        var files: [(name: String, data: Data, modified: Date?)] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var data: Data?
            var coordError: NSError?
            // Coordinate so iCloud Drive downloads the file if needed.
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { data = try? Data(contentsOf: $0) }
            guard let data else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            files.append((url.lastPathComponent, data, modified))
        }
        guard !files.isEmpty else { return "could not read the selected files" }
        return model.importFiles(files)
    }
}

struct FeedRow: View {
    @Environment(AppModel.self) private var model
    let id: String
    let feed: FeedEntry
    let status: SourceStatus?

    var body: some View {
        Toggle(isOn: Binding(get: { feed.enabled }, set: { model.setFeedEnabled(id, $0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(feed.name)
                Text(detail).font(.caption).foregroundStyle(status?.error == nil ? Color.secondary : Color.red)
                    .lineLimit(1)
            }
        }
    }

    private var detail: String {
        guard feed.enabled else { return "off" }
        if status?.pending == true { return "fetching…" }
        if let e = status?.error { return e }
        if let at = status?.fetchedAt { return "updated \(GSDText.relTime(at, now: model.now))" }
        return host(feed.url)
    }

    private func host(_ url: String) -> String {
        URL(string: FeedFetcher.normalize(url))?.host ?? url
    }
}


struct TimezoneRow: View {
    @Environment(AppModel.self) private var model
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        Button {
            draft = model.doc.timezoneSetting
            editing = true
        } label: {
            LabeledContent("Timezone") {
                Text(model.doc.timezoneSetting.lowercased() == "auto" ? "Auto (\(model.zone.identifier))" : model.zone.identifier)
            }
        }
        .foregroundStyle(.primary)
        .alert("Timezone", isPresented: $editing) {
            TextField("IANA name or auto", text: $draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Use Device Zone") { model.set(SettingKey.timezone, .string("auto")) }
            Button("Save") {
                let v = draft.trimmed
                if v.isEmpty || v.lowercased() == "auto" {
                    model.set(SettingKey.timezone, .string("auto"))
                } else if ICS.ianaZone(v) != nil {
                    model.set(SettingKey.timezone, .string(v))
                } else {
                    model.notify("unknown IANA timezone: \(v)", seconds: 5)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("e.g. America/Indiana/Indianapolis. Due times and day groups use this zone.")
        }
    }
}

struct AddFeedSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var name = ""

    private var valid: Bool {
        guard let u = URL(string: FeedFetcher.normalize(url.trimmed)), let s = u.scheme?.lowercased() else { return false }
        return (s == "https" || s == "http") && u.host != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://… or webcal://…", text: $url, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Name (optional)", text: $name)
                } footer: {
                    Text(url.isEmpty ? "The link stays on this device." : (valid ? "Will show as “\(name.trimmed.isEmpty ? FeedFetcher.defaultName(FeedFetcher.normalize(url.trimmed)) : name.trimmed)”" : "Not a web link"))
                }
                Section {
                    Button { if let s = UIPasteboard.general.string { url = s.trimmed } } label: {
                        Label("Paste Link", systemImage: "doc.on.clipboard")
                    }
                }
            }
            .navigationTitle("Add Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        model.addFeed(url: url.trimmed, name: name.trimmed.isEmpty ? nil : name.trimmed)
                        dismiss()
                    }
                    .disabled(!valid)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct GradescopeSection: View {
    @Environment(AppModel.self) private var model
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var result: String?
    @State private var loaded = false

    var body: some View {
        Section {
            Toggle("Gradescope", isOn: Binding(get: { model.doc.gradescopeEnabled }, set: {
                model.set(SettingKey.gradescopeEnabled, .bool($0))
                if $0 { model.refresh(only: [StateDoc.gradescopeSource]) }
            }))
            TextField("Email", text: $email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField(model.gradescopePassword == nil ? "Password" : "Password (saved)", text: $password)
                .textContentType(.password)
            Button {
                Task { await login() }
            } label: {
                HStack {
                    Text("Log In")
                    if busy { Spacer(); ProgressView() }
                }
            }
            .disabled(busy || email.trimmed.isEmpty || password.isEmpty)
            if let result { Text(result).font(.footnote).foregroundStyle(.secondary) }
            if model.doc.gradescopeEnabled {
                Toggle("Include past terms", isOn: Binding(get: { model.doc.gradescopeAllTerms }, set: {
                    model.set(SettingKey.gradescopeAllTerms, .bool($0))
                }))
                Toggle("Skip submitted", isOn: Binding(get: { model.doc.gradescopeSkipSubmitted }, set: {
                    model.set(SettingKey.gradescopeSkipSubmitted, .bool($0))
                }))
                if !model.statusRight.isEmpty {
                    Text(model.statusRight).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if model.hasGradescopeSession {
                Button("Log Out", role: .destructive) {
                    model.gradescopeLogout()
                    password = ""
                    result = nil
                }
            }
        } header: {
            Text("Gradescope")
        } footer: {
            Text("Your password stays in this iPhone's Keychain and is only sent to gradescope.com.")
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            email = model.doc.gradescopeEmail
        }
    }

    @MainActor
    private func login() async {
        busy = true
        defer { busy = false }
        do {
            try await model.gradescopeLogin(email: email, password: password)
            password = ""
            result = "Logged in. Syncing…"
        } catch {
            result = "Login failed: \(error)"
        }
    }
}
