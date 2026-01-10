import Foundation
import AppKit

/// Actor responsible for enforcing window positions and sizes
actor WindowPositionEnforcer {
    private let accessibilityService: AccessibilityService
    
    init(accessibilityService: AccessibilityService) {
        self.accessibilityService = accessibilityService
    }
    
    /// Reposition and resize a window to match a region
    /// Respects app minimum/maximum size constraints
    @MainActor
    func enforceRegion(_ region: Region, for app: NSRunningApplication) async {
        guard let window = accessibilityService.getFrontmostWindow(for: app) else {
            log("⚠️ Could not get window for \(app.bundleIdentifier ?? "unknown")")
            return
        }
        
        // Apply padding to the region frame
        let padding = region.padding
        let targetFrame = CGRect(
            x: region.frame.origin.x + padding,
            y: region.frame.origin.y + padding,
            width: region.frame.width - (padding * 2),
            height: region.frame.height - (padding * 2)
        )
        
        log("📐 Enforcing region '\(region.name)' for \(app.bundleIdentifier ?? "unknown")")
        if padding > 0 {
            log("   Padding: \(Int(padding))px")
        }
        log("   Target: \(targetFrame)")
        
        // Set position and size
        // The app will enforce its own constraints, we respect that
        accessibilityService.setWindowFrame(window, to: targetFrame)
        
        // Give the system a moment to apply changes
        try? await Task.sleep(for: .milliseconds(10))
        
        // Read back actual frame to log what happened
        if let actualPosition = accessibilityService.getWindowPosition(window),
           let actualSize = accessibilityService.getWindowSize(window) {
            let actualFrame = CGRect(origin: actualPosition, size: actualSize)
            log("   Actual: \(actualFrame)")
            
            // Check for significant position differences (menu bar, dock, etc.)
            let positionDiff = abs(actualFrame.origin.y - targetFrame.origin.y)
            if positionDiff > 5 {
                log("   ⚠️ Position adjusted by \(Int(positionDiff))px - check for menu bar/dock overlap")
            }
            
            if actualFrame.size != targetFrame.size {
                log("   ℹ️ Size adjusted by app constraints")
            }
        }
    }
    
    /// Reposition all windows for assigned apps in the given regions
    @MainActor
    func enforceAllRegions(_ regions: [Region]) async {
        // Build a map of bundleID -> region
        var appToRegion: [String: Region] = [:]
        for region in regions {
            for bundleID in region.assignedApps {
                appToRegion[bundleID] = region
            }
        }
        
        // Get all running applications
        let runningApps = NSWorkspace.shared.runningApplications
        
        // Reposition windows for apps that have assigned regions
        for app in runningApps {
            guard let bundleID = app.bundleIdentifier,
                  let region = appToRegion[bundleID] else {
                continue
            }
            
            await enforceRegion(region, for: app)
        }
    }
}
