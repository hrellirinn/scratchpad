import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Settings control for a global shortcut: click it, then press the keys.
/// Esc cancels, Delete removes the shortcut. Needs ⌘, ⌃ or ⌥, so a stray
/// letter can't hijack typing in every app.
struct ShortcutRecorder: View {

    @Binding var shortcut: KeyShortcut?

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Text(isRecording ? "Type shortcut…" : (shortcut?.display ?? "Record Shortcut"))
                    .frame(minWidth: 110)
            }
            if shortcut != nil, !isRecording {
                Button {
                    shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove shortcut")
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        isRecording = true
        // macOS delivers a registered shortcut to its hotkey, never as a key
        // press, so let go of ours while recording (else re-recording it fails).
        (NSApp.delegate as? AppDelegate)?.setPanelShortcutPaused(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            record(event)
            return nil                // swallow every key while recording
        }
    }

    private func record(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        switch Int(event.keyCode) {
        case kVK_Escape:
            stopRecording()
        case kVK_Delete where flags.isEmpty, kVK_ForwardDelete where flags.isEmpty:
            shortcut = nil
            stopRecording()
        default:
            guard !flags.isEmpty else { NSSound.beep(); return }
            shortcut = KeyShortcut(event)
            stopRecording()
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard isRecording else { return }
        isRecording = false
        (NSApp.delegate as? AppDelegate)?.setPanelShortcutPaused(false)
    }
}
