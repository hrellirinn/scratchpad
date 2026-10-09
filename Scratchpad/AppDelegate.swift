import AppKit
import SwiftUI

/// Owns the menubar icon (`NSStatusItem`) and the floating glass panel
/// (`FloatingPanel`), and decides when the panel shows and hides.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!

    /// The model. Created once here and handed to the view; lives as long as the app.
    private let store = SheetStore()
    private let settings = AppSettings.shared
    private let updates = UpdateChecker()

    /// Watches for clicks in *other* apps so we can dismiss, like Control Center.
    private var clickOutsideMonitor: Any?

    /// Watches clicks in *our* window that land in the transparent shadow margin.
    private var marginClickMonitor: Any?

    /// Watches key presses in the panel for the sheet-switching shortcuts.
    private var sheetKeyMonitor: Any?

    /// Guards against the "close then instantly reopen" race when the icon
    /// itself is clicked while the panel is open (see `togglePanel`).
    private var lastHiddenAt: Date = .distantPast

    /// The Settings ▸ General shortcut that opens the panel from any app.
    private var panelHotKey: GlobalHotKey?
    /// True while Settings is recording a new shortcut (see `ShortcutRecorder`).
    private var panelShortcutPaused = false

    /// Design values. 440×580 from the Figma frame; gap is the breathing room
    /// between the menubar and the panel, matching macOS 26 system panels.
    static let panelSize = NSSize(width: 440, height: 580)
    static let panelCornerRadius: CGFloat = 20
    static let panelGap: CGFloat = 6

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        configurePanel()
        observeAppearanceSetting()
        updates.startChecking()
    }

    /// Apply Settings ▸ Appearance to the panel, and re-apply whenever it changes.
    ///
    /// `withObservationTracking` runs the first closure, notes which observable
    /// properties it read (`appearanceMode`), and calls `onChange` once when one
    /// of them is about to change. It's one-shot, so we re-arm it each time.
    private func observeAppearanceSetting() {
        withObservationTracking { [weak self] in
            guard let self else { return }
            panel.appearance = settings.appearanceMode.nsAppearance
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.observeAppearanceSetting()
            }
        }
    }

    /// Register Settings ▸ General's shortcut, and re-register when it changes.
    /// Same one-shot observation trick as `observeAppearanceSetting`.
    private func observePanelShortcut() {
        withObservationTracking { [weak self] in
            self?.registerPanelShortcut()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.observePanelShortcut()
            }
        }
    }

    private func registerPanelShortcut() {
        let shortcut = settings.panelShortcut     // read first: this is what's observed
        panelHotKey = nil
        guard let shortcut, !panelShortcutPaused else { return }
        panelHotKey = GlobalHotKey(shortcut) { [weak self] in
            self?.togglePanel(nil)
        }
    }

    func setPanelShortcutPaused(_ paused: Bool) {
        panelShortcutPaused = paused
        registerPanelShortcut()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveAll()
    }

    // MARK: - Menubar icon

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }

        // Your clipboard glyph, from the asset catalog. It's marked as a
        // *template* image there, which is what lets macOS recolour it for
        // light/dark menubars and the pressed state. The SVG is 260×370;
        // we ask for 16 pt tall and let the vector data keep it crisp.
        let image = NSImage(named: "MenuBarIcon")
        image?.isTemplate = true
        image?.size = NSSize(width: 16 * 260 / 370, height: 16)
        button.image = image
        button.imageScaling = .scaleProportionallyDown

        button.target = self
        button.action = #selector(togglePanel(_:))
    }

    // MARK: - Panel

    private func configurePanel() {
        panel = FloatingPanel(size: Self.panelSize,
                              cornerRadius: Self.panelCornerRadius,
                              content: PopoverView(store: store, settings: settings, updates: updates))
        panel.onEscape = { [weak self] in self?.hidePanel() }

        // If you switch to another app (⌘-tab, clicking its Dock icon), dismiss.
        // We watch the *app* deactivating rather than the window losing key
        // status, because key status flickers during launch and menu handling.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification, object: nil
        )

        observePanelShortcut()
    }

    @objc private func togglePanel(_ sender: Any?) {
        if panel.isVisible {
            hidePanel()
        } else if Date().timeIntervalSince(lastHiddenAt) > 0.25 {
            // If we hid <250 ms ago, this click is the one that *caused* the hide
            // (focus moved to the menubar), so don't immediately reopen.
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }

        // Where is the icon, in screen coordinates?
        let iconFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))

        // Centre the visible panel under the icon, just below the menubar…
        var panelOrigin = NSPoint(
            x: iconFrame.midX - Self.panelSize.width / 2,
            y: iconFrame.minY - Self.panelGap - Self.panelSize.height
        )
        // …but never let it hang off the edge of the screen.
        let bounds = screen.visibleFrame
        panelOrigin.x = min(max(panelOrigin.x, bounds.minX + 8),
                            bounds.maxX - Self.panelSize.width - 8)

        // The window is bigger than the panel by the shadow margin on every side.
        let margin = FloatingPanel.shadowMargin
        panel.setFrameOrigin(NSPoint(x: panelOrigin.x - margin, y: panelOrigin.y - margin))

        // Make Scratchpad the active app for as long as the panel is open. macOS
        // treats a click into an *inactive* app's window as "wake this app up"
        // rather than as a click; activating first avoids that.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)   // keep the icon in its "pressed" look while open

        installClickMonitors()
        installSheetKeyMonitor()

        // Give the window one pass through the run loop to settle on screen
        // before we place the text cursor.
        DispatchQueue.main.async { [weak self] in
            self?.focusEditor()
        }
    }

    private func hidePanel() {
        store.saveAll()          // don't leave unsaved keystrokes waiting on the timer
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        removeClickMonitors()
        removeSheetKeyMonitor()
        lastHiddenAt = Date()

        // Hand focus back to whatever app you were in — unless one of our own
        // windows (Settings) is open, in which case stay active for it.
        let hasOtherVisibleWindows = NSApp.windows.contains { $0 !== panel && $0.isVisible }
        if !hasOtherVisibleWindows {
            NSApp.hide(nil)
        }
    }

    @objc private func appDidResignActive() {
        if panel.isVisible { hidePanel() }
    }

    /// Called from the gear menu just before opening Settings. Close the panel
    /// first so it doesn't float over the Settings window (the panel sits above
    /// normal windows), and make sure the app is active so the window shows.
    func prepareForSettings() {
        hidePanel()
        NSApp.activate()
    }

    /// The gear menu's "Check for Updates…". Same dance as Settings: close the
    /// panel so the alert isn't hidden behind it, and make sure we're active.
    func checkForUpdates() {
        hidePanel()
        NSApp.activate()
        Task { await updates.checkAndReport() }
    }

    /// Put the text cursor in the editor as soon as the panel opens, so you
    /// can start typing without clicking first.
    private func focusEditor() {
        guard let root = panel.contentView else { return }
        func firstTextView(in view: NSView) -> NSTextView? {
            if let tv = view as? NSTextView { return tv }
            for sub in view.subviews { if let tv = firstTextView(in: sub) { return tv } }
            return nil
        }
        if let textView = firstTextView(in: root) {
            panel.makeFirstResponder(textView)
        }
    }

    // MARK: - Click-outside dismissal

    private func installClickMonitors() {
        removeClickMonitors()

        // A *global* monitor only sees events in other apps — which is exactly the
        // "clicked somewhere else" signal we want. Mouse events don't need the
        // Accessibility permission (keyboard ones would).
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.hidePanel()
        }

        // A *local* monitor sees our own app's events before the views do. If a
        // click lands in our window but outside the visible panel (i.e. in the
        // transparent shadow margin), treat it as "outside" and swallow it.
        marginClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if self.panel.panelRect.contains(event.locationInWindow) {
                return event          // inside the panel: let it through
            }
            self.hidePanel()
            return nil                // in the margin: dismiss, don't deliver
        }
    }

    private func removeClickMonitors() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
        if let monitor = marginClickMonitor {
            NSEvent.removeMonitor(monitor)
            marginClickMonitor = nil
        }
    }

    // MARK: - Sheet shortcuts

    /// ⌘1…⌘5 jump to a sheet; ⌃Tab / ⌃⇧Tab step to the next / previous one,
    /// wrapping round. A local monitor sees the key before the text view does,
    /// so ⌃Tab switches sheets instead of typing a tab.
    private func installSheetKeyMonitor() {
        removeSheetKeyMonitor()
        sheetKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel,
                  let index = self.sheetIndex(for: event) else { return event }
            self.store.selectedIndex = index
            return nil                // handled: don't type it
        }
    }

    private func removeSheetKeyMonitor() {
        if let monitor = sheetKeyMonitor {
            NSEvent.removeMonitor(monitor)
            sheetKeyMonitor = nil
        }
    }

    /// The sheet a key press asks for, or `nil` if it isn't a sheet shortcut.
    private func sheetIndex(for event: NSEvent) -> Int? {
        let count = settings.sheetCount
        guard count > 1 else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])

        if event.keyCode == Self.tabKeyCode, modifiers.subtracting(.shift) == .control {
            let step = modifiers.contains(.shift) ? -1 : 1
            return (store.selectedIndex + step + count) % count
        }
        if modifiers == .command,
           let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }),
           (1...count).contains(digit) {
            return digit - 1
        }
        return nil
    }

    /// The Tab key's virtual key code (`kVK_Tab` in Carbon).
    private static let tabKeyCode: UInt16 = 48
}
