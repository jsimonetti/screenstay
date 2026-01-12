import Foundation
import ApplicationServices
import AppKit

/// Centralized permission management for Accessibility and Input Monitoring
@MainActor
class PermissionManager {
    
    enum Permission {
        case accessibility
        case inputMonitoring
        
        var name: String {
            switch self {
            case .accessibility: return "Accessibility"
            case .inputMonitoring: return "Input Monitoring"
            }
        }
        
        var systemSettingsURL: String {
            switch self {
            case .accessibility:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            case .inputMonitoring:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            }
        }
    }
    
    /// Check if Accessibility permission is granted
    static func checkAccessibility() -> Bool {
        return AXIsProcessTrusted()
    }
    
    /// Check if Input Monitoring permission is granted
    /// Note: This is a best-effort check. The system may still require Input Monitoring
    /// for certain operations even if this returns true.
    static func checkInputMonitoring() -> Bool {
        // On macOS 10.15+, Input Monitoring is required to capture keystrokes from other apps
        // However, there's no reliable API to check this permission before attempting to use it
        // The best we can do is try to create an event tap and see if it works
        
        let testTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, _, event, _ in return Unmanaged.passUnretained(event) },
            userInfo: nil
        )
        
        guard let tap = testTap else {
            return false
        }
        
        CFMachPortInvalidate(tap)
        
        // If we can create the tap, assume permission is granted
        // The system will enforce the actual permission when events are captured
        return true
    }
    
    /// Check all permissions and return missing ones
    static func checkAllPermissions() -> [Permission] {
        var missing: [Permission] = []
        
        if !checkAccessibility() {
            missing.append(.accessibility)
        }
        
        // Note: Input Monitoring cannot be reliably checked programmatically
        // It will be detected at runtime when keyboard shortcuts are used
        
        return missing
    }
    
    /// Request Accessibility permission with system prompt
    static nonisolated func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
    
    /// Check all permissions and show a helpful guide
    /// Returns true if user confirms they've checked permissions
    @discardableResult
    static func checkAndRequestPermissions() -> Bool {
        let hasAccessibility = checkAccessibility()
        
        if !hasAccessibility {
            // Request Accessibility with system prompt
            requestAccessibility()
            
            // Show our alert
            showAccessibilityAlert()
            
            return false
        }
        
        // Accessibility is granted, but we need to remind about Input Monitoring
        // since it cannot be reliably checked programmatically
        
        // Show a one-time reminder about Input Monitoring on first launch
        let hasShownReminder = UserDefaults.standard.bool(forKey: "HasShownInputMonitoringReminder")
        if !hasShownReminder {
            showInputMonitoringReminder()
            UserDefaults.standard.set(true, forKey: "HasShownInputMonitoringReminder")
        }
        
        return true
    }
    
    private static func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
        ScreenStay needs Accessibility permission to manage window positions.
        
        Please enable it in:
        System Settings → Privacy & Security → Accessibility
        
        Then restart ScreenStay.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
    
    private static func showInputMonitoringReminder() {
        let alert = NSAlert()
        alert.messageText = "Input Monitoring Permission Recommended"
        alert.informativeText = """
        For keyboard shortcuts to work, ScreenStay needs Input Monitoring permission.
        
        Please verify it's enabled in:
        System Settings → Privacy & Security → Input Monitoring
        
        ScreenStay should appear in the list and be checked.
        If it's not working, try removing and re-adding it.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "I'll Check Later")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
