import AppKit
import GSDCore
import SwiftUI

/// A floating panel that takes keystrokes without activating the app, so
/// focus goes straight back to whatever was in front when it hides.
final class GSDPanel: NSPanel {
    convenience init() {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 700, height: 480),
                  styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
                  backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        minSize = NSSize(width: 440, height: 240)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Summon / dismiss.  Hides on Esc, q, the hot key, or clicking elsewhere.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let sizeKey = "gsd.mac.panelSize"

    let panel = GSDPanel()
    let state: PanelState
    let defaults: UserDefaults
    var onShow: @MainActor () -> Void = {}
    var onHide: @MainActor () -> Void = {}
    private var monitor: Any?
    private var hiddenAt = Date.distantPast

    init(model: AppModel, state: PanelState, defaults: UserDefaults) {
        self.state = state
        self.defaults = defaults
        super.init()
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        let host = NSHostingView(rootView: PanelView().environment(model).environment(state))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            host.topAnchor.constraint(equalTo: background.topAnchor),
            host.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        panel.delegate = self
        if let saved = defaults.string(forKey: PanelController.sizeKey) {
            let size = NSSizeFromString(saved)
            if size.width >= panel.minSize.width, size.height >= panel.minSize.height { panel.setContentSize(size) }
        }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible {
            hide()
        } else if Date().timeIntervalSince(hiddenAt) > 0.3 {
            // A click on the menu-bar item first resigns the panel; don't bounce it back.
            show()
        }
    }

    func show() {
        guard !panel.isVisible else { return panel.makeKey() }
        onShow()
        state.bodyRows = Metrics.bodyRows(height: panel.contentView?.bounds.height ?? panel.frame.height)
        state.reset()
        position()
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        panel.makeKeyAndOrderFront(nil)
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.consumes(event) ?? false }
                return consumed ? nil : event
            }
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        hiddenAt = Date()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        defaults.set(NSStringFromSize(panel.contentRect(forFrameRect: panel.frame).size), forKey: PanelController.sizeKey)
        panel.orderOut(nil)
        state.mode = .list
        state.prompt = nil
        state.confirmDelete = nil
        onHide()
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    /// Centred, a little high, on the screen under the mouse.
    private func position() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        var frame = panel.frame
        frame.size.width = min(frame.width, area.width - 40)
        frame.size.height = min(frame.height, area.height - 40)
        frame.origin.x = area.midX - frame.width / 2
        frame.origin.y = min(area.maxY - frame.height - 20, area.midY - frame.height / 2 + area.height * 0.08)
        panel.setFrame(frame, display: false)
    }

    /// True when the panel handled the event (it then goes no further).
    private func consumes(_ event: NSEvent) -> Bool {
        guard event.window === panel else { return false }
        if event.type == .scrollWheel {
            guard state.mode == .list else { return false }
            state.wheel(event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
            return true
        }
        let chars = event.charactersIgnoringModifiers ?? ""
        let code = Int(event.keyCode)
        if state.mode == .prompt, !(panel.firstResponder is NSText), !event.modifierFlags.contains(.command) || chars == "v" {
            // The prompt's field didn't get focus: edit the line here instead.
            state.typeIntoPrompt(event.characters ?? chars, code: code, flags: event.modifierFlags)
            return true
        }
        return state.key(chars, code: code, flags: event.modifierFlags)
    }
}
