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
                var config = try JSONDecoder().decode(AppConfiguration.self, from: data)
                if ConfigurationMigration.migrateIfNeeded(&config) {
                    Self.backUpConfiguration(at: configURL, data: data)
                    Self.writeConfiguration(config, to: configURL)
                }
                self.configuration = config
                log("Configuration loaded")
            } catch let error as DecodingError {
                log("Failed to decode configuration, using defaults: \(error)")
                self.configuration = AppConfiguration()
            } catch {
                self.configuration = AppConfiguration()
            }
        } else {
            self.configuration = AppConfiguration()
        }
    }

    // MARK: - Migration support

    /// Keep the pre-migration file around; the schema change is not reversible.
    private static func backUpConfiguration(at url: URL, data: Data) {
        let backupURL = url.deletingPathExtension().appendingPathExtension("v1.backup.json")
        do {
            try data.write(to: backupURL)
            log("Backed up pre-migration configuration to \(backupURL.path)")
        } catch {
            log("Could not back up configuration: \(error)")
        }
    }

    /// Persist immediately after migration so the upgrade survives a crash.
    private static func writeConfiguration(_ config: AppConfiguration, to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: url)
            log("Wrote migrated configuration")
        } catch {
            log("Could not write migrated configuration: \(error)")
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
    
    /// Find and activate the profile that best fits the attached displays.
    ///
    /// Every profile is scored rather than taking the first hit, so a profile
    /// that names the exact monitors beats one that merely has the same screen
    /// sizes, and among equals the one with the matching arrangement wins.
    func autoSelectProfile() async -> Profile? {
        let live = await MainActor.run {
            DisplayRegistry.shared.refresh()
            return DisplayTopology.current()
        }

        // Deactivate all profiles first
        for i in 0..<configuration.profiles.count {
            configuration.profiles[i].isActive = false
        }

        let scored = configuration.profiles.enumerated().compactMap { index, profile in
            profile.match(against: live).map { (index: index, match: $0) }
        }

        // max(by:) keeps the earliest element on a tie, so profile order stays
        // the tie-breaker the user can control.
        guard let best = scored.max(by: { $0.match.score < $1.match.score }) else {
            log("No profile matches the attached displays")
            return nil
        }

        configuration.profiles[best.index].isActive = true

        // First time this migrated profile has seen its real monitors: record
        // their identities so future matches are exact.
        if ConfigurationMigration.adoptLiveKeys(in: &configuration.profiles[best.index], match: best.match, live: live) {
            try? save()
        }

        let profile = configuration.profiles[best.index]
        log("Activated profile '\(profile.name)' (score \(best.match.score), "
            + "exact identity: \(best.match.isExactIdentity))")
        return profile
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
