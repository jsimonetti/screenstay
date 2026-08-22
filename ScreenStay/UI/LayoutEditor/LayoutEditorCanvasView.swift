import AppKit

/// Draws one display's worth of the layout being edited.
///
/// Read-only for now: it renders what the profile contains so the coordinate
/// pipeline can be checked against real hardware. Hit testing, dragging and the
/// context menu come next.
@MainActor
final class LayoutEditorCanvasView: NSView {

    var display: DisplayRegistry.ResolvedDisplay?
    var profileName: String = ""

    /// Right click, reported with the pointer already converted to a
    /// display-relative point in AX orientation, which is how regions are stored.
    var onContextMenu: ((_ relativePoint: CGPoint, _ display: DisplayRegistry.ResolvedDisplay,
                         _ event: NSEvent, _ view: LayoutEditorCanvasView) -> Void)?

    /// Pointer press, drag and release, in display-relative AX coordinates.
    var onMouseDown: ((CGPoint, DisplayRegistry.ResolvedDisplay) -> Void)?
    var onMouseDragged: ((CGPoint, DisplayRegistry.ResolvedDisplay) -> Void)?
    var onMouseUp: ((CGPoint, DisplayRegistry.ResolvedDisplay) -> Void)?

    /// Regions belonging to this display, in z-order, bottom first.
    var regions: [Region] = [] {
        didSet { needsDisplay = true }
    }

    /// The region the context menu and the handles act on.
    var selectedRegionID: String? {
        didSet { needsDisplay = true }
    }

    /// Handles for the selected region only, so the display stays readable.
    var handles: [LayoutEditorOperations.Handle] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { false }

    // MARK: - Palette

