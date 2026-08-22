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
    
    // Observer for manual moves, rather than polling for them
    private var axObserver: AXObserver?
    
    init(accessibilityService: AccessibilityService) {
        self.accessibilityService = accessibilityService
    }
    
    /// Move a window to the focus region
    func focusWindow(_ window: AXUIElement, windowID: CGWindowID, toRegion region: Region, gap: CGFloat) {
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

        // Resolve the focus region against its display, then apply the gutter
        guard let targetFrame = RegionGeometry.contentAXFrame(for: region, gap: gap) else {
            log("Cannot focus window: region '\(region.name)' has no attached display")
            return
        }

        // Store state
        focusedWindow = window
        focusedWindowID = windowID
        originalFrame = currentFrame
        focusRegionFrame = targetFrame
        
        // Move window to focus region
        accessibilityService.setWindowFrame(window, to: targetFrame)

        // Watch for the user moving it back out
        startObserving(window)
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
        stopObserving()
        focusedWindow = nil
        focusedWindowID = nil
        originalFrame = nil
        focusRegionFrame = nil
    }
    
    /// Called when the displays change underneath a focused window.
    ///
    /// Best effort restore rather than a silent drop. The stored frame may now
    /// be on a display that is gone, in which case putting the window there
    /// would hide it, so that case only clears. Previously this always
    /// discarded the restore point and left the window in the focus region.
    func handleDisplayChange() {
        guard let window = focusedWindow, let originalFrame else {
            clearFocus()
            return
        }

        DisplayRegistry.shared.refresh()
        let stillVisible = DisplayRegistry.shared.displays.contains {
            $0.axBounds.intersects(originalFrame)
        }

        if stillVisible {
            accessibilityService.setWindowFrame(window, to: originalFrame)
            log("Displays changed: restored the focused window to where it was")
        } else {
            log("Displays changed: the focused window's original position is no longer on any display, "
                + "leaving it where it is")
        }
        clearFocus()
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
    
    // MARK: - Watching for manual moves

    /// Observe the window instead of polling it.
    ///
    /// This used to poll twice a second for as long as a window was focused,
    /// which both wasted the wakeups and took up to half a second to notice.
    /// The border overlay already did it this way.
    private func startObserving(_ window: AXUIElement) {
        stopObserving()

        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let manager = Unmanaged<FocusRegionManager>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    manager.handleWindowNotification(name)
                }
            }
        }

        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(observer, window, notification as CFString, refcon)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObserver = observer
    }

    private func stopObserving() {
        guard let axObserver else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes)
        self.axObserver = nil
    }

    private func handleWindowNotification(_ notification: String) {
        if notification == kAXUIElementDestroyedNotification as String {
            clearFocus()
            return
        }
        checkFocusedWindowFrame()
    }

    /// Give up the focus state once the user has moved or resized the window
    /// away from where it was put.
    private func checkFocusedWindowFrame() {
        guard let window = focusedWindow, let focusRegionFrame else { return }

        guard let position = accessibilityService.getWindowPosition(window),
              let size = accessibilityService.getWindowSize(window) else {
            clearFocus()
            return
        }

        // Size counts as well as position. Resizing a window out of its region
        // used to leave it considered focused.
        let movedBy = abs(position.x - focusRegionFrame.origin.x)
            + abs(position.y - focusRegionFrame.origin.y)
        let resizedBy = abs(size.width - focusRegionFrame.width)
            + abs(size.height - focusRegionFrame.height)

        if movedBy > Self.driftTolerance || resizedBy > Self.driftTolerance {
            clearFocus()
        }
    }

    /// How far a window may drift before it stops counting as focused. Apps
    /// nudge their own frames by a point or two, so this is not zero.
    private static let driftTolerance: CGFloat = 10
}
