import AppKit
import CoreImage

/// A scroll view with a frosted strip across its top.
///
/// Why not `NSVisualEffectView`? Our window is transparent and the Liquid
/// Glass behind the editor is composited outside the window's own pixels, so
/// a within-window material sees only text on a void and renders black.
///
/// Instead the strip is a layer with a *background filter*: Core Animation
/// blurs whatever is composited beneath that layer in this window — the text
/// and gutter scrolling past — and nothing else. It updates by itself.
final class FrostedScrollView: NSScrollView {

    /// Height of the frosted strip (the header band).
    var frostHeight: CGFloat = 0 { didSet { tile() } }

    private let frost = FrostView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(frost, positioned: .above, relativeTo: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Keep the strip pinned to the top, full width, above the content.
    override func tile() {
        super.tile()
        frost.frame = NSRect(x: 0, y: 0, width: bounds.width, height: frostHeight)
        // Rulers get added after init; make sure the strip stays on top of everything.
        if subviews.last !== frost {
            frost.removeFromSuperview()
            addSubview(frost, positioned: .above, relativeTo: nil)
        }
    }
}

/// The strip itself: an empty layer whose background filter is a blur.
private final class FrostView: NSView {

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true           // required for Core Image filters on layers
        let blur = CIFilter(name: "CIGaussianBlur")!
        blur.setValue(10, forKey: kCIInputRadiusKey)
        layer?.backgroundFilters = [blur]
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }      // clicks go to the text
}
