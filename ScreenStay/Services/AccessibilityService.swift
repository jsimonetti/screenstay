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

        // The value comes from another process, so check the type rather than
        // force casting it.
        if result == .success, let value = windowValue,
           CFGetTypeID(value) == AXUIElementGetTypeID() {
            return (value as! AXUIElement)
        }

        return getFirstPlaceableWindow(for: app)
    }

    /// First window of an application that is worth positioning.
    ///
    /// Not simply the first window: an app whose main window is hidden can list
    /// a palette or inspector first, and blindly taking it drags the wrong thing
    /// into a region.
    private func getFirstPlaceableWindow(for app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)

        guard result == .success, let windows = windowsValue as? [AXUIElement] else {
            return nil
        }

        return windows.first { shouldPositionWindow($0) } ?? windows.first
    }

    /// Process owning a window element.
    func getPID(_ window: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return nil }
        return pid
    }

    /// Whether a window is currently minimized.
    func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success,
              let number = value as? NSNumber else {
            return false
        }
        return number.boolValue
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
    ///
    /// Applied as size, position, size. A single position-then-size pass is
    /// unreliable when the window is moving between displays of different
    /// sizes: the move is evaluated while the window still has its old
    /// dimensions, so the window server or the app itself may refuse or adjust
    /// it. Shrinking first makes the move always legal, and the trailing resize
    /// re-applies the target size in case the app clamped it during the move.
    func setWindowFrame(_ window: AXUIElement, to frame: CGRect) {
        setWindowSize(window, to: frame.size)
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
        
        // Fallback: match by owning process, position and size.
        //
        // The process matters. Matching on bounds alone picks the first window
        // with those bounds, and identically sized windows are the normal state
        // in a tiled layout, not an edge case. Even scoped to one process the
        // match can be ambiguous, in which case returning nothing beats
        // returning the wrong window: callers treat nil as "not tracked", while
        // a wrong ID makes a different window look already positioned.
        guard let position = getWindowPosition(window),
              let size = getWindowSize(window),
              let pid = getPID(window) else {
            return nil
        }

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let matches = windowList.filter { windowDict in
            guard windowDict[kCGWindowOwnerPID as String] as? pid_t == pid,
                  let boundsDict = windowDict[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"], let y = boundsDict["Y"],
                  let width = boundsDict["Width"], let height = boundsDict["Height"] else {
                return false
            }
            return abs(x - position.x) < 1 && abs(y - position.y) < 1
                && abs(width - size.width) < 1 && abs(height - size.height) < 1
        }

        guard matches.count == 1 else { return nil }
        return matches[0][kCGWindowNumber as String] as? CGWindowID
    }
    
    /// Whether a window is an ordinary document window worth positioning.
    ///
    /// This asks for `AXStandardWindow` rather than listing things to exclude.
    /// A denylist positions anything whose subrole nobody thought of, and there
    /// is no shortage of those; requiring the one subrole that means "ordinary
    /// window" fails safe instead.
    func shouldPositionWindow(_ window: AXUIElement) -> Bool {
        placementRefusalReason(for: window) == nil
    }

    /// Why a window is not a placement target, or nil if it is one.
    ///
    /// Split out so the enforcer can say what it skipped. Requiring
    /// AXStandardWindow is stricter than the denylist it replaced, and the only
    /// way to find an app it wrongly excludes is to be able to see the refusals.
    func placementRefusalReason(for window: AXUIElement) -> String? {
        // A minimized window has a frame, and moving it does nothing visible
        // except surprise the user when it is restored.
        if isMinimized(window) {
            return "minimized"
        }

        var roleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleValue) == .success,
           let role = roleValue as? String, role != kAXWindowRole as String {
            return "role is \(role)"
        }

        var subroleValue: CFTypeRef?
        let subroleResult = AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleValue)

        guard subroleResult == .success, let subrole = subroleValue as? String else {
            // Some apps report no subrole at all. Their role already said
            // AXWindow, so allow it rather than refusing to manage the app.
            return nil
        }

        return subrole == kAXStandardWindowSubrole as String ? nil : "subrole is \(subrole)"
    }
}

