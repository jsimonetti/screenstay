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
                log("✅ Loaded configuration from \(configURL.path)")
            } catch let decodingError as DecodingError {
                log("⚠️ Failed to decode config during init:")
                switch decodingError {
                case .typeMismatch(let type, let context):
                    log("   Type mismatch for \(type) at \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")
                case .dataCorrupted(let context):
                    log("   Data corrupted at \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")
                    log("   Description: \(context.debugDescription)")
                default:
                    log("   \(decodingError)")
                }
                self.configuration = AppConfiguration()
                log("ℹ️ Created default configuration instead")
            } catch {
                log("⚠️ Other error loading config: \(error)")
                self.configuration = AppConfiguration()
                log("ℹ️ Created default configuration instead")
            }
        } else {
            self.configuration = AppConfiguration()
            log("ℹ️ Created default configuration at \(configURL.path)")
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
        log("🔄 Attempting to reload from \(configURL.path)")
        let data = try Data(contentsOf: configURL)
        log("   Loaded \(data.count) bytes")
        do {
            configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)
            log("✅ Reloaded configuration from \(configURL.path)")
        } catch let decodingError as DecodingError {
            switch decodingError {
            case .typeMismatch(let type, let context):
                log("❌ Type mismatch for \(type)")
                log("   Path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")
                log("   Debug: \(context.debugDescription)")
            case .keyNotFound(let key, let context):
                log("❌ Key not found: \(key.stringValue)")
                log("   Path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")
            case .valueNotFound(let type, let context):
                log("❌ Value not found for \(type)")
                log("   Path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")
            case .dataCorrupted(let context):
                log("❌ Data corrupted")
                log("   Path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")
            @unknown default:
                log("❌ Unknown decoding error")
            }
            throw decodingError
        } catch {
            log("❌ Other error: \(error)")
            throw error
        }
    }
    
    /// Find and activate a profile matching the current display topology
    func autoSelectProfile() async -> Profile? {
        let currentTopology = await MainActor.run {
            DisplayTopology.current()
        }
        
        log("🔍 Auto-selecting profile for topology: \(currentTopology.fingerprint)")
        log("   Available profiles: \(configuration.profiles.count)")
        
        for (i, profile) in configuration.profiles.enumerated() {
            log("   [\(i)] \(profile.name): fingerprint=\(profile.displayTopology.fingerprint), matches=\(profile.matches(currentTopology))")
        }
        
        // Deactivate all profiles first
        for i in 0..<configuration.profiles.count {
            configuration.profiles[i].isActive = false
        }
        
        // Find matching profile
        if let index = configuration.profiles.firstIndex(where: { $0.matches(currentTopology) }) {
            configuration.profiles[index].isActive = true
            let profile = configuration.profiles[index]
            log("✅ Activated profile: \(profile.name) with \(profile.regions.count) regions")
            return profile
        } else {
            log("⚠️ No matching profile found for current topology")
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
            log("✅ Set active profile: \(profile.name)")
        }
    }
}
