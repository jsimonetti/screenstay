import AppKit

/// One full-screen editing surface, covering exactly one display.
///
/// A session creates one of these per display in the profile. They are peers:
/// none of them owns the session state, and none of them handles keys, because
/// only one window can be key at a time and the shortcuts have to work wherever
/// the pointer happens to be. `LayoutEditorController` owns both.
@MainActor
final class LayoutEditorOverlayWindow: NSWindow {

    let display: DisplayRegistry.ResolvedDisplay
    let canvas: LayoutEditorCanvasView

    init(display: DisplayRegistry.ResolvedDisplay, profileName: String) {
        self.display = display

        // The display's bounds are in AX space; AppKit needs Cocoa space.
        let cocoaFrame = CoordinateSpace.axToCocoa(display.axBounds)
        self.canvas = LayoutEditorCanvasView(frame: NSRect(origin: .zero, size: cocoaFrame.size))

        super.init(
            contentRect: cocoaFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Above the menu bar and the Dock, so the editor really does cover the
        // display. Escape always closes, and the controller tears every overlay
        // down together, so there is no way to be left stuck behind one.
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        canvas.display = display
        canvas.profileName = profileName
        canvas.autoresizingMask = [.width, .height]
        contentView = canvas
    }

    /// Sit exactly on the display, menu bar included. The default implementation
    /// pushes windows clear of the menu bar, which would leave a strip of the
    /// display outside the editor.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
