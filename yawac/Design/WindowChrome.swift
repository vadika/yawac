import SwiftUI
import AppKit

/// Reaches up to the hosting NSWindow once it's attached, runs the
/// callback with it. Used to apply title-bar / mask configuration that
/// SwiftUI doesn't expose declaratively (transparent title bar with
/// full-size content area).
struct WindowAccessor: NSViewRepresentable {
    var callback: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            if let w = v.window { callback(w) }
        }
        return v
    }
    func updateNSView(_: NSView, context: Context) {}
}

/// Invisible overlay that forwards mouse-down to NSWindow.performDrag so
/// users can grab the top strip (where the OS title bar used to be) to
/// drag the window. Needed because `.fullSizeContentView` removes the
/// OS-supplied drag region. `allowsHitTesting` on interactive children
/// (buttons, search field) still pre-empts this.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_: NSView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { self }
    }
}

extension View {
    /// Applies Graphite window chrome: hides the title text, lets
    /// content draw under the title bar region, paints the window bg
    /// with Theme.bg so the surface reads continuous edge-to-edge.
    /// Keeps traffic lights visible — they're tied to the title bar,
    /// not the toolbar, so we must NOT remove the title bar container.
    func graphiteWindow() -> some View {
        background(
            WindowAccessor { w in
                w.titlebarAppearsTransparent = true
                w.titleVisibility = .hidden
                w.styleMask.insert(.fullSizeContentView)
                w.isMovableByWindowBackground = false
                w.backgroundColor = NSColor(
                    srgbRed: 0x0d/255, green: 0x0f/255, blue: 0x12/255, alpha: 1)
                // Defensive: traffic-light buttons sometimes get hidden
                // when combined with hiddenTitleBar windowStyle. Force
                // them visible.
                w.standardWindowButton(.closeButton)?.isHidden = false
                w.standardWindowButton(.miniaturizeButton)?.isHidden = false
                w.standardWindowButton(.zoomButton)?.isHidden = false
            }
        )
    }
}
