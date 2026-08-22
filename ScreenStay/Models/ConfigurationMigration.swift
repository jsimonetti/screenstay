import Foundation
import CoreGraphics

/// Upgrades configuration files written by older versions of ScreenStay.
enum ConfigurationMigration {

    /// Schema version introducing stable display keys and display-relative
    /// region geometry.
    static let currentVersion = "2.0"

    // MARK: - v1 -> v2

    /// Rewrite a v1 configuration in place. Returns true if anything changed.
    ///
    /// v1 stored region frames as absolute coordinates in the global AX space
    /// and identified displays by the volatile `CGDirectDisplayID`. v2 stores
    /// frames relative to the owning display and identifies displays by a
    /// stable key, so a profile keeps working when monitors are rearranged or
    /// reconnected.
    ///
    /// Displays are given provisional `legacy:` keys here, because the monitors
    /// a stored profile describes are usually not the ones attached right now -
    /// there is no EDID data to read. Those keys are upgraded to real ones by
    /// `adoptLiveKeys` the first time the profile matches attached hardware.
    static func migrateIfNeeded(_ config: inout AppConfiguration) -> Bool {
        guard config.version != currentVersion else {
            return false
        }

        log("Migrating configuration from version \(config.version) to \(currentVersion)")

        for profileIndex in config.profiles.indices {
            migrateProfile(&config.profiles[profileIndex])
        }

        config.version = currentVersion
        return true
    }

    private static func migrateProfile(_ profile: inout Profile) {
        let displays = profile.displayTopology.displays

        // Provisional keys derived from what v1 actually recorded.
        let legacyKeys = DisplayIdentity.legacyKeys(for: displays.map {
            (id: $0.displayID, isBuiltIn: $0.isBuiltIn, resolution: $0.resolution, position: $0.position)
        })

        for index in profile.displayTopology.displays.indices {
            let displayID = profile.displayTopology.displays[index].displayID
            profile.displayTopology.displays[index].key = legacyKeys[displayID]
        }

        for index in profile.regions.indices {
            migrateRegion(&profile.regions[index], displays: displays, legacyKeys: legacyKeys, profileName: profile.name)
        }
    }

    private static func migrateRegion(
        _ region: inout Region,
        displays: [DisplayTopology.DisplayInfo],
        legacyKeys: [CGDirectDisplayID: String],
        profileName: String
    ) {
        // At this point `relativeFrame` still holds the v1 absolute frame; the
        // decoder parks it there so migration has something to rebase.
        let absolute = region.relativeFrame

        guard let owner = owningDisplay(for: region, absolute: absolute, displays: displays) else {
            log("Migration: region '\(region.name)' in profile '\(profileName)' has no display to rebase against; leaving as-is")
            region.legacyDisplayID = nil
            return
        }

        let rebased = CGRect(
            x: absolute.origin.x - owner.position.x,
            y: absolute.origin.y - owner.position.y,
            width: absolute.width,
            height: absolute.height
        )

        // v1 let a region drift outside its own display - nothing ever checked.
        // Pull it back in, since that is unambiguously what the user meant.
        let displayBounds = CGRect(origin: .zero, size: owner.resolution)
        let clamped = clampToDisplay(rebased, bounds: displayBounds)
        if clamped != rebased {
            log("Migration: region '\(region.name)' in profile '\(profileName)' sat outside its display "
                + "(\(describe(rebased))); corrected to \(describe(clamped))")
        }

        region.relativeFrame = clamped
        region.displayKey = legacyKeys[owner.displayID]
        region.legacyDisplayID = nil
    }

    /// Work out which display a v1 region belonged to.
    ///
    /// The recorded display ID is trusted first; if it names a display the
    /// profile does not know about, fall back to whichever display the absolute
    /// frame overlaps most.
    private static func owningDisplay(
        for region: Region,
        absolute: CGRect,
        displays: [DisplayTopology.DisplayInfo]
    ) -> DisplayTopology.DisplayInfo? {
        if let displayID = region.legacyDisplayID,
           let match = displays.first(where: { $0.displayID == displayID }) {
            return match
        }

        let overlapping = displays
            .map { ($0, $0.axBounds.intersection(absolute)) }
            .filter { !$0.1.isNull && !$0.1.isEmpty }
            .max { lhs, rhs in (lhs.1.width * lhs.1.height) < (rhs.1.width * rhs.1.height) }

        return overlapping?.0 ?? displays.first
    }

    // MARK: - Legacy key adoption

    /// Replace provisional `legacy:` keys with the real identities of the
    /// displays a profile just matched. Returns true if anything changed.
    ///
    /// This is what makes migration self-healing: the first time you plug in
    /// the monitors a migrated profile describes, the profile records exactly
    /// which monitors those were, and from then on it matches on identity.
    static func adoptLiveKeys(
        in profile: inout Profile,
        match: DisplayTopology.Match,
        live: DisplayTopology
    ) -> Bool {
        var changed = false
        var rewrites: [String: String] = [:]

        for index in profile.displayTopology.displays.indices {
            guard let storedKey = profile.displayTopology.displays[index].key,
                  let liveKey = match.keyBindings[storedKey],
                  liveKey != storedKey,
                  let liveDisplay = live.displays.first(where: { $0.key == liveKey }) else {
                continue
            }

            profile.displayTopology.displays[index].key = liveKey
            profile.displayTopology.displays[index].displayID = liveDisplay.displayID
            profile.displayTopology.displays[index].position = liveDisplay.position
            profile.displayTopology.displays[index].name = liveDisplay.name
            rewrites[storedKey] = liveKey
            changed = true
        }

        guard changed else { return false }

        for index in profile.regions.indices {
            if let key = profile.regions[index].displayKey, let liveKey = rewrites[key] {
                profile.regions[index].displayKey = liveKey
            }
        }

        log("Profile '\(profile.name)': adopted display identities "
            + rewrites.map { "\($0.key) -> \($0.value)" }.joined(separator: ", "))
        return true
    }

    // MARK: - Helpers

    private static func clampToDisplay(_ rect: CGRect, bounds: CGRect) -> CGRect {
        let width = min(rect.width, bounds.width)
        let height = min(rect.height, bounds.height)
        let x = min(max(rect.origin.x, bounds.minX), bounds.maxX - width)
        let y = min(max(rect.origin.y, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func describe(_ rect: CGRect) -> String {
        "[\(Int(rect.origin.x)), \(Int(rect.origin.y))] [\(Int(rect.width)), \(Int(rect.height))]"
    }
}
