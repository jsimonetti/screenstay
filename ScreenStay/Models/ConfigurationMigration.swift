import Foundation
import CoreGraphics

/// Upgrades configuration files written by older versions of ScreenStay.
enum ConfigurationMigration {

    /// Latest schema version.
    ///
    /// v2 introduced stable display keys and display-relative region geometry.
    /// v3 replaced per-region padding with a single global window gap.
    static let currentVersion = "3.0"

    /// Gutter used when a configuration has nothing to infer one from.
    static let defaultWindowGap: Double = 3

    /// Bring a configuration up to `currentVersion`. Returns true if anything changed.
    ///
    /// Steps are chained, so a v1 file passes through v2 on its way to v3.
    static func migrateIfNeeded(_ config: inout AppConfiguration) -> Bool {
        guard config.version != currentVersion else {
            return false
        }

        log("Migrating configuration from version \(config.version) to \(currentVersion)")

        if config.version == "1.0" {
            migrateToV2(&config)
        }
        migrateToV3(&config)

        config.version = currentVersion
        return true
    }

    // MARK: - v1 -> v2

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
    private static func migrateToV2(_ config: inout AppConfiguration) {
        for profileIndex in config.profiles.indices {
            migrateProfile(&config.profiles[profileIndex])
        }
    }

    // MARK: - v2 -> v3

    /// Replace per-region padding with one global gap.
    ///
    /// Padding was an inset baked into every region. Hoisting it out keeps
    /// adjacent regions sharing exact edges, which is what the layout editor
    /// needs in order to offer a single handle for a shared boundary.
    ///
    /// The new gap is whichever padding value the configuration used most, so
    /// the common case keeps the spacing it had. Regions that disagreed with
    /// the majority shift by the difference, which is logged.
    private static func migrateToV3(_ config: inout AppConfiguration) {
        let paddings = config.profiles.flatMap { $0.regions.compactMap(\.legacyPadding) }

        let gap: Double
        if paddings.isEmpty {
            gap = defaultWindowGap
        } else {
            var counts: [CGFloat: Int] = [:]
            for padding in paddings {
                counts[padding, default: 0] += 1
            }
            // Most common wins; on a tie prefer the tighter gap.
            let best = counts.max { lhs, rhs in
                lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
            }
            gap = Double(best?.key ?? CGFloat(defaultWindowGap))
        }

        config.globalSettings.windowGap = gap
        log("Migration: window gap set to \(Int(gap)) pt, from \(paddings.count) region padding values")

        for profileIndex in config.profiles.indices {
            for regionIndex in config.profiles[profileIndex].regions.indices {
                let region = config.profiles[profileIndex].regions[regionIndex]
                if let padding = region.legacyPadding, Double(padding) != gap {
                    log("Migration: region '\(region.name)' in profile "
                        + "'\(config.profiles[profileIndex].name)' had padding \(Int(padding)); "
                        + "now uses the global gap of \(Int(gap)) pt")
                }
                config.profiles[profileIndex].regions[regionIndex].legacyPadding = nil
            }
        }
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
