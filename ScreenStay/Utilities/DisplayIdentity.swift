import AppKit
import CoreGraphics

/// Builds stable, persistable identifiers for displays.
///
/// `CGDirectDisplayID` is deliberately not used for persistence: macOS reassigns
/// it across reboots, sleep and reconnects, so a config written today can point
/// at a different physical monitor tomorrow. Instead we derive a key from the
/// EDID-backed vendor / model / serial triple, which survives replugging.
///
/// Not every display fills that triple in - AirPlay, virtual and some budget
/// monitors report zeroes - so the key falls back through progressively weaker
/// forms, and identical keys are disambiguated by arrangement order.
enum DisplayIdentity {

    /// Prefix marking a key synthesised from a pre-2.0 config, where the real
    /// EDID data was never recorded and the display may not even be attached.
    ///
    /// Legacy keys match live displays on (built-in, resolution) rather than on
    /// identity, and are upgraded to a real key the first time the profile is
    /// matched against attached hardware. See `DisplayTopology.bind(to:)`.
    static let legacyPrefix = "legacy:"

    /// Whether a key is a provisional key carried over from a v1 config.
    static func isLegacy(_ key: String) -> Bool {
        key.hasPrefix(legacyPrefix)
    }

    // MARK: - Live keys

    /// Base key for a currently attached display, before collision handling.
    private static func baseKey(for displayID: CGDirectDisplayID) -> String {
        if CGDisplayIsBuiltin(displayID) != 0 {
            // There is only ever one built-in panel, and identifying it by name
            // rather than EDID keeps configs portable across logic-board swaps.
            return "builtin"
        }

        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        let bounds = CGDisplayBounds(displayID)
        let size = "\(Int(bounds.width))x\(Int(bounds.height))"

        // kDisplayVendorIDUnknown / kDisplayProductIDGeneric come back as these.
        let vendorKnown = vendor != 0 && vendor != 0xFFFF_FFFF
        let modelKnown = model != 0 && model != 0xFFFF_FFFF

        guard vendorKnown || modelKnown else {
            return "ext:unknown-\(size)"
        }

        if serial != 0 && serial != 0xFFFF_FFFF {
            return "ext:v\(vendor)-m\(model)-s\(serial)"
        }

        // No serial: two identical monitors share this key and get separated by
        // the arrangement-order suffix added in `keys(for:)`.
        return "ext:v\(vendor)-m\(model)-\(size)"
    }

    /// Stable keys for the given displays, keyed by `CGDirectDisplayID`.
    ///
    /// Displays producing the same base key are suffixed `#0`, `#1`, ... in
    /// left-to-right, top-to-bottom arrangement order. Physically swapping two
    /// serial-less identical monitors therefore swaps their keys; nothing short
    /// of an EDID serial can distinguish them.
    static func keys(for displayIDs: [CGDirectDisplayID]) -> [CGDirectDisplayID: String] {
        let ordered = displayIDs.sorted { lhs, rhs in
            let a = CGDisplayBounds(lhs)
            let b = CGDisplayBounds(rhs)
            if a.origin.x != b.origin.x { return a.origin.x < b.origin.x }
            return a.origin.y < b.origin.y
        }

        return disambiguate(ordered.map { ($0, baseKey(for: $0)) })
    }

    // MARK: - Legacy keys

    /// Provisional keys for displays described by a v1 config, which records
    /// only built-in-ness, resolution and position.
    static func legacyKeys(for displays: [(id: CGDirectDisplayID, isBuiltIn: Bool, resolution: CGSize, position: CGPoint)])
        -> [CGDirectDisplayID: String] {
        let ordered = displays.sorted { lhs, rhs in
            if lhs.position.x != rhs.position.x { return lhs.position.x < rhs.position.x }
            return lhs.position.y < rhs.position.y
        }

        let based = ordered.map { display -> (CGDirectDisplayID, String) in
            let base = display.isBuiltIn
                ? "\(legacyPrefix)builtin"
                : "\(legacyPrefix)\(Int(display.resolution.width))x\(Int(display.resolution.height))"
            return (display.id, base)
        }

        return disambiguate(based)
    }

    // MARK: - Helpers

    /// Append `#n` to any key claimed by more than one display, preserving the
    /// order the pairs arrive in.
    private static func disambiguate(_ pairs: [(CGDirectDisplayID, String)]) -> [CGDirectDisplayID: String] {
        var counts: [String: Int] = [:]
        for (_, base) in pairs {
            counts[base, default: 0] += 1
        }

        var used: [String: Int] = [:]
        var result: [CGDirectDisplayID: String] = [:]
        for (id, base) in pairs {
            if counts[base, default: 0] > 1 {
                let index = used[base, default: 0]
                used[base] = index + 1
                result[id] = "\(base)#\(index)"
            } else {
                result[id] = base
            }
        }
        return result
    }
}
