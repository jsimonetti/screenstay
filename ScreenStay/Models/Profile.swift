import Foundation
import CoreGraphics

/// A profile containing regions and display topology for auto-matching
struct Profile: Codable, Identifiable, Sendable {
    let id: String
    var name: String
    var displayTopology: DisplayTopology
    var regions: [Region]
    var floatingWindows: [FloatingWindow]
    var isActive: Bool  // Runtime only - not persisted
    
    struct FloatingWindow: Codable, Sendable {
        var appBundleID: String
        var frame: CGRect
    }
    
    // Exclude isActive from persistence
    enum CodingKeys: String, CodingKey {
        case id, name, displayTopology, regions, floatingWindows
    }
    
    init(
        id: String = UUID().uuidString,
        name: String,
        displayTopology: DisplayTopology,
        regions: [Region] = [],
        floatingWindows: [FloatingWindow] = [],
        isActive: Bool = false
    ) {
        self.id = id
        self.name = name
        self.displayTopology = displayTopology
        self.regions = regions
        self.floatingWindows = floatingWindows
        self.isActive = isActive
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        displayTopology = try container.decode(DisplayTopology.self, forKey: .displayTopology)
        regions = try container.decode([Region].self, forKey: .regions)
        floatingWindows = try container.decode([FloatingWindow].self, forKey: .floatingWindows)
        isActive = false  // Always start inactive
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(displayTopology, forKey: .displayTopology)
        try container.encode(regions, forKey: .regions)
        try container.encode(floatingWindows, forKey: .floatingWindows)
        // isActive is not encoded
    }
    
    /// Check if this profile matches the given topology
    func matches(_ topology: DisplayTopology) -> Bool {
        return displayTopology.fingerprint == topology.fingerprint
    }
}
