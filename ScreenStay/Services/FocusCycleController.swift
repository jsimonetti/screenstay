import Foundation
import AppKit

/// Actor responsible for handling keyboard shortcuts and region focus cycling
actor FocusCycleController {
    private let windowOrderService: WindowOrderService
    private let profileManager: ProfileManager
    
    /// Track which region was last focused for cycling behavior
    private var lastFocusedRegion: String?
    
    /// App switcher state (MainActor isolated since it's all UI)
    @MainActor
    private var switcherState: SwitcherState?
    @MainActor
    private var eventMonitor: Any?
    @MainActor
    private var localEventMonitor: Any?
    @MainActor
    private var switcherTimeout: Task<Void, Never>?
    @MainActor
    private var switcherWindow: AppSwitcherWindow?
    
    struct SwitcherState {
        let region: Region
        let apps: [(bundleID: String, name: String, isRunning: Bool)]
        var selectedIndex: Int
    }
    
    init(windowOrderService: WindowOrderService, profileManager: ProfileManager) {
        self.windowOrderService = windowOrderService
        self.profileManager = profileManager
    }
    
    /// Handle focus cycle for a region
    /// Quick press & release: toggle between 2 most recent apps
    /// Hold modifiers: show switcher UI and cycle through all apps
    @MainActor
    func cycleFocus(for region: Region) async {
        let assignedApps = region.assignedApps
        guard !assignedApps.isEmpty else {
            return
        }
        
        // If switcher is already active, advance to next app
        if let state = self.switcherState, state.region.id == region.id {
            await advanceSelection()
            return
        }
        
        // Build app list for this region
        let apps = await buildAppList(for: region)
        guard !apps.isEmpty else {
            return
        }
        
        // Single app: just activate it
        if apps.count == 1 {
            await activateApp(apps[0].bundleID, launchIfNeeded: true)
            return
        }
        
        // Determine initial selection:
        // If currently focused app is the first in the region list, select second (toggle behavior)
        // Otherwise, select first (bring focus to region)
        let currentApp = NSWorkspace.shared.frontmostApplication
        let currentBundleID = currentApp?.bundleIdentifier
        let initialIndex = (currentBundleID == apps[0].bundleID && apps.count > 1) ? 1 : 0
        
        // Initialize switcher state
        let state = SwitcherState(
            region: region,
            apps: apps,
            selectedIndex: initialIndex
        )
        switcherState = state
        
        // Get scale setting
        let config = await profileManager.getConfiguration()
        let scale = config.globalSettings.appSwitcherScale
        
        // Show switcher UI
        if switcherWindow == nil {
            switcherWindow = AppSwitcherWindow()
        }
        switcherWindow?.setScale(scale)
        switcherWindow?.updateApps(apps, selectedIndex: initialIndex)
        if let cocoaFrame = RegionGeometry.absoluteCocoaFrame(for: region) {
            switcherWindow?.show(centeredIn: cocoaFrame)
        }
        
        // Start monitoring for modifier release
        await startModifierMonitoring()
    }
    
    /// Build ordered list of apps for region (running apps by MRU, then unstarted)
    @MainActor
    private func buildAppList(for region: Region) async -> [(bundleID: String, name: String, isRunning: Bool)] {
        var apps: [(bundleID: String, name: String, isRunning: Bool)] = []
        
        // Get running apps from region (ordered by most recent use)
        let regionWindows = windowOrderService.getWindows(forBundleIDs: region.assignedApps)
        var seenBundleIDs = Set<String>()
        
        for window in regionWindows {
            guard let bundleID = window.bundleID, !seenBundleIDs.contains(bundleID) else { continue }
            seenBundleIDs.insert(bundleID)
            
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
                let name = app.localizedName ?? bundleID
                apps.append((bundleID: bundleID, name: name, isRunning: true))
            }
        }
        
        // Add unstarted apps from config
        for bundleID in region.assignedApps {
            if !seenBundleIDs.contains(bundleID) {
                let name = appName(for: bundleID)
                apps.append((bundleID: bundleID, name: name, isRunning: false))
            }
        }
        
        return apps
    }
    
    /// Get human-readable app name from bundle ID
    @MainActor
    private func appName(for bundleID: String) -> String {
        // Try to get app name from workspace
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return name
        }
        
        // Fallback: extract from bundle ID
        let components = bundleID.split(separator: ".")
        return components.last.map(String.init) ?? bundleID
    }
    
    /// Advance to next app in switcher
    @MainActor
    private func advanceSelection() async {
        guard var state = switcherState else { return }
        
        state.selectedIndex = (state.selectedIndex + 1) % state.apps.count
        switcherState = state
        
        switcherWindow?.updateApps(state.apps, selectedIndex: state.selectedIndex)
    }
    
    /// Start monitoring for modifier key release
    ///
    /// Two monitors, not one. A global monitor only sees events dispatched to
    /// *other* applications, so as soon as ScreenStay itself is active - which
    /// it is whenever the Settings window is open - the modifier release never
    /// arrives and the switcher hangs with no way to commit or dismiss it.
    @MainActor
    private func startModifierMonitoring() async {
        stopModifierMonitoring()

        let onFlagsChanged: @MainActor (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let held = modifiers.contains(.command) || modifiers.contains(.control)
                || modifiers.contains(.option) || modifiers.contains(.shift)
            if !held {
                Task { await self.commitSelection() }
            }
        }

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            Task { @MainActor in onFlagsChanged(event) }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            MainActor.assumeIsolated { onFlagsChanged(event) }
            return event
        }

        startSwitcherTimeout()
    }

    /// Commit anyway if the modifiers are never seen going up.
    ///
    /// A quick enough tap releases them before the monitors are installed, and
    /// nothing would arrive to close the switcher.
    @MainActor
    private func startSwitcherTimeout() {
        switcherTimeout?.cancel()
        switcherTimeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.switcherTimeout))
            guard !Task.isCancelled, self.switcherState != nil else { return }

            // If the modifiers really are still down the user is still choosing,
            // so only give up when nothing is held.
            let held = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let stillHolding = held.contains(.command) || held.contains(.control)
                || held.contains(.option) || held.contains(.shift)
            if stillHolding {
                self.startSwitcherTimeout()
                return
            }

            log("App switcher timed out with no modifier release; committing")
            await self.commitSelection()
        }
    }

    @MainActor
    private func stopModifierMonitoring() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
        eventMonitor = nil
        localEventMonitor = nil
        switcherTimeout?.cancel()
        switcherTimeout = nil
    }

    /// How long to wait for a modifier release before assuming it was missed.
    private static let switcherTimeout: Double = 2

    /// Activate the selected app and hide switcher
    @MainActor
    private func commitSelection() async {
        guard let state = switcherState else { return }
        
        let selectedApp = state.apps[state.selectedIndex]
        
        // Hide switcher
        switcherWindow?.hide()
        switcherState = nil

        stopModifierMonitoring()
        
        // Activate or launch the app
        await activateApp(selectedApp.bundleID, launchIfNeeded: !selectedApp.isRunning)
    }
    
    /// Activate an app, optionally launching it if not running
    @MainActor
    private func activateApp(_ bundleID: String, launchIfNeeded: Bool) async {
        let runningApps = NSWorkspace.shared.runningApplications
        
        if let app = runningApps.first(where: { $0.bundleIdentifier == bundleID }) {
            // App is running - send reopen event (like clicking Dock) then activate
            sendReopenEvent(to: app)
            app.activate()
        } else if launchIfNeeded {
            // Check global setting
            let config = await profileManager.getConfiguration()
            let requireConfirm = config.globalSettings.requireConfirmToLaunchApps
            
            if requireConfirm {
                // Require manual launch when this setting is enabled
                return
            }
            
            // Launch the app
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            }
        }
    }
    
    /// Send reopen AppleEvent to app (simulates clicking Dock icon)
    @MainActor
    private func sendReopenEvent(to app: NSRunningApplication) {
        let pid = app.processIdentifier
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        
        // Send the reopen event (no reply needed)
        _ = try? event.sendEvent(options: .noReply, timeout: 1.0)
    }
}
