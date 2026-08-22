import Foundation
import AppKit
import CoreGraphics

/// A snapshot of a display arrangement, used to pick the right profile.
///
/// All geometry here is in **AX space** (origin at the top-left of the primary
/// display, y growing down), matching `CGDisplayBounds`. There is exactly one
/// capture path - `current()` - so a persisted `position` always means the same
/// thing regardless of which part of the app wrote it.
struct DisplayTopology: Codable, Equatable, Sendable {
    var displays: [DisplayInfo]
    var externalMonitorCount: Int

    struct DisplayInfo: Codable, Equatable, Sendable {
        /// Stable identity, see `DisplayIdentity`. Nil only in a v1 config that
        /// has not been migrated yet.
        var key: String?
        /// Volatile session-local ID. Never persisted for matching purposes;
        /// kept so the UI can talk to CoreGraphics about a live display.
        var displayID: CGDirectDisplayID
        var resolution: CGSize
        /// Top-left of the display in AX space.
        var position: CGPoint
        var isBuiltIn: Bool
        /// Human-readable name for the settings UI, when AppKit offers one.
        var name: String?

        enum CodingKeys: String, CodingKey {
            case key, displayID, resolution, position, isBuiltIn, name
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decodeIfPresent(String.self, forKey: .key)
            displayID = try container.decode(CGDirectDisplayID.self, forKey: .displayID)
            resolution = try container.decode(CGSize.self, forKey: .resolution)
            position = try container.decode(CGPoint.self, forKey: .position)
            isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
            name = try container.decodeIfPresent(String.self, forKey: .name)
        }

        init(
            key: String?,
            displayID: CGDirectDisplayID,
            resolution: CGSize,
            position: CGPoint,
            isBuiltIn: Bool,
            name: String? = nil
        ) {
            self.key = key
            self.displayID = displayID
            self.resolution = resolution
            self.position = position
            self.isBuiltIn = isBuiltIn
            self.name = name
        }

        /// Frame of the display in AX space.
        var axBounds: CGRect {
            CGRect(origin: position, size: resolution)
        }
    }

    // MARK: - Capture

    /// Capture the current arrangement of all active displays.
    ///
    /// Uses CoreGraphics rather than `NSScreen` so the result is natively in AX
    /// space and includes displays AppKit may not surface.
    @MainActor
    static func current() -> DisplayTopology {
        let maxDisplays: UInt32 = 16
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0

        guard CGGetActiveDisplayList(maxDisplays, &displayIDs, &displayCount) == .success else {
            return DisplayTopology(displays: [], externalMonitorCount: 0)
        }

        let activeIDs = Array(displayIDs.prefix(Int(displayCount)))
        let keys = DisplayIdentity.keys(for: activeIDs)

        // NSScreen is only consulted for the human-readable name.
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                names[id] = screen.localizedName
            }
        }

        var displays: [DisplayInfo] = []
        var externalCount = 0

        for displayID in activeIDs {
            let bounds = CGDisplayBounds(displayID)
            let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0
            if !isBuiltIn {
                externalCount += 1
            }

            displays.append(DisplayInfo(
                key: keys[displayID],
                displayID: displayID,
                resolution: bounds.size,
                position: bounds.origin,
                isBuiltIn: isBuiltIn,
                name: names[displayID]
            ))
        }

        // Stable, arrangement-independent ordering so persisted configs do not
        // churn when CoreGraphics reorders the active list.
        displays.sort { ($0.key ?? "") < ($1.key ?? "") }

        return DisplayTopology(displays: displays, externalMonitorCount: externalCount)
    }

    // MARK: - Matching

    /// How a profile's stored topology lines up with an attached arrangement.
    struct Match {
        /// Maps a display key as stored in the profile to the key of the live
        /// display it was bound to. Identical entries mean the profile is
        /// already using real identities.
        var keyBindings: [String: String]
        /// Sum of per-display confidence plus the arrangement bonus. Higher wins.
        var score: Int
        /// True when every display was matched on identity rather than on a
        /// resolution fallback.
        var isExactIdentity: Bool
    }

    /// Score awarded for a display matched on its stable identity key.
    private static let identityWeight = 4
    /// Score awarded for a display matched only on built-in-ness and resolution.
    private static let resolutionWeight = 1
    /// Bonus when the displays also sit in the same relative positions.
    private static let arrangementBonus = 2

    /// Attempt to bind every display in `self` to a distinct display in `live`.
    ///
    /// Returns nil when no complete one-to-one binding exists, which is what
    /// "this profile is not for this hardware" means. A binding is preferred if
    /// it matches on identity; matching purely on resolution still succeeds but
    /// scores lower, so a profile that knows the exact monitor always beats a
    /// profile that only knows its size.
    func match(against live: DisplayTopology) -> Match? {
        guard displays.count == live.displays.count, !displays.isEmpty else {
            return nil
        }

        var remainingLive = live.displays
        var bindings: [String: String] = [:]
        var boundPairs: [(mine: DisplayInfo, live: DisplayInfo)] = []
        var score = 0
        var identityMatches = 0

        // Pass 1: exact identity. Keys are unique, so greedy is optimal here.
        var unmatched: [DisplayInfo] = []
        for mine in displays {
            guard let myKey = mine.key,
                  !DisplayIdentity.isLegacy(myKey),
                  let index = remainingLive.firstIndex(where: { $0.key == myKey }) else {
                unmatched.append(mine)
                continue
            }

            let matched = remainingLive.remove(at: index)
            bindings[myKey] = matched.key ?? myKey
            boundPairs.append((mine, matched))
            score += Self.identityWeight
            identityMatches += 1
        }

        // Pass 2: legacy keys, and real keys whose monitor is not attached, fall
        // back to built-in-ness plus resolution. Candidates are consumed in
        // arrangement order so two identical panels bind left-to-right.
        for mine in unmatched {
            let candidates = remainingLive.indices.filter { index in
                let candidate = remainingLive[index]
                return candidate.isBuiltIn == mine.isBuiltIn && candidate.resolution == mine.resolution
            }

            guard let index = candidates.min(by: { lhs, rhs in
                let a = remainingLive[lhs].position
                let b = remainingLive[rhs].position
                if a.x != b.x { return a.x < b.x }
                return a.y < b.y
            }) else {
                // A display in this profile has no counterpart attached.
                return nil
            }

            let matched = remainingLive.remove(at: index)
            if let myKey = mine.key, let liveKey = matched.key {
                bindings[myKey] = liveKey
            }
            boundPairs.append((mine, matched))
            score += Self.resolutionWeight
        }

        guard remainingLive.isEmpty else {
            return nil
        }

        // Arrangement bonus: same monitors *and* same relative placement. With
        // display-relative regions this no longer affects correctness, but it
        // lets a user keep separate profiles for e.g. laptop-left vs laptop-right.
        let sameArrangement = boundPairs.allSatisfy { $0.mine.position == $0.live.position }
        if sameArrangement {
            score += Self.arrangementBonus
        }

        return Match(
            keyBindings: bindings,
            score: score,
            isExactIdentity: identityMatches == displays.count
        )
    }
}
