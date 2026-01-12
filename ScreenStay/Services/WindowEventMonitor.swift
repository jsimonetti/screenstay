import Foundation
import ApplicationServices
import AppKit

/// Monitors window-level events using AXObserver for specific applications
@MainActor
class WindowEventMonitor {
    
    private var observers: [pid_t: AXObserver] = [:]
    private var monitoredBundleIDs: Set<String> = []
    private var positionedWindows: Set<CGWindowID> = []
    private var isRepositioning = false
    private let accessibilityService: AccessibilityService
    
    var onWindowEvent: ((NSRunningApplication, AXUIElement) -> Void)?
    
    init(accessibilityService: AccessibilityService) {
        self.accessibilityService = accessibilityService
    }
    
    // MARK: - Public API
    
    /// Start monitoring windows for the given bundle IDs
    func startMonitoring(bundleIDs: Set<String>) {
        monitoredBundleIDs = bundleIDs
        
        // Monitor currently running apps
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier, monitoredBundleIDs.contains(bundleID) {
                createObserver(for: app)
            }
        }
        
        log("🔍 WindowEventMonitor: Monitoring \(bundleIDs.count) apps")
    }
    
    /// Stop monitoring all windows
    func stopMonitoring() {
        for (pid, observer) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            log("   Stopped monitoring PID \(pid)")
        }
        observers.removeAll()
        monitoredBundleIDs.removeAll()
        positionedWindows.removeAll()
    }
    
    /// Check if we should monitor this app
    func shouldMonitor(_ app: NSRunningApplication) -> Bool {
        guard let bundleID = app.bundleIdentifier else { return false }
        return monitoredBundleIDs.contains(bundleID)
    }
    
    /// Create observer for a newly launched app
    func observeApp(_ app: NSRunningApplication) async {
        guard shouldMonitor(app) else { return }
        createObserver(for: app)
    }
    
    /// Remove observer when app terminates
    func removeObserver(for app: NSRunningApplication) async {
        if let observer = observers.removeValue(forKey: app.processIdentifier) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            log("   Removed observer for \(app.bundleIdentifier ?? "unknown")")
        }
        
        // Clean up window IDs for this app
        // Note: We can't easily know which windows belong to which app,
        // so we'll let the set grow until profile changes (acceptable)
    }
    
    /// Mark that we are about to reposition a window (to ignore subsequent events)
    func willRepositionWindow() {
        isRepositioning = true
    }
    
    /// Mark that we finished repositioning
    func didRepositionWindow() {
        // Small delay to ensure any triggered events are processed before we clear the flag
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            isRepositioning = false
        }
    }
    
    /// Mark a window as positioned (either by us or by user)
    func markWindowAsPositioned(_ window: AXUIElement) {
        if let windowID = accessibilityService.getWindowID(window) {
            positionedWindows.insert(windowID)
        }
    }
    
    /// Remove a window from the positioned set (to allow repositioning)
    func removeWindowFromPositioned(_ window: AXUIElement) {
        if let windowID = accessibilityService.getWindowID(window) {
            positionedWindows.remove(windowID)
            log("   Removed window \(windowID) from positioned set")
        }
    }
    
    /// Check if we've already positioned this window
    func hasPositionedWindow(_ window: AXUIElement) -> Bool {
        guard let windowID = accessibilityService.getWindowID(window) else {
            return false
        }
        return positionedWindows.contains(windowID)
    }
    
    /// Reset all positioned window tracking (e.g., when profile changes)
    func resetPositionedWindows() {
        positionedWindows.removeAll()
        log("   Reset positioned windows tracking")
    }
    
    // MARK: - Private Implementation
    
    private func createObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        
        // Don't create duplicate observers
        guard observers[pid] == nil else { return }
        
        let appElement = AXUIElementCreateApplication(pid)
        var observer: AXObserver?
        
        // Create a context struct to pass both monitor and pid
        struct ObserverContext {
            let monitor: Unmanaged<WindowEventMonitor>
            let pid: pid_t
        }
        
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon = refcon else { return }
            let context = refcon.load(as: ObserverContext.self)
            let monitor = context.monitor.takeUnretainedValue()
            let pid = context.pid
            
            Task { @MainActor in
                monitor.handleWindowEvent(
                    notification: notification as String,
                    element: element,
                    pid: pid
                )
            }
        }
        
        // Create context and pass it as refcon
        let monitorRef = Unmanaged.passUnretained(self)
        let context = ObserverContext(monitor: monitorRef, pid: pid)
        let contextPtr = UnsafeMutablePointer<ObserverContext>.allocate(capacity: 1)
        contextPtr.initialize(to: context)
        
        let result = AXObserverCreate(pid, callback, &observer)
        
        guard result == .success, let observer = observer else {
            contextPtr.deinitialize(count: 1)
            contextPtr.deallocate()
            log("⚠️ Failed to create observer for PID \(pid)")
            return
        }
        
        // Only register for window creation events
        // This catches: new windows (Cmd+N), app launches
        AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, contextPtr)
        
        // Add to run loop
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        
        observers[pid] = observer
        log("   Created observer for \(app.bundleIdentifier ?? "unknown") (PID \(pid))")
    }
    
    private func handleWindowEvent(notification: String, element: AXUIElement, pid: pid_t) {
        // Only handle window creation events
        guard notification == kAXWindowCreatedNotification as String else {
            return
        }
        
        // Ignore if we're currently repositioning
        if isRepositioning {
            return
        }
        
        // Check if this window has already been positioned
        if hasPositionedWindow(element) {
            return
        }
        
        // Find the app and trigger callback with window element
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }) {
            onWindowEvent?(app, element)
        }
    }
}
