import Foundation
import AppKit

/// Manages temporary focus region functionality - moving any window to a designated focus area
@MainActor
class FocusRegionManager {
    private let accessibilityService: AccessibilityService
    
    // Current focused window state
    private var focusedWindow: AXUIElement?
    private var focusedWindowID: CGWindowID?
    private var originalFrame: CGRect?
    private var focusRegionFrame: CGRect?  // The frame where window should be when focused
    
    // Monitor for manual moves
    private var positionCheckTimer: Timer?
    
    init(accessibilityService: AccessibilityService) {
        self.accessibilityService = accessibilityService
    }
    
    /// Move a window to the focus region
    func focusWindow(_ window: AXUIElement, windowID: CGWindowID, toRegion region: Region) {
        // Check if there's already a focused window and unfocus it first
        if let existingID = focusedWindowID, existingID != windowID {
            unfocusWindow()
        }
        
        // Capture current position before moving
        guard let currentPosition = accessibilityService.getWindowPosition(window),
              let currentSize = accessibilityService.getWindowSize(window) else {
            return
        }
        
        let currentFrame = CGRect(origin: currentPosition, size: currentSize)
        
        // Apply padding to focus region frame
        let padding = region.padding
        let targetFrame = CGRect(
            x: region.frame.origin.x + padding,
            y: region.frame.origin.y + padding,
            width: region.frame.width - (padding * 2),
            height: region.frame.height - (padding * 2)
        )
        
        // Store state
        focusedWindow = window
        focusedWindowID = windowID
        originalFrame = currentFrame
        focusRegionFrame = targetFrame
        
        // Move window to focus region
        accessibilityService.setWindowFrame(window, to: targetFrame)
        
        // Start monitoring for manual moves
        startMonitoringPosition()
    }
    
    /// Unfocus the current window (return to original position)
    func unfocusWindow() {
        guard let window = focusedWindow,
              let originalFrame = originalFrame else {
            return
        }
        
        // Restore original position
        accessibilityService.setWindowFrame(window, to: originalFrame)
        
        // Clear state
        clearFocus()
    }
    
    /// Clear focus state without moving window
    func clearFocus() {
        stopMonitoringPosition()
        focusedWindow = nil
        focusedWindowID = nil
        originalFrame = nil
        focusRegionFrame = nil
    }
    
    /// Get the currently focused window
    func getFocusedWindow() -> (window: AXUIElement, id: CGWindowID)? {
        guard let window = focusedWindow, let id = focusedWindowID else {
            return nil
        }
        return (window, id)
    }
    
    /// Check if a specific window is currently focused
    func isWindowFocused(_ windowID: CGWindowID) -> Bool {
        return focusedWindowID == windowID
    }
    
    // MARK: - Position Monitoring
    
    private func startMonitoringPosition() {
        stopMonitoringPosition()
        
        // Check every 500ms if the focused window was manually moved
        positionCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkFocusedWindowPosition()
            }
        }
    }
    
    private func stopMonitoringPosition() {
        positionCheckTimer?.invalidate()
        positionCheckTimer = nil
    }
    
    private func checkFocusedWindowPosition() {
        guard let window = focusedWindow,
              let focusRegionFrame = focusRegionFrame else {
            return
        }
        
        // Get current position
        guard let currentPosition = accessibilityService.getWindowPosition(window),
              let currentSize = accessibilityService.getWindowSize(window) else {
            // Window might be closed or invalid
            clearFocus()
            return
        }
        
        let currentFrame = CGRect(origin: currentPosition, size: currentSize)
        
        // Check if window was moved significantly from the focus region (> 10px in any direction)
        let positionDiff = abs(currentFrame.origin.x - focusRegionFrame.origin.x) + 
                          abs(currentFrame.origin.y - focusRegionFrame.origin.y)
        
        if positionDiff > 10 {
            clearFocus()
        }
    }
}