    private let backdrop = NSColor.black.withAlphaComponent(0.28)
    private let regionLine = NSColor.white.withAlphaComponent(0.85)
    private let regionFill = NSColor.white.withAlphaComponent(0.06)
    private let focusLine = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.24, alpha: 1.0)
    private let selectedLine = NSColor(calibratedRed: 0.42, green: 0.68, blue: 1.0, alpha: 1.0)
    private let handleFill = NSColor.white
    private let loneHandleFill = NSColor.white.withAlphaComponent(0.45)

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let display else { return }

        backdrop.setFill()
        bounds.fill()

        // The selected region is drawn last so its highlight is never painted
        // over by a region further along the array. Without this, selecting
        // anything below a full-screen region looks like nothing happened.
        for region in regions where region.id != selectedRegionID {
            draw(region, on: display)
        }
        if let selectedRegionID,
           let selected = regions.first(where: { $0.id == selectedRegionID }) {
            draw(selected, on: display)
        }

        drawReservedBand(on: display)
        drawHandles(on: display)
        drawDisplayLabel(display)
        drawHint()
    }

    /// Where a display-relative region lands in this view's coordinates.
    ///
    /// Region geometry is stored relative to its display and in AX orientation,
    /// so it is resolved against the display, flipped into Cocoa space, then
    /// rebased onto the view, which covers exactly that display. Both space
    /// conversions go through the shared helpers rather than being done by hand.
    static func viewRect(
        for relativeFrame: CGRect,
        on display: DisplayRegistry.ResolvedDisplay
    ) -> CGRect {
        let absoluteAX = RegionGeometry.absoluteAXFrame(for: relativeFrame, on: display)
        let displayOrigin = CoordinateSpace.axToCocoa(display.axBounds).origin
        return CoordinateSpace.axToCocoa(absoluteAX)
            .offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)
    }

    /// The inverse of `viewRect` for a point: view coordinates back to a
    /// display-relative point in AX orientation.
    static func relativePoint(
        forViewPoint point: CGPoint,
        on display: DisplayRegistry.ResolvedDisplay
    ) -> CGPoint {
        let displayOrigin = CoordinateSpace.axToCocoa(display.axBounds).origin
        let globalCocoa = CGPoint(x: displayOrigin.x + point.x, y: displayOrigin.y + point.y)
        let ax = CoordinateSpace.cocoaToAX(globalCocoa)
        return CGPoint(x: ax.x - display.axBounds.minX, y: ax.y - display.axBounds.minY)
    }

    // MARK: - Mouse

    override func rightMouseDown(with event: NSEvent) {
        guard let display else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        onContextMenu?(Self.relativePoint(forViewPoint: viewPoint, on: display), display, event, self)
    }

    /// Control-click is the system contextual menu gesture, so route it the same
    /// way rather than letting it arrive as an ordinary click.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        forward(event, to: onMouseDown)
    }

    override func mouseDragged(with event: NSEvent) {
        forward(event, to: onMouseDragged)
    }

    override func mouseUp(with event: NSEvent) {
        forward(event, to: onMouseUp)
    }

    private func forward(_ event: NSEvent,
                         to handler: ((CGPoint, DisplayRegistry.ResolvedDisplay) -> Void)?) {
        guard let display, let handler else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        handler(Self.relativePoint(forViewPoint: viewPoint, on: display), display)
    }

    private func draw(_ region: Region, on display: DisplayRegistry.ResolvedDisplay) {
        let rect = Self.viewRect(for: region.relativeFrame, on: display)
        guard rect.width > 2, rect.height > 2 else { return }

        let isFocus = region.isFocusRegion
        let isSelected = region.id == selectedRegionID
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)

        // Selection wins over the focus styling, so there is never any doubt
        // about which region an action will apply to.
        let line = isSelected ? selectedLine : (isFocus ? focusLine : regionLine)
        let fill: NSColor
        if isSelected {
            fill = selectedLine.withAlphaComponent(0.16)
        } else if isFocus {
            fill = focusLine.withAlphaComponent(0.10)
        } else {
            fill = regionFill
        }

        fill.setFill()
        path.fill()

        line.setStroke()
        path.lineWidth = isSelected ? 2.5 : (isFocus ? 1.5 : 1)
        if isFocus && !isSelected {
            path.setLineDash([6, 4], count: 2, phase: 0)
        }
        path.stroke()

        drawText(region.name, at: NSPoint(x: rect.minX + 9, y: rect.maxY - 20),
                 size: 11, weight: .medium, color: .white.withAlphaComponent(0.8))

        let size = "\(Int(region.relativeFrame.width)) x \(Int(region.relativeFrame.height))"
        drawCentredText(size, in: rect, size: 12, weight: .semibold, color: .white)

        drawText(assignmentSummary(for: region), at: NSPoint(x: rect.minX + 9, y: rect.minY + 8),
                 size: 10, weight: .regular, color: .white.withAlphaComponent(0.75))
    }

    /// The strip the menu bar occupies, which no window can be placed in.
    ///
    /// Drawn over the regions rather than under them, because a region may be
    /// authored to overlap it and the point is to show that the overlap will be
    /// cut away at placement time.
    ///
    /// The measurement comes from the display captured when the session opened.
    /// Reading it live would report nothing, since the editor hides the menu bar
    /// and `visibleFrame` grows the moment it does.
    private func drawReservedBand(on display: DisplayRegistry.ResolvedDisplay) {
        let inset = display.menuBarInset
        guard inset > 0 else { return }

        let band = Self.viewRect(
            for: CGRect(x: 0, y: 0, width: display.axBounds.width, height: inset), on: display)

        NSColor.black.withAlphaComponent(0.45).setFill()
        band.fill()

        // Hatching, so it reads as unavailable rather than merely dark.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: band).setClip()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        let stripe = NSBezierPath()
        stripe.lineWidth = 1
        var x = band.minX - band.height
        while x < band.maxX {
            stripe.move(to: NSPoint(x: x, y: band.minY))
            stripe.line(to: NSPoint(x: x + band.height, y: band.maxY))
            x += 8
        }
        stripe.stroke()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.30).setStroke()
        let edge = NSBezierPath()
        edge.move(to: NSPoint(x: band.minX, y: band.minY))
        edge.line(to: NSPoint(x: band.maxX, y: band.minY))
        edge.lineWidth = 1
        edge.stroke()

        let label = "menu bar  \(Int(inset)) pt  -  windows cannot be placed here"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6)
        ]
        let size = label.size(withAttributes: attributes)
        if band.height >= size.height {
            label.draw(at: NSPoint(x: band.midX - size.width / 2,
                                   y: band.midY - size.height / 2),
                       withAttributes: attributes)
        }
    }

    /// Solid pills mark a boundary shared with another region, where dragging
    /// moves both. Dimmer ones are edges with no neighbour, moving one region.
    private func drawHandles(on display: DisplayRegistry.ResolvedDisplay) {
        for handle in handles {
            let rect = Self.viewRect(for: handle.rect, on: display)
            (handle.isLinked ? handleFill : loneHandleFill).setFill()

            let radius = min(rect.width, rect.height) / 2
            let pill = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

            NSColor.black.withAlphaComponent(0.45).setStroke()
            pill.lineWidth = 1
            pill.fill()
            pill.stroke()
        }
    }

    /// What this region carries besides its rectangle, so nothing is deleted blind.
    private func assignmentSummary(for region: Region) -> String {
        var parts: [String] = []
        parts.append(region.assignedApps.count == 1 ? "1 app" : "\(region.assignedApps.count) apps")
        if let shortcut = region.keyboardShortcut {
            let symbols = shortcut.modifiers.map(Self.symbol(for:)).joined()
            parts.append("\(symbols)\(shortcut.key.uppercased())")
        }
        return parts.joined(separator: "  ")
    }

    private static func symbol(for modifier: String) -> String {
        switch modifier {
        case "control": return "\u{2303}"
        case "option": return "\u{2325}"
        case "shift": return "\u{21E7}"
        case "cmd": return "\u{2318}"
        default: return ""
        }
    }

    private func drawDisplayLabel(_ display: DisplayRegistry.ResolvedDisplay) {
        let text = "\(profileName)   \u{2022}   \(display.name)  "
            + "\(Int(display.axBounds.width))x\(Int(display.axBounds.height))"
        drawBadge(text, at: NSPoint(x: 18, y: bounds.maxY - 34))
    }

    private func drawHint() {
        drawBadge("Esc to close", at: NSPoint(x: 18, y: 18))
    }

    private func drawBadge(_ text: String, at origin: NSPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85)
        ]
        let size = text.size(withAttributes: attributes)
        let box = NSRect(x: origin.x, y: origin.y, width: size.width + 14, height: size.height + 8)

        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        text.draw(at: NSPoint(x: box.minX + 7, y: box.minY + 4), withAttributes: attributes)
    }

    private func drawText(_ text: String, at point: NSPoint, size: CGFloat,
                          weight: NSFont.Weight, color: NSColor) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)

        text.draw(at: point, withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .shadow: shadow
        ])
    }

    private func drawCentredText(_ text: String, in rect: NSRect, size: CGFloat,
                                 weight: NSFont.Weight, color: NSColor) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .shadow: shadow
        ]
        let textSize = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: rect.midX - textSize.width / 2,
                              y: rect.midY - textSize.height / 2),
                  withAttributes: attributes)
    }
}
