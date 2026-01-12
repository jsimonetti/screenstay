import AppKit
import Foundation

/// Displays a colored border around the currently focused window
@MainActor
class FocusedWindowBorderOverlay {
    private let accessibilityService: AccessibilityService
    private var borderWindows: [NSWindow] = []
    private var currentTrackedWindow: AXUIElement?
    private var axObserver: AXObserver?
    
    private var isEnabled: Bool = false
    private var borderColor: NSColor = .orange
    private var borderWidth: Double = 4.0
    
    // Cached values for performance
    private var cachedGlobalMaxY: CGFloat = 0
    private var cachedScreenBounds: CGRect = .zero
    private var lastWindowScreen: NSScreen?
    
    init(accessibilityService: AccessibilityService) {
        self.accessibilityService = accessibilityService
    }
    
    /// Start showing borders around focused windows
    func start(enabled: Bool, color: String, width: Double) {
        self.isEnabled = enabled
        self.borderColor = NSColor.from(hex: color) ?? .orange
        self.borderWidth = width
        
        guard enabled else {
            stop()
            return
        }
        
        // Initial update
        updateBorder()
    }
    
    /// Stop showing borders
    func stop() {
        removeWindowObserver()
        hideBorder()
        currentTrackedWindow = nil
    }
    
    /// Update border settings
    func updateSettings(enabled: Bool, color: String, width: Double) {
        start(enabled: enabled, color: color, width: width)
    }
    
    /// Manually trigger border update (called when app activation changes)
    func updateBorder() {
        guard isEnabled else {
            hideBorder()
            return
        }
        
        // Get frontmost app
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontmostApp.bundleIdentifier else {
            hideBorder()
            return
        }
        
        // Exclude ScreenStay's own windows
        if bundleID == Bundle.main.bundleIdentifier {
            hideBorder()
            return
        }
        
        // Get focused window
        guard let focusedWindow = accessibilityService.getFrontmostWindow(for: frontmostApp) else {
            hideBorder()
            return
        }
        
        // Get window frame
        guard let position = accessibilityService.getWindowPosition(focusedWindow),
              let size = accessibilityService.getWindowSize(focusedWindow) else {
            hideBorder()
            return
        }
        
        let windowFrame = CGRect(origin: position, size: size)
        
        // Check if window is minimized
        var value: AnyObject?
        var isMinimized = false
        if AXUIElementCopyAttributeValue(focusedWindow, kAXMinimizedAttribute as CFString, &value) == .success,
           let number = value as? NSNumber {
            isMinimized = number.boolValue
        }
        
        if isMinimized {
            hideBorder()
            return
        }
        
        // Show/update border
        showBorder(around: windowFrame)
        
        // Set up notifications if this is a new window
        if currentTrackedWindow == nil || !CFEqual(currentTrackedWindow, focusedWindow) {
            setupWindowObserver(for: focusedWindow)
            currentTrackedWindow = focusedWindow
        }
    }
    
