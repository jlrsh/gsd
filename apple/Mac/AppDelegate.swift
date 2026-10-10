import AppKit
import GSDCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let options = LaunchOptions(CommandLine.arguments)
    var store: LocalStore!
    var model: AppModel!
    var state: PanelState!
    var panel: PanelController!
    var prefs: MacPrefs!
    let hotKey = HotKey()
    var statusItem: NSStatusItem!
    let statusMenu = NSMenu()
    var settingsWindow: NSWindow?
    var loop: Task<Void, Never>?
    var terminateSignal: DispatchSourceSignal?

    static let launchedKey = "gsd.mac.launched"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A debug store gets its own defaults so it never touches the real sync bookmark.
        let suite = options.store.map { "gsd.debug" + $0.path.replacingOccurrences(of: "/", with: ".") }
        let defaults = suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        let fixed = options.now
        store = LocalStore(directory: options.store)
        model = AppModel(store: store, deviceName: Host.current().localizedName ?? "Mac", platform: "macOS",
                         defaults: defaults, clock: { fixed ?? Date() })
        state = PanelState(model: model)
        state.statePath = TerminalImport.abbreviate(store.stateURL)
        if options.headless {
            Task {
                await runHeadless()
                if let suite { defaults.removePersistentDomain(forName: suite) }
                exit(0)
            }
            return
        }

        prefs = MacPrefs(hotKey: hotKey, defaults: defaults)
        installMainMenu()
        installStatusItem()
        panel = PanelController(model: model, state: state, defaults: defaults)
        panel.onShow = { [weak self] in self?.panelWillShow() }
        panel.onHide = { [weak self] in self?.panelDidHide() }
        state.hide = { [weak self] in self?.panel.hide() }
        state.openSettings = { [weak self] in self?.openSettings() }
        state.quit = { NSApp.terminate(nil) }
        hotKey.onPress = { [weak self] in self?.panel.toggle() }
        prefs.onShortcut = { [weak self] in self?.state.shortcut = $0.display }
        state.shortcut = prefs.shortcut.display
        prefs.apply()
        observeSystem()
        watchStatus()
        terminateOnSIGTERM()

        let firstRun = !defaults.bool(forKey: AppDelegate.launchedKey)
        defaults.set(true, forKey: AppDelegate.launchedKey)
        loop = Task { await run(firstRun: firstRun) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !options.headless else { return }
        model.sweep()
        model.flush()
    }

    // MARK: lifecycle

    var isFresh: Bool {
        model.doc.feeds.isEmpty && model.doc.records.isEmpty && model.doc.manual.isEmpty && model.doc.settings.isEmpty
    }

    func run(firstRun: Bool) async {
        if isFresh, TerminalImport.available { _ = TerminalImport.run(model, store: store, fetch: false) }
        if firstRun {
            panel.show()
            model.notify("\(prefs.shortcut.display) summons gsd · ? for keys", seconds: 8)
        }
        // Peers first: a fetch another device just made is reused.
        await model.syncAndWait()
        model.refresh()
        var minute = 0
        while !Task.isCancelled {
            // Re-render on each minute boundary so "overdue" flips at the due minute.
            let wait = 60 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60) + 0.05
            try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            minute += 1
            model.tick()
            // Remote merges and fetches wait while the panel is up, so rows
            // never reshuffle under the cursor.
            guard !panel.isVisible else { continue }
            model.sync()
            if minute % 15 == 0 { model.refresh() }
        }
    }

    func panelWillShow() {
        model.tick()
        if model.isStale { model.refresh() }
    }

    /// The TUI's quit: checked rows file under Completed, then save and publish.
    func panelDidHide() {
        model.sweep()
        model.flush()
    }

    func observeSystem() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.tick()
                Task {
                    await self.model.syncAndWait()
                    self.model.refresh()
                }
            }
        }
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    NSTimeZone.resetSystemTimeZone()
                    self?.model.tick()
                }
            }
        }
    }

    func terminateOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        source.resume()
        terminateSignal = source
    }

    // MARK: menu bar

    func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "gsd")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusMenu.delegate = self
    }

    /// Left click toggles the panel; right (or ⌃/⌥) click opens the menu.
    @objc func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true || event?.modifierFlags.contains(.option) == true {
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            panel.toggle()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("Show gsd", #selector(showPanel), detail: prefs.shortcut.display))
        menu.addItem(item("Refresh", #selector(refreshNow)))
        menu.addItem(.separator())
        for line in [model.statusLeft, model.statusRight] where !line.isEmpty {
            let info = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        prefs.refreshLoginState()
        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = prefs.launchAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit gsd", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func item(_ title: String, _ action: Selector, key: String = "", detail: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let detail {
            let text = NSMutableAttributedString(string: title + "  ")
            text.append(NSAttributedString(string: detail, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = text
        }
        return item
    }

    /// The overdue count rides next to the menu-bar icon.
    func watchStatus() {
        withObservationTracking {
            let overdue = model.view.overdueCount
            statusItem.button?.title = overdue > 0 ? " \(overdue)" : ""
            statusItem.button?.toolTip = "gsd · " + model.statusLeft
        } onChange: { [weak self] in
            Task { @MainActor in self?.watchStatus() }
        }
    }

    @objc func showPanel() { panel.show() }
    @objc func refreshNow() { state.refresh() }
    @objc func toggleLaunchAtLogin() { prefs.setLaunchAtLogin(!prefs.launchAtLogin) }

    /// An agent app has no visible menu bar, but its main menu still routes
    /// ⌘C/⌘V/⌘A to text fields.
    func installMainMenu() {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(item("Settings…", #selector(openSettings), key: ","))
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Quit gsd", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        for submenu in [app, edit, window] {
            let holder = NSMenuItem()
            holder.submenu = submenu
            main.addItem(holder)
        }
        NSApp.mainMenu = main
    }

    // MARK: settings

    @objc func openSettings() {
        panel.hide()
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(store: store).environment(model).environment(prefs))
            host.sizingOptions = []
            let window = NSWindow(contentViewController: host)
            window.title = "gsd Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 580, height: 720))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("gsd.settings")
            settingsWindow = window
        }
        prefs.refreshLoginState()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Hand focus back to the previous app once Settings closes.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        DispatchQueue.main.async {
            if !(self.panel?.isVisible ?? false) { NSApp.hide(nil) }
        }
    }

    // MARK: headless

    func runHeadless() async {
        if options.importTerminal || isFresh {
            print("# import: " + TerminalImport.run(model, store: store, cookies: false, fetch: false))
        }
        if let dir = options.sync {
            model.useSyncFolder(dir)
            await model.syncAndWait()
        }
        if options.fetch { await model.refreshAndWait() } else { model.sweep() }
        model.tick()
        if options.dumpRows {
            print(model.dumpRows(), terminator: "")
            print("# \(model.statusLeft) | \(model.statusRight)")
        }
        if let path = options.snapshot {
            state.bodyRows = Metrics.bodyRows(height: options.size.height)
            state.reset()
            if let keys = options.keys { state.replay(keys) }
            switch options.screen {
            case "help": state.mode = .help
            case "sources": state.mode = .sources
            case "add": state.replay("aRead chapter 5<cr>fri 5pm")
            default: break
            }
            let ok = Snapshot.write(model: model, state: state, size: options.size, dark: !options.light, to: path)
            print(ok ? "# wrote \(path)" : "# snapshot failed")
        }
        if options.store != nil { model.flush() }
        if options.sync != nil { await model.syncAndWait() }
        fflush(stdout)
    }
}
