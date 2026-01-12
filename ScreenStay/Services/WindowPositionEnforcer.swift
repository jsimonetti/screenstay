import Foundation
import AppKit

/// Actor responsible for enforcing window positions and sizes
actor WindowPositionEnforcer {
    private let accessibilityService: AccessibilityService
    weak var windowEventMonitor: WindowEventMonitor?
    
    init(accessibilityService: AccessibilityService) {
        self.accessibilityService = accessibilityService
    }
    
    /// Set the window event monitor reference
    func setWindowEventMonitor(_ monitor: WindowEventMonitor) {
        self.windowEventMonitor = monitor
    }
    
    /// Get the window event monitor reference (for use outside actor)
    func getWindowEventMonitor() -> WindowEventMonitor? {
        return windowEventMonitor
    }
    
    /// Reposition and resize a window to match a region
    /// Respects app minimum/maximum size constraints
    @MainActor
    func enforceRegion(_ region: Region, for app: NSRunningApplication, window: AXUIElement? = nil) async {
        let targetWindow = window ?? accessibilityService.getFrontmostWindow(for: app)
        
        guard let targetWindow = targetWindow else {
            return
        }
        
        // Filter out system dialogs, sheets, and floating windows
        guard accessibilityService.shouldPositionWindow(targetWindow) else {
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
        
        // Get monitor reference from actor context
        let monitor = await getWindowEventMonitor()
        
        // Mark that we are repositioning (to ignore the move event)
        monitor?.willRepositionWindow()
        
        // Set position and size
        // The app will enforce its own constraints, we respect that
        accessibilityService.setWindowFrame(targetWindow, to: targetFrame)
        
        // Give the system a moment to apply changes
        try? await Task.sleep(for: .milliseconds(10))
        
        // Mark that we finished repositioning
        monitor?.didRepositionWindow()
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
