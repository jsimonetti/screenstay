import Foundation
@preconcurrency import ApplicationServices
import AppKit

/// Service for interacting with macOS Accessibility API
@MainActor
class AccessibilityService {
    
    // MARK: - Permission Checking
    
    /// Check if accessibility permissions are granted
    static func checkPermissions() -> Bool {
        return AXIsProcessTrusted()
    }
    
    /// Prompt user to grant accessibility permissions
    static nonisolated func requestPermissions() {
        // Suppress concurrency warning - this is a C API constant
        let promptKey = unsafeBitCast(kAXTrustedCheckOptionPrompt, to: String.self)
        let options = [promptKey: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
    
    // MARK: - Window Manipulation
    
    /// Get the frontmost window of an application
    func getFrontmostWindow(for app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        
        var windowValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue)
        
        guard result == .success, let window = windowValue else {
            // Fallback: try to get any window
            return getFirstWindow(for: app)
        }
        
        return (window as! AXUIElement)
    }
    
    /// Get the first window of an application
    private func getFirstWindow(for app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        
        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        
        guard result == .success,
              let windows = windowsValue as? [AXUIElement],
              let firstWindow = windows.first else {
            return nil
        }
        
        return firstWindow
    }
    
    /// Get window position
    func getWindowPosition(_ window: AXUIElement) -> CGPoint? {
        var positionValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue)
        
        guard result == .success,
              let axValue = positionValue,
              AXValueGetType(axValue as! AXValue) == .cgPoint else {
            return nil
        }
        
        var position = CGPoint.zero
        AXValueGetValue(axValue as! AXValue, .cgPoint, &position)
        return position
    }
    
    /// Get window size
    func getWindowSize(_ window: AXUIElement) -> CGSize? {
        var sizeValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)
        
        guard result == .success,
              let axValue = sizeValue,
              AXValueGetType(axValue as! AXValue) == .cgSize else {
            return nil
        }
        
        var size = CGSize.zero
        AXValueGetValue(axValue as! AXValue, .cgSize, &size)
        return size
    }
    
    /// Set window position
    @discardableResult
    func setWindowPosition(_ window: AXUIElement, to position: CGPoint) -> Bool {
        var axPosition = position
        guard let axValue = AXValueCreate(.cgPoint, &axPosition) else {
            return false
        }
        
        let result = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, axValue)
        return result == .success
    }
    
    /// Set window size
    @discardableResult
    func setWindowSize(_ window: AXUIElement, to size: CGSize) -> Bool {
        var axSize = size
        guard let axValue = AXValueCreate(.cgSize, &axSize) else {
            return false
        }
        
        let result = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axValue)
        return result == .success
    }
    
    /// Set window frame (position + size)
    func setWindowFrame(_ window: AXUIElement, to frame: CGRect) {
        // Set position first, then size
        setWindowPosition(window, to: frame.origin)
        setWindowSize(window, to: frame.size)
    }
    
    /// Get the CGWindowID for an AXUIElement window
    func getWindowID(_ window: AXUIElement) -> CGWindowID? {
        // Try to get the window ID via private attribute (undocumented but works)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, "AXWindowID" as CFString, &value)
        
        if result == .success, let number = value as? NSNumber {
            return number.uint32Value
        }
        
        // Fallback: try to match by position and size using CGWindowList
        guard let position = getWindowPosition(window),
              let size = getWindowSize(window) else {
            return nil
        }
        
        // Get window list and find matching window
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        
        for windowDict in windowList {
            guard let boundsDict = windowDict[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"],
                  let y = boundsDict["Y"],
                  let width = boundsDict["Width"],
                  let height = boundsDict["Height"] else {
                continue
            }
            
            // Match by position and size (within 1px tolerance)
            if abs(x - position.x) < 1 && abs(y - position.y) < 1 &&
               abs(width - size.width) < 1 && abs(height - size.height) < 1 {
                if let id = windowDict[kCGWindowNumber as String] as? CGWindowID {
                    return id
                }
            }
        }
        
        return nil
    }
    
    /// Check if a window should be positioned (filters out system dialogs, sheets, etc.)
    func shouldPositionWindow(_ window: AXUIElement) -> Bool {
        // Check subrole - dialogs, sheets, and floating windows should not be positioned
        var subroleValue: CFTypeRef?
        let subroleResult = AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleValue)
        
        if subroleResult == .success, let subrole = subroleValue as? String {
            let excludedSubroles = [
                kAXDialogSubrole as String,          // Standard dialogs (open/save)
                kAXSystemDialogSubrole as String,    // System-level dialogs
                kAXFloatingWindowSubrole as String,  // Floating palettes/inspectors
                kAXSheetRole as String               // Modal sheets
            ]
            
            if excludedSubroles.contains(subrole) {
                return false
            }
        }
        
        // Check role - sheets should never be positioned
        var roleValue: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleValue)
        
        if roleResult == .success, let role = roleValue as? String {
            if role == kAXSheetRole as String {
                return false
            }
        }
        
        return true
    }
}

