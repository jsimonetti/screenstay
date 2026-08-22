import AppKit
import CoreGraphics

/// Turns display-relative `Region` geometry into real screen coordinates.
///
/// This is the only place that knows how to go from stored region data to
/// something you can hand to the Accessibility API or to AppKit. Keeping it in
/// one place is what makes a region behave identically on every monitor.
@MainActor
enum RegionGeometry {

    /// Smallest window edge we will ever ask for, so the gutter can never invert a rect.
    private static let minimumEdge: CGFloat = 1

    // MARK: - Resolution

    /// The attached display a region belongs to, if any.
    ///
    /// Falls back to the primary display when the region names a monitor that
    /// is not currently connected, so a stale region degrades to something
    /// visible rather than vanishing off-screen.
    static func display(for region: Region, in registry: DisplayRegistry) -> DisplayRegistry.ResolvedDisplay? {
        if let key = region.displayKey, let display = registry.display(forKey: key) {
            return display
        }

        if let key = region.displayKey {
            log("Region '\(region.name)' references display '\(key)' which is not attached; falling back to primary")
        }
        return registry.primary
    }

    /// Absolute frame of a region in AX space, clamped to its display.
    static func absoluteAXFrame(for region: Region, in registry: DisplayRegistry) -> CGRect? {
        guard let display = display(for: region, in: registry) else {
            return nil
        }
        return absoluteAXFrame(for: region.relativeFrame, on: display, regionName: region.name)
    }

    /// Absolute frame in AX space for a display-relative rect.
    static func absoluteAXFrame(
        for relativeFrame: CGRect,
        on display: DisplayRegistry.ResolvedDisplay,
        regionName: String? = nil
    ) -> CGRect {
        let absolute = CGRect(
            x: display.axBounds.origin.x + relativeFrame.origin.x,
            y: display.axBounds.origin.y + relativeFrame.origin.y,
            width: relativeFrame.width,
            height: relativeFrame.height
        )

        let clamped = clamp(absolute, to: display.axBounds)
        if let regionName, clamped != absolute {
            log("Region '\(regionName)' extends past display '\(display.key)'; clamped to \(rectDescription(clamped))")
        }
        return clamped
    }

    /// Absolute frame a window should actually be given.
    ///
    /// Two things happen here that the stored region deliberately does not know
    /// about. The frame is cut down to the area a window can occupy, and then
    /// the gutter is applied.
    ///
    /// The clamp is a rectangle intersection, not a nudge. macOS constrains only
    /// the *origin* of a window, so a region starting at the top of a display
    /// gets pushed down while keeping its height, and its bottom edge ends up
    /// past the end of the display. Intersecting shortens it instead, which is
    /// what was actually wanted.
    ///
    /// Clamping runs before the gutter so the window sits a gutter's width below
    /// the menu bar, like every other edge. The other way round the clamp would
    /// override the inset and leave it flush.
    static func contentAXFrame(for region: Region, gap: CGFloat, in registry: DisplayRegistry) -> CGRect? {
        guard let display = display(for: region, in: registry) else {
            return nil
        }

        let frame = absoluteAXFrame(for: region.relativeFrame, on: display, regionName: region.name)
        let placeable = frame.intersection(display.axPlacementBounds)

        guard !placeable.isNull, placeable.width > 0, placeable.height > 0 else {
            log("Region '\(region.name)' lies entirely under the menu bar of display "
                + "'\(display.key)'; nothing to place")
            return nil
        }

        if placeable != frame {
            log("Region '\(region.name)' overlaps the menu bar on '\(display.key)'; "
                + "placing in \(rectDescription(placeable)) instead of \(rectDescription(frame))")
        }

        return inset(placeable, by: gap)
    }

    /// Absolute frame in Cocoa space, for handing to AppKit.
    static func absoluteCocoaFrame(for region: Region, in registry: DisplayRegistry) -> CGRect? {
        absoluteAXFrame(for: region, in: registry).map { CoordinateSpace.axToCocoa($0) }
    }

    // MARK: - Authoring

    /// Rebase an absolute AX rect into display-relative coordinates.
    static func relativeFrame(forAbsoluteAX rect: CGRect, on display: DisplayRegistry.ResolvedDisplay) -> CGRect {
        CGRect(
            x: rect.origin.x - display.axBounds.origin.x,
            y: rect.origin.y - display.axBounds.origin.y,
            width: rect.width,
            height: rect.height
        )
    }

    /// Rebase an absolute AX rect against whichever display it mostly covers.
    ///
    /// Returns the owning display alongside the rebased rect so callers can
    /// record the right `displayKey`.
    static func rebase(
        absoluteAX rect: CGRect,
        in registry: DisplayRegistry
    ) -> (display: DisplayRegistry.ResolvedDisplay, relativeFrame: CGRect)? {
        guard let display = registry.display(bestMatchingAX: rect)
            ?? registry.display(containingAX: CGPoint(x: rect.midX, y: rect.midY))
            ?? registry.primary else {
            return nil
        }
        return (display, relativeFrame(forAbsoluteAX: rect, on: display))
    }

    // MARK: - Convenience over the shared registry

    // Default arguments are evaluated outside actor isolation, so the shared
    // registry is reached through overloads rather than through `= .shared`.

    static func display(for region: Region) -> DisplayRegistry.ResolvedDisplay? {
        display(for: region, in: .shared)
    }

    static func absoluteAXFrame(for region: Region) -> CGRect? {
        absoluteAXFrame(for: region, in: .shared)
    }

    static func contentAXFrame(for region: Region, gap: CGFloat) -> CGRect? {
        contentAXFrame(for: region, gap: gap, in: .shared)
    }

    static func absoluteCocoaFrame(for region: Region) -> CGRect? {
        absoluteCocoaFrame(for: region, in: .shared)
    }

    static func rebase(absoluteAX rect: CGRect) -> (display: DisplayRegistry.ResolvedDisplay, relativeFrame: CGRect)? {
        rebase(absoluteAX: rect, in: .shared)
    }

    // MARK: - Helpers

    /// Inset a rect on all four edges, refusing to produce a degenerate rect.
    ///
    /// A gap larger than half the region would otherwise yield a negative size,
    /// which the Accessibility API accepts and renders as a broken window.
    static func inset(_ rect: CGRect, by gap: CGFloat) -> CGRect {
        guard gap > 0 else { return rect }

        let maxHorizontal = max(0, (rect.width - minimumEdge) / 2)
        let maxVertical = max(0, (rect.height - minimumEdge) / 2)
        let horizontal = min(gap, maxHorizontal)
        let vertical = min(gap, maxVertical)

        return rect.insetBy(dx: horizontal, dy: vertical)
    }

    /// Keep a rect inside `bounds`, shrinking it first and then nudging it in.
    private static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let width = min(rect.width, bounds.width)
        let height = min(rect.height, bounds.height)
        let x = min(max(rect.origin.x, bounds.minX), bounds.maxX - width)
        let y = min(max(rect.origin.y, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func rectDescription(_ rect: CGRect) -> String {
        "[\(Int(rect.origin.x)), \(Int(rect.origin.y))] [\(Int(rect.width)), \(Int(rect.height))]"
    }
}
