import Foundation
import CoreGraphics

/// The region edits the layout editor can perform, as pure functions.
///
/// Everything here works on display-relative geometry and returns new values
/// rather than mutating, so the controller can snapshot for undo by simply
/// keeping the array it had.
enum LayoutEditorOperations {

    /// Nothing smaller than this is worth creating, and splitting below it
    /// produces regions no window could sensibly occupy.
    static let minimumRegionEdge: CGFloat = 80

    /// Size given to a region drawn from the context menu.
    static let newRegionSize = CGSize(width: 600, height: 400)

    enum SplitAxis {
        /// Two regions side by side.
        case columns
        /// Two regions stacked.
        case rows
    }

    enum Edge {
        case left, right, top, bottom
    }

    // MARK: - Split

    /// Whether a region is big enough to divide on the given axis.
    static func canSplit(_ region: Region, into axis: SplitAxis) -> Bool {
        switch axis {
        case .columns: return region.relativeFrame.width >= minimumRegionEdge * 2
        case .rows: return region.relativeFrame.height >= minimumRegionEdge * 2
        }
    }

    /// Divide a region in half.
    ///
    /// The first result keeps the original's identity, name, apps, shortcut and
    /// focus flag; the second is new and carries nothing. Which half that is
    /// follows the reading order of the axis: left for columns, top for rows.
    static func split(_ region: Region, into axis: SplitAxis, existingNames: [String]) -> (kept: Region, added: Region)? {
        guard canSplit(region, into: axis) else { return nil }

        let frame = region.relativeFrame
        let keptFrame: CGRect
        let addedFrame: CGRect

        switch axis {
        case .columns:
            let half = (frame.width / 2).rounded(.down)
            keptFrame = CGRect(x: frame.minX, y: frame.minY, width: half, height: frame.height)
            addedFrame = CGRect(x: frame.minX + half, y: frame.minY,
                                width: frame.width - half, height: frame.height)
        case .rows:
            let half = (frame.height / 2).rounded(.down)
            keptFrame = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: half)
            addedFrame = CGRect(x: frame.minX, y: frame.minY + half,
                                width: frame.width, height: frame.height - half)
        }

        var kept = region
        kept.relativeFrame = keptFrame

        let added = Region(
            name: uniqueName(basedOn: region.name, avoiding: existingNames),
            displayKey: region.displayKey,
            relativeFrame: addedFrame
        )

        return (kept, added)
    }

    // MARK: - New region

    /// A region centred on a point, clamped to fit the display.
    static func newRegion(
        centredAtRelative point: CGPoint,
        on display: DisplayRegistry.ResolvedDisplay,
        existingNames: [String]
    ) -> Region {
        let bounds = CGRect(origin: .zero, size: display.axBounds.size)
        let size = CGSize(
            width: min(newRegionSize.width, bounds.width),
            height: min(newRegionSize.height, bounds.height)
        )

        let unclamped = CGRect(
            x: point.x - size.width / 2,
            y: point.y - size.height / 2,
            width: size.width,
            height: size.height
        )

        return Region(
            name: uniqueName(basedOn: "Region", avoiding: existingNames),
            displayKey: display.key,
            relativeFrame: clamp(unclamped, to: bounds)
        )
    }

    // MARK: - Snap

    /// Move one edge to the nearest edge offered by another region or by the
    /// display, keeping the opposite edge where it is.
    ///
    /// This is how coincident edges get created deliberately, which is what
    /// lets a shared boundary offer a single handle driving both sides.
    static func snap(
        _ region: Region,
        edge: Edge,
        against others: [Region],
        on display: DisplayRegistry.ResolvedDisplay
    ) -> Region? {
        let frame = region.relativeFrame
        let bounds = CGRect(origin: .zero, size: display.axBounds.size)

        let neighbours = others.filter { $0.id != region.id && $0.displayKey == region.displayKey }
        let horizontal = edge == .left || edge == .right

        var candidates: [CGFloat] = horizontal ? [bounds.minX, bounds.maxX] : [bounds.minY, bounds.maxY]
        for neighbour in neighbours {
            let other = neighbour.relativeFrame
            candidates += horizontal ? [other.minX, other.maxX] : [other.minY, other.maxY]
        }

        // An edge may only move to somewhere that leaves the region a real size.
        let current: CGFloat
        let usable: [CGFloat]
        switch edge {
        case .left:
            current = frame.minX
            usable = candidates.filter { $0 <= frame.maxX - minimumRegionEdge }
        case .right:
            current = frame.maxX
            usable = candidates.filter { $0 >= frame.minX + minimumRegionEdge }
        case .top:
            current = frame.minY
            usable = candidates.filter { $0 <= frame.maxY - minimumRegionEdge }
        case .bottom:
            current = frame.maxY
            usable = candidates.filter { $0 >= frame.minY + minimumRegionEdge }
        }

        guard let target = usable
            .filter({ abs($0 - current) > 0.5 })
            .min(by: { abs($0 - current) < abs($1 - current) }) else {
            return nil
        }

        var moved = region
        switch edge {
        case .left:   moved.relativeFrame = CGRect(x: target, y: frame.minY,
                                                   width: frame.maxX - target, height: frame.height)
        case .right:  moved.relativeFrame = CGRect(x: frame.minX, y: frame.minY,
                                                   width: target - frame.minX, height: frame.height)
        case .top:    moved.relativeFrame = CGRect(x: frame.minX, y: target,
                                                   width: frame.width, height: frame.maxY - target)
        case .bottom: moved.relativeFrame = CGRect(x: frame.minX, y: frame.minY,
                                                   width: frame.width, height: target - frame.minY)
        }
        return moved
    }

    /// What `snap` would move an edge to, for labelling the menu item.
    static func snapTarget(
        _ region: Region,
        edge: Edge,
        against others: [Region],
        on display: DisplayRegistry.ResolvedDisplay
    ) -> CGFloat? {
        guard let moved = snap(region, edge: edge, against: others, on: display) else { return nil }
        switch edge {
        case .left: return moved.relativeFrame.minX
        case .right: return moved.relativeFrame.maxX
        case .top: return moved.relativeFrame.minY
        case .bottom: return moved.relativeFrame.maxY
        }
    }

    // MARK: - Helpers

    /// "Center" becomes "Center 2", then "Center 3", and so on.
    static func uniqueName(basedOn base: String, avoiding taken: [String]) -> String {
        guard taken.contains(base) else { return base }
        var index = 2
        while taken.contains("\(base) \(index)") {
            index += 1
        }
        return "\(base) \(index)"
    }

    private static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let width = min(rect.width, bounds.width)
        let height = min(rect.height, bounds.height)
        let x = min(max(rect.minX, bounds.minX), bounds.maxX - width)
        let y = min(max(rect.minY, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
