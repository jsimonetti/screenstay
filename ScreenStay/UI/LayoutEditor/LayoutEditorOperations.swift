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

        // The edge of the placeable area is worth snapping to as well, so stored
        // geometry can be made to match where a window will actually land.
        if !horizontal {
            candidates.append(display.axPlacementBounds.minY - display.axBounds.minY)
            candidates.append(display.axPlacementBounds.maxY - display.axBounds.minY)
        }

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

// MARK: - Handles

extension LayoutEditorOperations {

    /// A draggable edge of a region.
    ///
    /// Handles are derived, not stored. When another region's opposite edge sits
    /// at exactly the same coordinate the two are treated as one boundary and
    /// dragging moves both, which is what gives a tiled layout divider
    /// behaviour without the model being a partition.
    struct Handle {
        let edge: Edge
        let regionID: String
        /// Regions whose opposite edge coincides with this one.
        let linkedRegionIDs: [String]
        /// Pill in display-relative coordinates, for drawing and hit testing.
        let rect: CGRect

        var isLinked: Bool { !linkedRegionIDs.isEmpty }
        var isHorizontalEdge: Bool { edge == .top || edge == .bottom }
    }

    /// Long side of a handle pill.
    static let handleLength: CGFloat = 34
    /// Short side of a handle pill.
    static let handleThickness: CGFloat = 6
    /// How far from a pill still counts as grabbing it.
    static let handleGrabSlop: CGFloat = 6

    /// The four handles of a region, with any coincident neighbours recorded.
    static func handles(for region: Region, among all: [Region]) -> [Handle] {
        let frame = region.relativeFrame
        let neighbours = all.filter { $0.id != region.id && $0.displayKey == region.displayKey }

        return Edge.allCases.map { edge in
            let position = coordinate(of: edge, in: frame)

            // A divider is this edge meeting a neighbour's *opposite* edge.
            // Two regions merely aligned on the same side are not a boundary.
            let linked = neighbours.filter { neighbour in
                abs(coordinate(of: edge.opposite, in: neighbour.relativeFrame) - position) < 0.5
                    && overlaps(frame, neighbour.relativeFrame, alongEdge: edge)
            }.map(\.id)

            return Handle(edge: edge, regionID: region.id, linkedRegionIDs: linked,
                          rect: handleRect(for: edge, in: frame))
        }
    }

    static func handleRect(for edge: Edge, in frame: CGRect) -> CGRect {
        switch edge {
        case .left, .right:
            let x = edge == .left ? frame.minX : frame.maxX
            return CGRect(x: x - handleThickness / 2, y: frame.midY - handleLength / 2,
                          width: handleThickness, height: handleLength)
        case .top, .bottom:
            let y = edge == .top ? frame.minY : frame.maxY
            return CGRect(x: frame.midX - handleLength / 2, y: y - handleThickness / 2,
                          width: handleLength, height: handleThickness)
        }
    }

    /// Move a handle's edge, carrying any linked neighbours with it.
    static func resize(
        _ regions: [Region],
        handle: Handle,
        toRelative value: CGFloat,
        on display: DisplayRegistry.ResolvedDisplay
    ) -> [Region] {
        guard let index = regions.firstIndex(where: { $0.id == handle.regionID }) else { return regions }

        let bounds = CGRect(origin: .zero, size: display.axBounds.size)
        let frame = regions[index].relativeFrame

        // Keep the dragged region a usable size and inside its display.
        let clamped: CGFloat
        switch handle.edge {
        case .left:   clamped = min(max(value, bounds.minX), frame.maxX - minimumRegionEdge)
        case .right:  clamped = max(min(value, bounds.maxX), frame.minX + minimumRegionEdge)
        case .top:    clamped = min(max(value, bounds.minY), frame.maxY - minimumRegionEdge)
        case .bottom: clamped = max(min(value, bounds.maxY), frame.minY + minimumRegionEdge)
        }

        var result = regions
        result[index].relativeFrame = apply(handle.edge, at: clamped, to: frame)

        // Linked neighbours follow, so a shared boundary stays shared.
        for linkedID in handle.linkedRegionIDs {
            guard let other = result.firstIndex(where: { $0.id == linkedID }) else { continue }
            let otherFrame = result[other].relativeFrame
            let moved = apply(handle.edge.opposite, at: clamped, to: otherFrame)
            // Refuse to crush the neighbour; leave it be rather than invert it.
            if moved.width >= minimumRegionEdge && moved.height >= minimumRegionEdge {
                result[other].relativeFrame = moved
            }
        }
        return result
    }

    /// Translate a region, keeping it inside its display.
    static func move(
        _ region: Region,
        toRelativeOrigin origin: CGPoint,
        on display: DisplayRegistry.ResolvedDisplay
    ) -> Region {
        let bounds = CGRect(origin: .zero, size: display.axBounds.size)
        let frame = region.relativeFrame
        var moved = region
        moved.relativeFrame = CGRect(
            x: min(max(origin.x, 0), max(0, bounds.width - frame.width)),
            y: min(max(origin.y, 0), max(0, bounds.height - frame.height)),
            width: frame.width,
            height: frame.height
        )
        return moved
    }

    // MARK: - Edge helpers

    static func coordinate(of edge: Edge, in frame: CGRect) -> CGFloat {
        switch edge {
        case .left: return frame.minX
        case .right: return frame.maxX
        case .top: return frame.minY
        case .bottom: return frame.maxY
        }
    }

    private static func apply(_ edge: Edge, at value: CGFloat, to frame: CGRect) -> CGRect {
        switch edge {
        case .left:   return CGRect(x: value, y: frame.minY, width: frame.maxX - value, height: frame.height)
        case .right:  return CGRect(x: frame.minX, y: frame.minY, width: value - frame.minX, height: frame.height)
        case .top:    return CGRect(x: frame.minX, y: value, width: frame.width, height: frame.maxY - value)
        case .bottom: return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: value - frame.minY)
        }
    }

    /// Whether two regions actually run alongside each other at a shared edge,
    /// rather than merely having the same coordinate somewhere far away.
    private static func overlaps(_ a: CGRect, _ b: CGRect, alongEdge edge: Edge) -> Bool {
        switch edge {
        case .left, .right:
            return min(a.maxY, b.maxY) - max(a.minY, b.minY) > 0
        case .top, .bottom:
            return min(a.maxX, b.maxX) - max(a.minX, b.minX) > 0
        }
    }
}

extension LayoutEditorOperations.Edge: CaseIterable {
    var opposite: LayoutEditorOperations.Edge {
        switch self {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        }
    }
}
