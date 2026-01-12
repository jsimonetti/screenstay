import Foundation
import AppKit

/// Actor responsible for managing profiles and configuration persistence
actor ProfileManager {
    private var configuration: AppConfiguration
    private let configURL: URL
    
    /// Active profile (if any)
    var activeProfile: Profile? {
        configuration.profiles.first { $0.isActive }
    }
    
    /// All regions from the active profile
    var activeRegions: [Region] {
        activeProfile?.regions ?? []
    }
    
    init() {
        // Configuration file location: ~/Library/Application Support/ScreenStay/config.json
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        
        let screenStayDir = appSupport.appendingPathComponent("ScreenStay")
        self.configURL = screenStayDir.appendingPathComponent("config.json")
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(
            at: screenStayDir,
            withIntermediateDirectories: true
        )
        
        // Load configuration or create default
        if let data = try? Data(contentsOf: configURL) {
            do {
                let config = try JSONDecoder().decode(AppConfiguration.self, from: data)
                self.configuration = config
                log("Configuration loaded")
            } catch _ as DecodingError {
                log("Failed to decode configuration, using defaults")
                self.configuration = AppConfiguration()
            } catch {
                self.configuration = AppConfiguration()
            }
        } else {
            self.configuration = AppConfiguration()
        }
    }
    
    // MARK: - Access
    
    /// Get the current configuration
    func getConfiguration() -> AppConfiguration {
        return configuration
    }
    
    /// Update the configuration
    func updateConfiguration(_ newConfig: AppConfiguration) {
        self.configuration = newConfig
    }
    
    /// Save configuration to disk
    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        try data.write(to: configURL)
        print("💾 Saved configuration to \(configURL.path)")
    }
    
    /// Reload configuration from disk
    func reload() throws {
        log("Reloading configuration")
        let data = try Data(contentsOf: configURL)
        do {
            configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)
        } catch let decodingError as DecodingError {
            throw decodingError
        } catch {
            throw error
        }
    }
    
    /// Find and activate a profile matching the current display topology
    func autoSelectProfile() async -> Profile? {
        let currentTopology = await MainActor.run {
            DisplayTopology.current()
        }
        
        // Deactivate all profiles first
        for i in 0..<configuration.profiles.count {
            configuration.profiles[i].isActive = false
        }
        
        // Find matching profile
        if let index = configuration.profiles.firstIndex(where: { $0.matches(currentTopology) }) {
            configuration.profiles[index].isActive = true
            let profile = configuration.profiles[index]
            return profile
        } else {
            return nil
        }
    }
    
    /// Get the configuration file URL for external editing
    func getConfigURL() -> URL {
        return configURL
    }
    
    /// Get a profile by ID
    func getProfile(by id: String) -> Profile? {
        return configuration.profiles.first { $0.id == id }
    }
    
    /// Set the active profile
    func setActiveProfile(_ profile: Profile) {
        // Deactivate all profiles
        for i in 0..<configuration.profiles.count {
            configuration.profiles[i].isActive = false
        }
        
        // Activate the specified profile
        if let index = configuration.profiles.firstIndex(where: { $0.id == profile.id }) {
            configuration.profiles[index].isActive = true
        }
    }
}
