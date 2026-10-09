import AppKit
import Carbon.HIToolbox

/// A key combination, as Settings records it and Carbon registers it.
struct KeyShortcut: Codable, Equatable {
    /// Virtual key code: the physical key, whatever the keyboard layout.
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, …), what `RegisterEventHotKey` wants.
    var modifiers: UInt32
    /// What Settings shows, e.g. "⌥Space". Captured when recorded, because
    /// turning a key code back into a character depends on the layout.
    var display: String
}

extension KeyShortcut {
    /// The shortcut a key press in the recorder describes.
    init(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        var symbols = ""
        // Same order as the menus: ⌃⌥⇧⌘.
        if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option)  { carbon |= UInt32(optionKey);  symbols += "⌥" }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey);   symbols += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey);     symbols += "⌘" }

        keyCode = UInt32(event.keyCode)
        modifiers = carbon
        display = symbols + (Self.keyNames[Int(event.keyCode)]
                             ?? event.charactersIgnoringModifiers?.uppercased() ?? "?")
    }

    /// Keys whose character is invisible or unprintable.
    private static let keyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

/// A system-wide shortcut that works while other apps are in front.
///
/// Carbon's `RegisterEventHotKey` is old, but it's still how macOS does this:
/// it works inside the sandbox and needs no Accessibility permission (a global
/// key monitor would). macOS swallows the key press, so the front app never
/// sees it. The shortcut stays registered for as long as this object lives.
final class GlobalHotKey {

    private let action: () -> Void
    private let id: EventHotKeyID
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private static var nextID: UInt32 = 1

    init(_ shortcut: KeyShortcut, action: @escaping () -> Void) {
        self.action = action
        id = EventHotKeyID(signature: OSType(0x5343_5250), id: Self.nextID)   // "SCRP"
        Self.nextID += 1

        // Carbon calls a plain C function, so `self` travels as an opaque pointer.
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                    eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var pressedID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressedID)
            return MainActor.assumeIsolated {
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                guard pressedID.id == hotKey.id.id else { return OSStatus(eventNotHandledErr) }
                hotKey.action()
                return noErr
            }
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            print("[Scratchpad] couldn't register \(shortcut.display): \(status)")
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
