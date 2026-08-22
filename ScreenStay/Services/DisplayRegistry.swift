import AppKit
import CoreGraphics

/// Live view of the attached displays, addressable by stable key.
///
/// Everything that needs to turn a stored `Region` into real coordinates goes
/// through here, so there is a single place that knows which physical monitor a
/// key currently refers to. Refreshed on display reconfiguration.
@MainActor
final class DisplayRegistry {
    static let shared = DisplayRegistry()

    /// A currently attached display, with geometry in AX space.
    struct ResolvedDisplay {
        let key: String
        let displayID: CGDirectDisplayID
        let isBuiltIn: Bool
        let name: String
        /// Full display rect in AX space.
        let axBounds: CGRect
        /// Display rect minus the menu bar and Dock, in AX space. Useful for
        /// snapping in the layout editor; region geometry is *not* implicitly
        /// inset by it.
        let axVisibleBounds: CGRect
    }

    private(set) var displays: [ResolvedDisplay] = []

    private init() {
        refresh()
    }

    // MARK: - Lookup

    /// The display a key currently resolves to, if it is attached.
    func display(forKey key: String) -> ResolvedDisplay? {
        displays.first { $0.key == key }
    }

    /// The display containing a point given in AX space.
    func display(containingAX point: CGPoint) -> ResolvedDisplay? {
        displays.first { $0.axBounds.contains(point) }
    }

    /// The display whose area overlaps the given AX rect the most.
    ///
    /// Used when a rect straddles a boundary and a single owner must be picked.
    func display(bestMatchingAX rect: CGRect) -> ResolvedDisplay? {
        displays
            .map { ($0, $0.axBounds.intersection(rect)) }
            .filter { !$0.1.isNull && !$0.1.isEmpty }
            .max { lhs, rhs in
                (lhs.1.width * lhs.1.height) < (rhs.1.width * rhs.1.height)
            }?.0
    }

    /// The primary display, whose top-left is the AX origin.
    var primary: ResolvedDisplay? {
        displays.first { $0.axBounds.origin == .zero } ?? displays.first
    }

    // MARK: - Refresh

    /// Re-read the attached displays. Call on display reconfiguration.
    func refresh() {
        let maxDisplays: UInt32 = 16
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0

        guard CGGetActiveDisplayList(maxDisplays, &displayIDs, &displayCount) == .success else {
            displays = []
            return
        }

        let activeIDs = Array(displayIDs.prefix(Int(displayCount)))
        let keys = DisplayIdentity.keys(for: activeIDs)

        var screensByID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                screensByID[id] = screen
            }
        }

        displays = activeIDs.compactMap { displayID in
            guard let key = keys[displayID] else { return nil }

            let bounds = CGDisplayBounds(displayID)
            let screen = screensByID[displayID]

            // visibleFrame is Cocoa-space; bring it back to AX space so callers
            // never have to think about which space a bound is in.
            let visible = screen.map { CoordinateSpace.cocoaToAX($0.visibleFrame) } ?? bounds

            return ResolvedDisplay(
                key: key,
                displayID: displayID,
                isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
                name: screen?.localizedName ?? "Display \(displayID)",
                axBounds: bounds,
                axVisibleBounds: visible
            )
        }

        let summary = displays.map { "\($0.key)@\(Int($0.axBounds.minX)),\(Int($0.axBounds.minY))" }
        log("Display registry refreshed: \(summary.joined(separator: " "))")
    }
}
