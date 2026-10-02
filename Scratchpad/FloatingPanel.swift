import AppKit
import SwiftUI

/// A borderless, fully transparent window that floats under the menubar icon.
///
/// Why not NSPopover? It paints its own frosted background, which is not Liquid
/// Glass and ignores the system Clear/Tinted setting. Real glass needs to see the
/// desktop *through* the window, so the window must be transparent.
///
/// The window is slightly larger than the visible panel: a transparent margin
/// all round gives our own drop shadow room. We draw that shadow ourselves and
/// turn the system one off, because macOS shapes its shadow from what it thinks
/// is opaque, and it guesses wrong for glass.
final class FloatingPanel: NSPanel {

    /// Transparent space around the panel for the shadow to fall into.
    static let shadowMargin: CGFloat = 48

    /// The visible panel's rectangle, in this window's own coordinates.
    let panelRect: NSRect

    /// Called when the user presses Escape inside the panel.
    var onEscape: (() -> Void)?

    init(size: NSSize, cornerRadius: CGFloat, content: some View) {
        let margin = Self.shadowMargin
        let windowSize = NSSize(width: size.width + margin * 2,
                                height: size.height + margin * 2)
        panelRect = NSRect(x: margin, y: margin, width: size.width, height: size.height)

        super.init(
            contentRect: NSRect(origin: .zero, size: windowSize),
            // `.borderless` = no title bar. `.nonactivatingPanel` = takes keyboard
            // input without making Scratchpad the active app (like Spotlight).
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // See-through window; shadow is ours (drawn in PanelChrome).
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false

        // NSPanel's default is to hide itself whenever the app deactivates. That
        // races with our own show/hide logic at launch and leaves a "ghost"
        // window on screen. We decide when to hide; AppKit doesn't.
        hidesOnDeactivate = false

        // No order-in/out fade: the fade is a separate snapshot window, and an
        // early orderOut during the fade is what produced the ghost.
        animationBehavior = .none

        let chrome = PanelChrome(size: size, cornerRadius: cornerRadius, margin: margin) {
            content
        }
        let hosting = NSHostingView(rootView: chrome)
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: windowSize)
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

/// The panel's "chrome": glass surface + drop shadow, wrapped around the content.
///
/// Everything here has an explicit frame — the panel's, or the whole window's —
/// so nothing depends on SwiftUI guessing how much room a blur needs.
private struct PanelChrome<Content: View>: View {
    let size: NSSize
    let cornerRadius: CGFloat
    let margin: CGFloat
    @ViewBuilder let content: () -> Content

    private var windowSize: CGSize {
        CGSize(width: size.width + margin * 2, height: size.height + margin * 2)
    }

    var body: some View {
        ZStack {
            PanelShadow(panelSize: size, cornerRadius: cornerRadius, windowSize: windowSize)

            content()
                .frame(width: size.width, height: size.height)
                // The Liquid Glass. `.regular` is the standard system glass; this
                // is what the system Clear/Tinted appearance setting acts on.
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        }
        .frame(width: windowSize.width, height: windowSize.height)
    }
}

/// A soft shadow that exists only *outside* the panel shape, so it never
/// darkens the glass itself — same as a real window shadow.
private struct PanelShadow: View {
    let panelSize: NSSize
    let cornerRadius: CGFloat
    let windowSize: CGSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        // 1. An opaque panel-shaped block casts the shadow…
        shape
            .fill(.black)
            .frame(width: panelSize.width, height: panelSize.height)
            .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
            .frame(width: windowSize.width, height: windowSize.height)
            // 2. …then the block itself is masked away, leaving only the shadow.
            .mask {
                Rectangle()
                    .overlay {
                        shape
                            .frame(width: panelSize.width, height: panelSize.height)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                    .frame(width: windowSize.width, height: windowSize.height)
            }
            .allowsHitTesting(false)
    }
}
