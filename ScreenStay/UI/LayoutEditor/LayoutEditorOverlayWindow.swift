import AppKit

/// One full-screen editing surface, covering exactly one display.
///
/// A session creates one of these per display in the profile. They are peers:
/// none of them owns the session state, and none of them handles keys, because
/// only one window can be key at a time and the shortcuts have to work wherever
/// the pointer happens to be. `LayoutEditorController` owns both.
@MainActor
final class LayoutEditorOverlayWindow: NSWindow {

    /// Snapshot of the display as it was when the session opened.
    ///
    /// Held by value on purpose. The session hides the menu bar straight after
    /// creating these windows, which grows every screen's `visibleFrame`, and
    /// the display-change observer refreshes the shared registry afterwards.
    /// Anything reading the registry from here on would see no menu bar at all
    /// and draw no reserved band.
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

        level = Self.overlayLevel
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

    /// Above the Dock (20) and the menu bar (24), so the editor really does
    /// cover the display, but below pop-up menus (101) so the context menu
    /// draws on top of it rather than behind.
    ///
    /// Modal alerts sit lower still, at 8, so the controller drops the overlays
    /// while one is up. See `LayoutEditorController.runModal`.
    static let overlayLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

    /// Sit exactly on the display, menu bar included. The default implementation
    /// pushes windows clear of the menu bar, which would leave a strip of the
    /// display outside the editor.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
