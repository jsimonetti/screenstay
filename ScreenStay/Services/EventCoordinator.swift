import Foundation
import AppKit

/// Coordinates all event listeners and dispatches to appropriate handlers
@MainActor
class EventCoordinator: ObservableObject {
    private let profileManager: ProfileManager
    private let windowPositionEnforcer: WindowPositionEnforcer
    private let focusCycleController: FocusCycleController
    private let accessibilityService: AccessibilityService
    private let keyboardHandler = GlobalKeyboardHandler()
    private let windowEventMonitor: WindowEventMonitor
    private let focusRegionManager: FocusRegionManager
    
    init(
        profileManager: ProfileManager,
        windowPositionEnforcer: WindowPositionEnforcer,
        focusCycleController: FocusCycleController,
        accessibilityService: AccessibilityService
    ) {
        self.profileManager = profileManager
        self.focusCycleController = focusCycleController
        self.accessibilityService = accessibilityService
        
        // Create window event monitor with access to accessibility service
        self.windowEventMonitor = WindowEventMonitor(accessibilityService: accessibilityService)
        
        // Create focus region manager
        self.focusRegionManager = FocusRegionManager(accessibilityService: accessibilityService)
        
        // Initialize enforcer with monitor reference
        self.windowPositionEnforcer = windowPositionEnforcer
        
        // Set monitor on enforcer (async actor call)
        Task {
            await windowPositionEnforcer.setWindowEventMonitor(windowEventMonitor)
        }
    }
    
    /// Start listening to system events
    func start() async {
        print("🎧 Starting event listeners...")
        
        // Auto-select initial profile
        if let profile = await profileManager.autoSelectProfile() {
            await windowPositionEnforcer.enforceAllRegions(profile.regions)
        }
        
        // Get all bundle IDs assigned to regions
        let bundleIDs = await getBundleIDsFromActiveRegions()
        
        // Start monitoring window events for these apps
        windowEventMonitor.startMonitoring(bundleIDs: bundleIDs)
        windowEventMonitor.onWindowEvent = { [weak self] app, window in
            Task { @MainActor in
                await self?.handleWindowEvent(for: app, window: window)
            }
        }
        
        // Listen to app launch/termination
        setupAppLifecycleListeners()
        
        // Listen to app activation events
        setupAppActivationListener()
        
        // Listen to display configuration changes
        setupDisplayChangeListener()
        
        // Listen to keyboard shortcuts
        await setupKeyboardShortcuts()
        
        print("✅ Event listeners active")
    }
    
    /// Stop listening to events
    func stop() {
        keyboardHandler.stop()
        windowEventMonitor.stopMonitoring()
        
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        
        print("🛑 Event listeners stopped")
    }
    
    // MARK: - App Lifecycle Listeners
    
    private func setupAppLifecycleListeners() {
        // Monitor app launches to create observers
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            
            Task { @MainActor in
                await self.windowEventMonitor.observeApp(app)
            }
        }
        
