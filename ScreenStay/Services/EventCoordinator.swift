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
    
    init(
        profileManager: ProfileManager,
        windowPositionEnforcer: WindowPositionEnforcer,
        focusCycleController: FocusCycleController,
        accessibilityService: AccessibilityService
    ) {
        self.profileManager = profileManager
        self.windowPositionEnforcer = windowPositionEnforcer
        self.focusCycleController = focusCycleController
        self.accessibilityService = accessibilityService
    }
    
    /// Start listening to system events
    func start() async {
        print("🎧 Starting event listeners...")
        
        // Auto-select initial profile
        if let profile = await profileManager.autoSelectProfile() {
            await windowPositionEnforcer.enforceAllRegions(profile.regions)
        }
        
        // Listen to app launch events
        setupAppLaunchListener()
        
        // Listen to display configuration changes
        setupDisplayChangeListener()
        
        // Listen to keyboard shortcuts
        await setupKeyboardShortcuts()
        
        print("✅ Event listeners active")
    }
    
    /// Stop listening to events
    func stop() {
        keyboardHandler.stop()
        
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        
        print("🛑 Event listeners stopped")
    }
    
    // MARK: - App Launch Listener
    
    private func setupAppLaunchListener() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else {
                return
            }
            
            print("🚀 App launched: \(bundleID)")
            
            Task {
                await self.handleAppLaunch(app)
            }
        }
    }
    
    private func handleAppLaunch(_ app: NSRunningApplication) async {
        guard let bundleID = app.bundleIdentifier else { return }
        
        // Get active regions
        let regions = await profileManager.activeRegions
        
        // Find region for this app
        guard let region = regions.first(where: { $0.assignedApps.contains(bundleID) }) else {
            print("   App not assigned to any region")
            return
        }
        
        // Wait a moment for the window to be created
        try? await Task.sleep(for: .milliseconds(500))
        
        // Enforce region
        await windowPositionEnforcer.enforceRegion(region, for: app)
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
        // Auto-select matching profile
        if let profile = await profileManager.autoSelectProfile() {
            // Reposition all windows
            await windowPositionEnforcer.enforceAllRegions(profile.regions)
        }
    }
    
    // MARK: - Keyboard Shortcuts
    
    private func setupKeyboardShortcuts() async {
        let regions = await profileManager.activeRegions
        log("🎹 EventCoordinator: Found \(regions.count) active regions")
        
        for region in regions {
            if let shortcut = region.keyboardShortcut {
                log("   - \(region.name): \(shortcut.modifiers.joined(separator: "+"))+\(shortcut.key)")
            } else {
                log("   - \(region.name): NO SHORTCUT")
            }
        }
        
        let shortcuts = regions.compactMap { $0.keyboardShortcut }
        log("🎹 Starting keyboard handler with \(shortcuts.count) shortcuts")
        
        keyboardHandler.start(shortcuts: shortcuts) { [weak self] shortcut in
            guard let self = self else { return }
            
            Task {
                // Find the region with this shortcut
                let regions = await self.profileManager.activeRegions
                if let region = regions.first(where: { $0.keyboardShortcut?.key == shortcut.key && 
                                                            $0.keyboardShortcut?.modifiers == shortcut.modifiers }) {
                    log("⌨️ Triggering region: \(region.name)")
                    await self.focusCycleController.cycleFocus(for: region)
                }
            }
        }
    }
    
    func updateKeyboardShortcuts() async {
        let regions = await profileManager.activeRegions
        let shortcuts = regions.compactMap { $0.keyboardShortcut }
        log("🔄 Updating keyboard handler with \(shortcuts.count) shortcuts")
        keyboardHandler.updateShortcuts(shortcuts)
    }
}
