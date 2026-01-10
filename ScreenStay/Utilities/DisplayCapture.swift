import AppKit
import CoreGraphics

/// Helper for capturing current display configuration
class DisplayCapture {
    
    /// Capture current display topology
    static func captureCurrentTopology() -> DisplayTopology {
        var displays: [DisplayTopology.DisplayInfo] = []
        
        // Get all displays
        let maxDisplays: UInt32 = 16
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0
        
        let result = CGGetActiveDisplayList(maxDisplays, &displayIDs, &displayCount)
        
        guard result == .success else {
            log("❌ Failed to get display list")
            return DisplayTopology(displays: [], externalMonitorCount: 0)
        }
        
        var externalCount = 0
        
        for i in 0..<Int(displayCount) {
            let displayID = displayIDs[i]
            let bounds = CGDisplayBounds(displayID)
            let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0
            
            if !isBuiltIn {
                externalCount += 1
            }
            
            let display = DisplayTopology.DisplayInfo(
                displayID: displayID,
                resolution: CGSize(width: bounds.width, height: bounds.height),
                position: CGPoint(x: bounds.origin.x, y: bounds.origin.y),
                isBuiltIn: isBuiltIn
            )
            
            displays.append(display)
            
            log("📺 Display \(displayID): \(Int(bounds.width))x\(Int(bounds.height)) at (\(Int(bounds.origin.x)), \(Int(bounds.origin.y))) \(isBuiltIn ? "[Built-in]" : "[External]")")
        }
        
        // Sort by displayID for consistency
        displays.sort { $0.displayID < $1.displayID }
        
        return DisplayTopology(displays: displays, externalMonitorCount: externalCount)
    }
    
    /// Get a human-readable description of the topology
    static func describeTopology(_ topology: DisplayTopology) -> String {
        var parts: [String] = []
        
        let builtInCount = topology.displays.filter { $0.isBuiltIn }.count
        let externalCount = topology.externalMonitorCount
        
        if builtInCount > 0 {
            parts.append("Built-in")
        }
        
        if externalCount > 0 {
            let externalResolutions = topology.displays
                .filter { !$0.isBuiltIn }
                .map { "\(Int($0.resolution.width))x\(Int($0.resolution.height))" }
                .joined(separator: ", ")
            parts.append("\(externalCount) External (\(externalResolutions))")
        }
        
        return parts.joined(separator: " + ")
    }
}
