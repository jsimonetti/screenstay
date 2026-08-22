import Foundation

/// A profile containing regions and display topology for auto-matching
struct Profile: Codable, Identifiable, Sendable {
    let id: String
    var name: String
    var displayTopology: DisplayTopology
    var regions: [Region]
    var isActive: Bool  // Runtime only - not persisted

    // Exclude isActive from persistence.
    //
    // A `floatingWindows` key from older configs is ignored on read and dropped
    // on the next save. Nothing ever read it, and its frames were absolute
    // coordinates from before regions became display-relative, so there is
    // nothing worth migrating.
    enum CodingKeys: String, CodingKey {
        case id, name, displayTopology, regions
    }
    
    init(
        id: String = UUID().uuidString,
        name: String,
        displayTopology: DisplayTopology,
        regions: [Region] = [],
        isActive: Bool = false
    ) {
        self.id = id
        self.name = name
        self.displayTopology = displayTopology
        self.regions = regions
        self.isActive = isActive
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        displayTopology = try container.decode(DisplayTopology.self, forKey: .displayTopology)
        regions = try container.decode([Region].self, forKey: .regions)
        isActive = false  // Always start inactive
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(displayTopology, forKey: .displayTopology)
        try container.encode(regions, forKey: .regions)
        // isActive is not encoded
    }
    
    /// How well this profile fits the given live topology, or nil if it does not.
    ///
    /// Scored rather than boolean so that when several profiles describe the
    /// same set of monitors, the one that knows their exact identities - and
    /// their arrangement - wins over one that only knows their resolutions.
    func match(against topology: DisplayTopology) -> DisplayTopology.Match? {
        return displayTopology.match(against: topology)
    }
}
