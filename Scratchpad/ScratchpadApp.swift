import SwiftUI

/// The entry point. `@main` tells Swift "start the program here".
///
/// A normal Mac app would declare a `WindowGroup` (a main window) in `body`.
/// Scratchpad has no main window — it lives in the menubar — so the only scene
/// we declare is `Settings`, which macOS opens on demand (⌘,) and never at launch.
///
/// All the menubar and popover work is AppKit, so we hand that to `AppDelegate`
/// via `@NSApplicationDelegateAdaptor`. That one line is the bridge between the
/// SwiftUI app lifecycle and the older AppKit world.
@main
struct ScratchpadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
        // Adds the standard Format ▸ Font items (Bold ⌘B, Italic ⌘I, Underline ⌘U).
        // We have no visible menu bar, but keyboard shortcuts are routed *through*
        // the menu, so this is what makes ⌘B reach the text view.
        .commands {
            TextFormattingCommands()
        }
    }
}
