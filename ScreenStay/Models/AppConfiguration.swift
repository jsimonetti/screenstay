import Foundation

/// Top-level application configuration
struct AppConfiguration: Codable, Sendable {
    var version: String
    var profiles: [Profile]
    var globalSettings: GlobalSettings
    
    struct GlobalSettings: Codable, Sendable {
        var enableAutoProfileSwitch: Bool
        var repositionOnAppLaunch: Bool
        var repositionOnDisplayChange: Bool
        var requireConfirmToLaunchApps: Bool
        
        enum CodingKeys: String, CodingKey {
            case enableAutoProfileSwitch, repositionOnAppLaunch, repositionOnDisplayChange, requireConfirmToLaunchApps
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enableAutoProfileSwitch = try container.decode(Bool.self, forKey: .enableAutoProfileSwitch)
            repositionOnAppLaunch = try container.decode(Bool.self, forKey: .repositionOnAppLaunch)
            repositionOnDisplayChange = try container.decode(Bool.self, forKey: .repositionOnDisplayChange)
            requireConfirmToLaunchApps = try container.decodeIfPresent(Bool.self, forKey: .requireConfirmToLaunchApps) ?? false
        }
        
        init(
            enableAutoProfileSwitch: Bool,
            repositionOnAppLaunch: Bool,
            repositionOnDisplayChange: Bool,
            requireConfirmToLaunchApps: Bool
        ) {
            self.enableAutoProfileSwitch = enableAutoProfileSwitch
            self.repositionOnAppLaunch = repositionOnAppLaunch
            self.repositionOnDisplayChange = repositionOnDisplayChange
            self.requireConfirmToLaunchApps = requireConfirmToLaunchApps
        }
        
        static let `default` = GlobalSettings(
            enableAutoProfileSwitch: true,
            repositionOnAppLaunch: true,
            repositionOnDisplayChange: true,
            requireConfirmToLaunchApps: false
        )
    }
    
    init(
        version: String = "1.0",
        profiles: [Profile] = [],
        globalSettings: GlobalSettings = .default
    ) {
        self.version = version
        self.profiles = profiles
        self.globalSettings = globalSettings
    }
}
