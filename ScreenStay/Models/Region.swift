import Foundation
import CoreGraphics

/// A rectangular slot on one display where assigned apps are placed.
///
/// The geometry is stored **relative to the owning display**: the origin is the
/// display's top-left corner and y grows downward, matching AX orientation. It
/// is deliberately not absolute - absolute coordinates depend on which monitor
/// is primary and on how the displays are arranged, so they break as soon as
/// anything moves. Use `RegionGeometry` to resolve a region to real coordinates.
struct Region: Codable, Identifiable, Sendable, Equatable {
    let id: String
    var name: String
    /// Stable key of the display this region lives on, see `DisplayIdentity`.
    /// Nil only in a v1 config that has not been migrated yet.
    var displayKey: String?
    /// Position and size in points, measured from the display's top-left.
    var relativeFrame: CGRect
    var assignedApps: [String] // Bundle identifiers like "com.apple.Terminal"
    var keyboardShortcut: KeyboardShortcut?
    var isFocusRegion: Bool = false  // Whether this is the focus region for the profile

    /// Per-region padding recorded by configs before v3, when the gutter between
    /// tiled windows was stored once per region instead of once per app. Read
    /// during migration to pick the global `windowGap`, then dropped.
    var legacyPadding: CGFloat?

    /// Display ID recorded by v1 configs. Volatile and meaningless across
    /// reboots, so it is read once during migration to work out which display a
    /// legacy absolute frame belonged to, then dropped. Never encoded.
    var legacyDisplayID: CGDirectDisplayID?

    enum CodingKeys: String, CodingKey {
        case id, name, displayKey, relativeFrame, assignedApps, keyboardShortcut, isFocusRegion
        // pre-v3 only
        case padding
        // v1 only
        case displayID, frame
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        assignedApps = try container.decode([String].self, forKey: .assignedApps)
        keyboardShortcut = try container.decodeIfPresent(KeyboardShortcut.self, forKey: .keyboardShortcut)
        legacyPadding = try container.decodeIfPresent(CGFloat.self, forKey: .padding)
        isFocusRegion = try container.decodeIfPresent(Bool.self, forKey: .isFocusRegion) ?? false

        displayKey = try container.decodeIfPresent(String.self, forKey: .displayKey)
        legacyDisplayID = try container.decodeIfPresent(CGDirectDisplayID.self, forKey: .displayID)

        // A v1 config carries an absolute `frame`; migration rebases it against
        // the owning display and rewrites it as `relativeFrame`.
        if let relative = try container.decodeIfPresent(CGRect.self, forKey: .relativeFrame) {
            relativeFrame = relative
        } else if let absolute = try container.decodeIfPresent(CGRect.self, forKey: .frame) {
            relativeFrame = absolute
        } else {
            throw DecodingError.keyNotFound(CodingKeys.relativeFrame, DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Region has neither 'relativeFrame' nor a legacy 'frame'"
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(displayKey, forKey: .displayKey)
        try container.encode(relativeFrame, forKey: .relativeFrame)
        try container.encode(assignedApps, forKey: .assignedApps)
        try container.encodeIfPresent(keyboardShortcut, forKey: .keyboardShortcut)
        try container.encode(isFocusRegion, forKey: .isFocusRegion)
        // legacyPadding, legacyDisplayID and the v1 `frame` are not written back.
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        displayKey: String?,
        relativeFrame: CGRect,
        assignedApps: [String] = [],
        keyboardShortcut: KeyboardShortcut? = nil,
        isFocusRegion: Bool = false
    ) {
        self.id = id
        self.name = name
        self.displayKey = displayKey
        self.relativeFrame = relativeFrame
        self.assignedApps = assignedApps
        self.keyboardShortcut = keyboardShortcut
        self.isFocusRegion = isFocusRegion
        self.legacyPadding = nil
        self.legacyDisplayID = nil
    }
}

/// Keyboard shortcut configuration
struct KeyboardShortcut: Codable, Sendable, Equatable {
    var modifiers: [String] // ["cmd", "shift", "option", "control"]
    var key: String // Single character or special key name

    /// Convert to Carbon key code equivalent flags
    var carbonFlags: Int {
        var flags = 0
        if modifiers.contains("cmd") { flags |= 0x0100 /* cmdKey */ }
        if modifiers.contains("shift") { flags |= 0x0200 /* shiftKey */ }
        if modifiers.contains("option") { flags |= 0x0800 /* optionKey */ }
        if modifiers.contains("control") { flags |= 0x1000 /* controlKey */ }
        return flags
    }
}
