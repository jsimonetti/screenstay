import Foundation
import CoreGraphics

/// Represents a rectangular region on a display where windows can be positioned
struct Region: Codable, Identifiable, Sendable {
    let id: String
    var name: String
    var displayID: CGDirectDisplayID
    var frame: CGRect
    var assignedApps: [String] // Bundle identifiers like "com.apple.Terminal"
    var keyboardShortcut: KeyboardShortcut?
    var padding: CGFloat = 0  // Padding in pixels to apply to all edges
    var isFocusRegion: Bool = false  // Whether this is the focus region for the profile
    
    enum CodingKeys: String, CodingKey {
        case id, name, displayID, frame, assignedApps, keyboardShortcut, padding, isFocusRegion
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        displayID = try container.decode(CGDirectDisplayID.self, forKey: .displayID)
        frame = try container.decode(CGRect.self, forKey: .frame)
        assignedApps = try container.decode([String].self, forKey: .assignedApps)
        keyboardShortcut = try container.decodeIfPresent(KeyboardShortcut.self, forKey: .keyboardShortcut)
        padding = try container.decodeIfPresent(CGFloat.self, forKey: .padding) ?? 0
        isFocusRegion = try container.decodeIfPresent(Bool.self, forKey: .isFocusRegion) ?? false
    }
    
    init(
        id: String = UUID().uuidString,
        name: String,
        displayID: CGDirectDisplayID,
        frame: CGRect,
        assignedApps: [String] = [],
        keyboardShortcut: KeyboardShortcut? = nil,
        padding: CGFloat = 0,
        isFocusRegion: Bool = false
    ) {
        self.id = id
        self.name = name
        self.displayID = displayID
        self.frame = frame
        self.assignedApps = assignedApps
        self.keyboardShortcut = keyboardShortcut
        self.padding = padding
        self.isFocusRegion = isFocusRegion
    }
}

/// Keyboard shortcut configuration
struct KeyboardShortcut: Codable, Sendable {
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


