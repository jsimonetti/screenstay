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
        var resetWindowShortcut: KeyboardShortcut?
        var focusWindowShortcut: KeyboardShortcut?
        var showFocusedWindowBorder: Bool
        var focusedWindowBorderColor: String
        var focusedWindowBorderWidth: Double
        
        enum CodingKeys: String, CodingKey {
            case enableAutoProfileSwitch, repositionOnAppLaunch, repositionOnDisplayChange, requireConfirmToLaunchApps, resetWindowShortcut, focusWindowShortcut, showFocusedWindowBorder, focusedWindowBorderColor, focusedWindowBorderWidth
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enableAutoProfileSwitch = try container.decode(Bool.self, forKey: .enableAutoProfileSwitch)
            repositionOnAppLaunch = try container.decode(Bool.self, forKey: .repositionOnAppLaunch)
            repositionOnDisplayChange = try container.decode(Bool.self, forKey: .repositionOnDisplayChange)
            requireConfirmToLaunchApps = try container.decodeIfPresent(Bool.self, forKey: .requireConfirmToLaunchApps) ?? false
            resetWindowShortcut = try container.decodeIfPresent(KeyboardShortcut.self, forKey: .resetWindowShortcut)
            focusWindowShortcut = try container.decodeIfPresent(KeyboardShortcut.self, forKey: .focusWindowShortcut)
            showFocusedWindowBorder = try container.decodeIfPresent(Bool.self, forKey: .showFocusedWindowBorder) ?? false
            focusedWindowBorderColor = try container.decodeIfPresent(String.self, forKey: .focusedWindowBorderColor) ?? "#FF6B00"
            focusedWindowBorderWidth = try container.decodeIfPresent(Double.self, forKey: .focusedWindowBorderWidth) ?? 4.0
        }
        
        init(
            enableAutoProfileSwitch: Bool,
            repositionOnAppLaunch: Bool,
            repositionOnDisplayChange: Bool,
            requireConfirmToLaunchApps: Bool,
            resetWindowShortcut: KeyboardShortcut? = nil,
            focusWindowShortcut: KeyboardShortcut? = nil,
            showFocusedWindowBorder: Bool = false,
            focusedWindowBorderColor: String = "#FF6B00",
            focusedWindowBorderWidth: Double = 4.0
        ) {
            self.enableAutoProfileSwitch = enableAutoProfileSwitch
            self.repositionOnAppLaunch = repositionOnAppLaunch
            self.repositionOnDisplayChange = repositionOnDisplayChange
            self.requireConfirmToLaunchApps = requireConfirmToLaunchApps
            self.resetWindowShortcut = resetWindowShortcut
            self.focusWindowShortcut = focusWindowShortcut
            self.showFocusedWindowBorder = showFocusedWindowBorder
            self.focusedWindowBorderColor = focusedWindowBorderColor
            self.focusedWindowBorderWidth = focusedWindowBorderWidth
        }
        
        static let `default` = GlobalSettings(
            enableAutoProfileSwitch: true,
            repositionOnAppLaunch: true,
            repositionOnDisplayChange: true,
            requireConfirmToLaunchApps: false,
            resetWindowShortcut: KeyboardShortcut(modifiers: ["cmd", "option"], key: "r"),
            focusWindowShortcut: KeyboardShortcut(modifiers: ["cmd", "option"], key: "f")
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