        // Monitor app terminations to clean up observers
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            
            Task { @MainActor in
                await self.windowEventMonitor.removeObserver(for: app)
            }
        }
    }
    
    // MARK: - App Activation Listener
    
    private func setupAppActivationListener() {
        // This notification fires when:
        // 1. An app is launched and becomes active (initial launch)
        // 2. An app is brought to foreground (Cmd+Tab, dock click)
        // 3. A new window is created in an active app (Cmd+N)
        // This single listener covers all window positioning scenarios
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else {
                return
            }
            
            print("🔄 App activated: \(bundleID)")
            
            Task {
                await self.handleAppActivation(app)
            }
        }
    }
    
    private func handleAppActivation(_ app: NSRunningApplication) async {
        guard let bundleID = app.bundleIdentifier else { return }
        
        // Check if repositioning is enabled
        let config = await profileManager.getConfiguration()
        guard config.globalSettings.repositionOnAppLaunch else {
            return
        }
        
        // Get active regions
        let regions = await profileManager.activeRegions
        
        // Find region for this app
        guard let region = regions.first(where: { $0.assignedApps.contains(bundleID) }) else {
            return
        }
        
        // Get frontmost window
        guard let window = accessibilityService.getFrontmostWindow(for: app) else {
            return
        }
        
        // Check if we've already positioned this window
        if windowEventMonitor.hasPositionedWindow(window) {
            return // Already handled
        }
        
        // Reposition this window and mark it as positioned
        // This handles the race condition where app activates before observer is created
        await windowPositionEnforcer.enforceRegion(region, for: app, window: window)
        windowEventMonitor.markWindowAsPositioned(window)
    }
    
    // MARK: - Display Change Listener
    
    private func setupDisplayChangeListener() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            
            print("🖥️ Display configuration changed")
            
            Task {
                await self.handleDisplayChange()
            }
        }
    }
    
    private func handleDisplayChange() async {
        // Clear any focused window since display topology changed
        focusRegionManager.clearFocus()
        
        // Reset window tracking since display topology changed
        windowEventMonitor.resetPositionedWindows()
        
        // Auto-select matching profile
        if let profile = await profileManager.autoSelectProfile() {
            // Reposition all windows
            await windowPositionEnforcer.enforceAllRegions(profile.regions)
        }
    }
    
    // MARK: - Window Event Handling
    
    private func handleWindowEvent(for app: NSRunningApplication, window: AXUIElement) async {
        guard let bundleID = app.bundleIdentifier else { return }
        
        // Filter out system dialogs, sheets, and floating windows
        guard accessibilityService.shouldPositionWindow(window) else {
            return
        }
        
        // Check if repositioning is enabled
        let config = await profileManager.getConfiguration()
        guard config.globalSettings.repositionOnAppLaunch else {
            return
        }
        
        // Get active regions
        let regions = await profileManager.activeRegions
        
        // Find region for this app
        guard let region = regions.first(where: { $0.assignedApps.contains(bundleID) }) else {
            return
        }
        
        // Reposition the window and mark it as positioned
        await windowPositionEnforcer.enforceRegion(region, for: app, window: window)
        windowEventMonitor.markWindowAsPositioned(window)
    }
    
    private func getBundleIDsFromActiveRegions() async -> Set<String> {
        let regions = await profileManager.activeRegions
        var bundleIDs = Set<String>()
        for region in regions {
            bundleIDs.formUnion(region.assignedApps)
        }
        return bundleIDs
    }
    
    // MARK: - Keyboard Shortcuts
    
    private func setupKeyboardShortcuts() async {
        let regions = await profileManager.activeRegions
        let config = await profileManager.getConfiguration()
        
        // Collect all shortcuts (region shortcuts + reset window shortcut + focus window shortcut)
        var shortcuts = regions.compactMap { $0.keyboardShortcut }
        if let resetShortcut = config.globalSettings.resetWindowShortcut {
            shortcuts.append(resetShortcut)
        }
        if let focusShortcut = config.globalSettings.focusWindowShortcut {
            shortcuts.append(focusShortcut)
        }
        
        keyboardHandler.start(shortcuts: shortcuts) { [weak self] shortcut in
            guard let self = self else { return }
            
            Task {
                let config = await self.profileManager.getConfiguration()
                
                // Check if this is the reset window shortcut
                if let resetShortcut = config.globalSettings.resetWindowShortcut,
                   shortcut.key == resetShortcut.key && shortcut.modifiers == resetShortcut.modifiers {
                    await self.handleResetWindowShortcut()
                    return
                }
                
                // Check if this is the focus window shortcut
                if let focusShortcut = config.globalSettings.focusWindowShortcut,
                   shortcut.key == focusShortcut.key && shortcut.modifiers == focusShortcut.modifiers {
                    await self.handleFocusWindowShortcut()
                    return
                }
                
                // Otherwise, find the region with this shortcut
                let regions = await self.profileManager.activeRegions
                if let region = regions.first(where: { $0.keyboardShortcut?.key == shortcut.key && 
                                                            $0.keyboardShortcut?.modifiers == shortcut.modifiers }) {
                    await self.focusCycleController.cycleFocus(for: region)
                }
            }
        }
    }
    
    func updateKeyboardShortcuts() async {
        // Simply call setupKeyboardShortcuts to restart the handler with updated shortcuts
        // This ensures both the shortcut list and the callback logic are properly updated
        await setupKeyboardShortcuts()
    }
    
    // MARK: - Reset Window Handler
    
    private func handleResetWindowShortcut() async {
        // Get the currently focused window
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontmostApp.bundleIdentifier else {
            return
        }
        
        // Get the focused window using accessibility API
        guard let focusedWindow = accessibilityService.getFrontmostWindow(for: frontmostApp) else {
            return
        }
        
        // Find which region this app belongs to
        let regions = await profileManager.activeRegions
        guard let region = regions.first(where: { $0.assignedApps.contains(bundleID) }) else {
            return
        }
        
        // Don't reposition dialogs/sheets even with explicit shortcut
        guard accessibilityService.shouldPositionWindow(focusedWindow) else {
            return
        }
        
        // Reposition the window
        await windowPositionEnforcer.enforceRegion(region, for: frontmostApp, window: focusedWindow)
    }
    
    // MARK: - Focus Window Handler
    
    private func handleFocusWindowShortcut() async {
        // Get the currently frontmost window
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return
        }
        
        guard let frontmostWindow = accessibilityService.getFrontmostWindow(for: frontmostApp) else {
            return
        }
        
        // Don't focus dialogs/sheets
        guard accessibilityService.shouldPositionWindow(frontmostWindow) else {
            return
        }
        
        // Get window ID for tracking
        guard let windowID = accessibilityService.getWindowID(frontmostWindow) else {
            return
        }
        
        // Find the focus region in active profile
        let regions = await profileManager.activeRegions
        guard let focusRegion = regions.first(where: { $0.isFocusRegion }) else {
            return
        }
        
        // If this window is already focused, unfocus it (toggle)
        if focusRegionManager.isWindowFocused(windowID) {
            focusRegionManager.unfocusWindow()
            return
        }
        
        // Focus the window (this will unfocus any previously focused window)
        focusRegionManager.focusWindow(frontmostWindow, windowID: windowID, toRegion: focusRegion)
    }
}
