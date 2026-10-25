import AppKit
import SwiftUI

/// Floating-panel background: a system material, or a solid color with a border under
/// Reduce Transparency / Increase Contrast.
private struct PanelBackground<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial), in: shape)
            .overlay(shape.strokeBorder(contrast == .increased || reduceTransparency ? Color.primary.opacity(0.6) : .clear))
    }
}

extension View {
    func panelBackground<S: InsettableShape>(_ shape: S) -> some View { modifier(PanelBackground(shape: shape)) }
}

extension NSHostingView {
    /// Panel content sized once to the SwiftUI view. The hosting view sits inside a plain container: as a window's
    /// direct contentView it keeps pushing content-size extrema to the window on every update (the audio meter
    /// redraws ~10×/s), which loops update-constraint passes until AppKit raises (crash seen in the toast and
    /// the recording bar).
    @MainActor
    static func fixed(_ root: Content) -> NSView {
        let host = NSHostingView(rootView: root)
        // Measure with intrinsic sizing on (not the default on every macOS release), then turn sizing off.
        host.sizingOptions = [.intrinsicContentSize]
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        if size.width < 1 || size.height < 1 { size = host.intrinsicContentSize }
        host.sizingOptions = []
        let container = MeasuredView(size: size)
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        return container
    }
}

/// Container that remembers the measured SwiftUI size: assigning it as a window's contentView resizes it to the
/// window first, so callers read `fittingSize`, never `frame`, to size the panel.
final class MeasuredView: NSView {
    private let measured: NSSize
    init(size: NSSize) {
        measured = size
        super.init(frame: NSRect(origin: .zero, size: size))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var fittingSize: NSSize { measured }
    override var intrinsicContentSize: NSSize { measured }
}
