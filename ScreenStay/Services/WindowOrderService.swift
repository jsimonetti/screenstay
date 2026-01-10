import Foundation
import AppKit

/// Information about a window from CGWindowList
struct WindowInfo: Sendable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let bundleID: String?
    let bounds: CGRect
    let layer: Int
}

/// Service for querying window order from macOS
@MainActor
class WindowOrderService {
    
    /// Get all on-screen windows in order (most recent first)
    func getOrderedWindows() -> [WindowInfo] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        
        var windows: [WindowInfo] = []
        
        for windowDict in windowList {
            guard let windowID = windowDict[kCGWindowNumber as String] as? CGWindowID,
                  let ownerPID = windowDict[kCGWindowOwnerPID as String] as? pid_t,
                  let ownerName = windowDict[kCGWindowOwnerName as String] as? String,
                  let boundsDict = windowDict[kCGWindowBounds as String] as? [String: CGFloat],
                  let layer = windowDict[kCGWindowLayer as String] as? Int else {
                continue
            }
            
            // Convert bounds dictionary to CGRect
            let x = boundsDict["X"] ?? 0
            let y = boundsDict["Y"] ?? 0
            let width = boundsDict["Width"] ?? 0
            let height = boundsDict["Height"] ?? 0
            let bounds = CGRect(x: x, y: y, width: width, height: height)
            
            // Get bundle ID from running application
            let bundleID = NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier
            
            let info = WindowInfo(
                windowID: windowID,
                ownerPID: ownerPID,
                ownerName: ownerName,
                bundleID: bundleID,
                bounds: bounds,
                layer: layer
            )
            
            windows.append(info)
        }
        
        return windows
    }
    
    /// Get windows for specific bundle IDs (most recent first)
    func getWindows(forBundleIDs bundleIDs: [String]) -> [WindowInfo] {
        let allWindows = getOrderedWindows()
        let bundleIDSet = Set(bundleIDs)
        
        return allWindows.filter { window in
            guard let bundleID = window.bundleID else { return false }
            return bundleIDSet.contains(bundleID)
        }
    }
    
    /// Get the most recently used window for specific bundle IDs
    func getMostRecentWindow(forBundleIDs bundleIDs: [String]) -> WindowInfo? {
        return getWindows(forBundleIDs: bundleIDs).first
    }
}
