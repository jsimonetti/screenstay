import AppKit
import CoreGraphics

/// Conversion between the two global coordinate spaces macOS exposes.
///
/// ScreenStay stores and reasons about geometry in **AX space** throughout:
/// origin at the top-left of the primary display, y growing downward. This is
/// what `kAXPosition`, `CGDisplayBounds` and `kCGWindowBounds` all use.
///
/// AppKit (`NSWindow.setFrame`, `NSScreen.frame`) uses **Cocoa space**: origin
/// at the bottom-left of the primary display, y growing upward. Anything that
/// hands a rect to AppKit must convert first.
///
/// The flip constant is the height of the *primary* display - the one carrying
/// the menu bar, always `NSScreen.screens[0]`. It is deliberately **not**
/// `NSScreen.main`, which is the screen holding the key window and therefore
/// changes as focus moves between monitors.
enum CoordinateSpace {

    /// The primary display, i.e. the one whose top-left is the AX origin.
    static var primaryScreen: NSScreen? {
        NSScreen.screens.first
    }

    /// Height of the primary display; the constant both flips pivot around.
    ///
    /// Falls back to the union height of all screens if AppKit reports no
    /// screens at all (can happen briefly during display reconfiguration).
    static var flipHeight: CGFloat {
        if let primary = primaryScreen {
            return primary.frame.height
        }
        return NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }.height
    }

    // MARK: - Rect conversion

    /// Convert a rect from AX space (top-left origin) to Cocoa space.
    static func axToCocoa(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: flipHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// Convert a rect from Cocoa space (bottom-left origin) to AX space.
    ///
    /// The transform is its own inverse, but both directions are named so call
    /// sites document which way they are going.
    static func cocoaToAX(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: flipHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: - Point conversion

    /// Convert a point from AX space to Cocoa space.
    static func axToCocoa(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: flipHeight - point.y)
    }

    /// Convert a point from Cocoa space to AX space.
    static func cocoaToAX(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: flipHeight - point.y)
    }
}