    private func showBorder(around frame: CGRect) {
        let width = CGFloat(borderWidth)
        
        // Find which screen contains this window (in Accessibility coordinates - top-left origin)
        let windowCenterAX = CGPoint(x: frame.midX, y: frame.midY)
        
        // Try cached screen first for performance
        var targetScreen: NSScreen?
        if let lastScreen = lastWindowScreen {
            let screenFrame = lastScreen.frame
            let axScreenY = cachedGlobalMaxY - screenFrame.maxY
            let axScreenFrame = CGRect(x: screenFrame.minX, y: axScreenY, width: screenFrame.width, height: screenFrame.height)
            
            if axScreenFrame.contains(windowCenterAX) {
                targetScreen = lastScreen
            }
        }
        
        // If not on cached screen, find the correct one
        if targetScreen == nil {
            // Update cached global max Y
            cachedGlobalMaxY = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
            
            for screen in NSScreen.screens {
                let screenFrame = screen.frame
                let axScreenY = cachedGlobalMaxY - screenFrame.maxY
                let axScreenFrame = CGRect(x: screenFrame.minX, y: axScreenY, width: screenFrame.width, height: screenFrame.height)
                
                if axScreenFrame.contains(windowCenterAX) {
                    targetScreen = screen
                    lastWindowScreen = screen
                    break
                }
            }
        }
        
        guard let screen = targetScreen ?? NSScreen.main else { return }
        
        // Convert from Accessibility API coordinates to NSWindow coordinates
        let convertedY = cachedGlobalMaxY - frame.origin.y - frame.height
        let convertedFrame = CGRect(x: frame.origin.x, y: convertedY, width: frame.width, height: frame.height)
        
        cachedScreenBounds = screen.frame
        
        // Create 4 border windows (top, right, bottom, left), clamped to screen bounds
        let borders: [(CGRect, String)] = [
            (CGRect(x: convertedFrame.origin.x, y: convertedFrame.maxY, width: convertedFrame.width, height: width), "top"),
            (CGRect(x: convertedFrame.maxX - width, y: convertedFrame.origin.y, width: width, height: convertedFrame.height), "right"),
            (CGRect(x: convertedFrame.origin.x, y: convertedFrame.origin.y - width, width: convertedFrame.width, height: width), "bottom"),
            (CGRect(x: convertedFrame.origin.x, y: convertedFrame.origin.y, width: width, height: convertedFrame.height), "left")
        ]
        
        // Create windows if they don't exist, otherwise reuse
        if borderWindows.isEmpty {
            for _ in 0..<4 {
                let window = NSWindow(
                    contentRect: .zero,
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                
                window.backgroundColor = borderColor
                window.isOpaque = false
                window.level = .statusBar
                window.ignoresMouseEvents = true
                window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                window.hasShadow = false
                
                borderWindows.append(window)
            }
        }
        
        // Update window frames and colors
        for (index, (borderFrame, _)) in borders.enumerated() {
            guard index < borderWindows.count else { break }
            let window = borderWindows[index]
            
            // Clamp border to screen bounds
            let clampedFrame = borderFrame.intersection(cachedScreenBounds)
            
            // Hide if border is completely outside screen
            if clampedFrame.isEmpty {
                window.orderOut(nil)
                continue
            }
            
            // Update frame and show
            window.setFrame(clampedFrame, display: false)
            window.backgroundColor = borderColor
            window.orderFrontRegardless()
        }
    }
    
    private func hideBorder() {
        for window in borderWindows {
            window.orderOut(nil)
        }
        borderWindows.removeAll()
    }
    
    // MARK: - Accessibility Notifications
    
    private func setupWindowObserver(for window: AXUIElement) {
        // Remove any existing observer
        removeWindowObserver()
        
        // Create observer for the window's process
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return }
        
        var observer: AXObserver?
        guard AXObserverCreate(pid, { _, element, notification, refcon in
            // Callback is called on a background thread, move to main queue immediately
            let overlay = Unmanaged<FocusedWindowBorderOverlay>.fromOpaque(refcon!).takeUnretainedValue()
            DispatchQueue.main.async {
                overlay.handleWindowNotification(element: element, notification: notification)
            }
        }, &observer) == .success else { return }
        
        guard let observer = observer else { return }
        
        // Register for position and size changes
        AXObserverAddNotification(observer, window, kAXMovedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
        AXObserverAddNotification(observer, window, kAXResizedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
        AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
        
        // Start observing
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        
        self.axObserver = observer
    }
    
    private func removeWindowObserver() {
        guard let observer = axObserver else { return }
        
        // Remove from run loop
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        
        axObserver = nil
    }
    
    private func handleWindowNotification(element: AXUIElement, notification: CFString) {
        let notificationName = notification as String
        
        if notificationName == kAXUIElementDestroyedNotification as String {
            // Window was destroyed, hide border
            hideBorder()
            currentTrackedWindow = nil
        } else if notificationName == kAXMovedNotification as String || notificationName == kAXResizedNotification as String {
            // Window moved or resized, update border position
            updateBorder()
        }
    }
}

// MARK: - NSColor Hex Extension
extension NSColor {
    static func from(hex: String) -> NSColor? {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        
        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }
        
        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgb & 0x0000FF) / 255.0
        
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }
    
    func toHex() -> String {
        guard let rgbColor = usingColorSpace(.deviceRGB) else { return "#FF6B00" }
        let r = Int(rgbColor.redComponent * 255)
        let g = Int(rgbColor.greenComponent * 255)
        let b = Int(rgbColor.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
