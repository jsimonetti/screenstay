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
}
