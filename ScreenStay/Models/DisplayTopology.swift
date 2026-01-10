import Foundation
import AppKit
import CoreGraphics

/// Represents a display topology fingerprint for profile matching
struct DisplayTopology: Codable, Equatable, Sendable {
    var displays: [DisplayInfo]
    var externalMonitorCount: Int
    
    struct DisplayInfo: Codable, Equatable, Sendable {
        var displayID: CGDirectDisplayID
        var resolution: CGSize
        var position: CGPoint
        var isBuiltIn: Bool
    }
    
    /// Generate a fingerprint string for comparison
    /// Based on display count, resolutions, and which is built-in (ignoring position)
    var fingerprint: String {
        // Sort displays by: built-in first, then by resolution
        let sorted = displays.sorted { d1, d2 in
            if d1.isBuiltIn != d2.isBuiltIn {
                return d1.isBuiltIn
            }
            return (d1.resolution.width, d1.resolution.height) < (d2.resolution.width, d2.resolution.height)
        }
        
        let parts = sorted.map { display in
            let type = display.isBuiltIn ? "builtin" : "external"
            return "\(type):\(Int(display.resolution.width))x\(Int(display.resolution.height))"
        }
        return parts.joined(separator: "|")
    }
    
    /// Create topology from current screen configuration
    static func current() -> DisplayTopology {
        let screens = NSScreen.screens
        var displays: [DisplayInfo] = []
        var externalCount = 0
        
        for screen in screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                continue
            }
            
            let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0
            if !isBuiltIn {
                externalCount += 1
            }
            
            let info = DisplayInfo(
                displayID: displayID,
                resolution: screen.frame.size,
                position: screen.frame.origin,
                isBuiltIn: isBuiltIn
            )
            displays.append(info)
        }
        
        return DisplayTopology(displays: displays, externalMonitorCount: externalCount)
    }
}


