import Foundation
import ApplicationServices
import AppKit

/// Monitors window-level events using AXObserver for specific applications
@MainActor
class WindowEventMonitor {
    
    /// Observer per process, with the bundle identifier it was created for.
    ///
    /// The identifier is kept because macOS recycles process IDs. Without it a
    /// new app inheriting a dead one's PID looks like an existing observer and
    /// is never watched.
    private var observers: [pid_t: (observer: AXObserver, bundleID: String)] = [:]
    private var monitoredBundleIDs: Set<String> = [] // Apps assigned to regions (for window creation)

    /// Windows already placed, remembered with their owning process.
    ///
    /// `CGWindowID` is 32 bits and gets reused. Keyed by ID alone, a recycled
    /// value makes a genuinely new window look already positioned, and it is
    /// then silently skipped. Pairing with the PID makes that far less likely,
    /// and the set is pruned so it cannot grow without bound.
    private var positionedWindows: [CGWindowID: pid_t] = [:]

    /// Depth of in-flight repositioning, not a flag.
    ///
    /// Repositioning happens per app in sequence and each one clears itself
    /// after a delay, so a single boolean gets cleared by an earlier call while
    /// a later one is still running.
    private var repositioningDepth = 0

    /// Prune the positioned set once it passes this, measured against the
    /// windows actually on screen.
    private static let positionedWindowsPruneThreshold = 256

    private let accessibilityService: AccessibilityService
    
    var onWindowEvent: ((NSRunningApplication, AXUIElement, String) -> Void)?
    
    init(accessibilityService: AccessibilityService) {
        self.accessibilityService = accessibilityService
    }
    
    // MARK: - Public API
    
    /// Start monitoring windows for the given bundle IDs
    func startMonitoring(bundleIDs: Set<String>) {
        monitoredBundleIDs = bundleIDs
        
        // Monitor ALL currently running apps (for focus changes and window creation)
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier, !bundleID.isEmpty {
                createObserver(for: app, monitorCreation: monitoredBundleIDs.contains(bundleID))
            }
        }
    }
    
    /// Stop monitoring all windows
    func stopMonitoring() {
        for (_, entry) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(entry.observer), .commonModes)
        }
        observers.removeAll()
        monitoredBundleIDs.removeAll()
        positionedWindows.removeAll()
    }
    
    /// Check if we should monitor this app
    func shouldMonitor(_ app: NSRunningApplication) -> Bool {
        // We monitor ALL apps now (for focus changes)
        guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return false }
        return true
    }
    
    /// Create observer for a newly launched app
    func observeApp(_ app: NSRunningApplication) async {
        guard shouldMonitor(app), let bundleID = app.bundleIdentifier else { return }
        createObserver(for: app, monitorCreation: monitoredBundleIDs.contains(bundleID))
    }
    
    /// Remove observer when app terminates
    func removeObserver(for app: NSRunningApplication) async {
        let pid = app.processIdentifier
        if let entry = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(entry.observer), .commonModes)
        }

        // Now that positioned windows record their owner, the dead app's
        // entries can go, which is most of what kept the set growing.
        positionedWindows = positionedWindows.filter { $0.value != pid }
    }
    
    /// Mark that we are about to reposition a window (to ignore subsequent events)
    func willRepositionWindow() {
        repositioningDepth += 1
    }

    /// Mark that we finished repositioning
    func didRepositionWindow() {
        // Small delay so any events the move triggered arrive while still suppressed.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            repositioningDepth = max(0, repositioningDepth - 1)
        }
    }
    
    /// Mark a window as positioned (either by us or by user)
    func markWindowAsPositioned(_ window: AXUIElement) {
        guard let windowID = accessibilityService.getWindowID(window),
              let pid = accessibilityService.getPID(window) else {
            return
        }
        positionedWindows[windowID] = pid
        prunePositionedWindowsIfNeeded()
    }

    /// Remove a window from the positioned set (to allow repositioning)
    func removeWindowFromPositioned(_ window: AXUIElement) {
        if let windowID = accessibilityService.getWindowID(window) {
            positionedWindows.removeValue(forKey: windowID)
        }
    }

    /// Check if we've already positioned this window
    func hasPositionedWindow(_ window: AXUIElement) -> Bool {
        guard let windowID = accessibilityService.getWindowID(window),
              let pid = accessibilityService.getPID(window) else {
            return false
        }
        // Same ID but a different owner means the ID was recycled.
        return positionedWindows[windowID] == pid
    }

    /// Reset all positioned window tracking (e.g., when profile changes)
    func resetPositionedWindows() {
        positionedWindows.removeAll()
    }

    /// Drop entries for windows that are no longer on screen.
    private func prunePositionedWindowsIfNeeded() {
        guard positionedWindows.count > Self.positionedWindowsPruneThreshold else { return }

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        let live = Set(windowList.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })

        let before = positionedWindows.count
        positionedWindows = positionedWindows.filter { live.contains($0.key) }
        log("Pruned positioned window tracking: \(before) -> \(positionedWindows.count)")
    }
    
    // MARK: - Private Implementation
    
    private func createObserver(for app: NSRunningApplication, monitorCreation: Bool) {
        let pid = app.processIdentifier
        guard let bundleID = app.bundleIdentifier else { return }

        if let existing = observers[pid] {
            // Same process, already watched.
            guard existing.bundleID != bundleID else { return }
            // Different app on a recycled PID: the old observer is dead weight
            // and would otherwise block this app from ever being watched.
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(existing.observer), .commonModes)
            observers.removeValue(forKey: pid)
            log("Reusing recycled PID \(pid): \(existing.bundleID) -> \(bundleID)")
        }

        let appElement = AXUIElementCreateApplication(pid)
        var observer: AXObserver?

        // The PID is read back from the element rather than carried in a context
        // struct. The struct had to be heap allocated per observer and was only
        // freed on the failure path, so every observed app leaked one.
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<WindowEventMonitor>.fromOpaque(refcon).takeUnretainedValue()

            var elementPID: pid_t = 0
            guard AXUIElementGetPid(element, &elementPID) == .success else { return }

            Task { @MainActor in
                monitor.handleWindowEvent(
                    notification: notification as String,
                    element: element,
                    pid: elementPID
                )
            }
        }

        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else {
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // Register for focus change events for ALL apps
        AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, refcon)

        // Only register for window creation if app is assigned to a region
        if monitorCreation {
            AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, refcon)
        }

        // commonModes, not defaultMode. In defaultMode these callbacks stop
        // arriving while a menu is open or a drag is in progress, which is
        // exactly when windows are being created and focus is changing.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)

        observers[pid] = (observer, bundleID)
    }

    private func handleWindowEvent(notification: String, element: AXUIElement, pid: pid_t) {
        // Direct lookup. Scanning runningApplications ran on every focus change.
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return
        }
        
        // Handle window creation events
        if notification == kAXWindowCreatedNotification as String {
            // Ignore anything triggered by our own repositioning.
            if repositioningDepth > 0 {
                return
            }
            
            // Check if this window has already been positioned
            if hasPositionedWindow(element) {
                return
            }
            
            // Trigger callback with window element and notification type
            onWindowEvent?(app, element, notification)
        }
        // Handle focus change events - just update border
        else if notification == kAXFocusedWindowChangedNotification as String {
            // Trigger callback to update border only
            onWindowEvent?(app, element, notification)
        }
    }
}
