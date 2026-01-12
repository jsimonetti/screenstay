import SwiftUI

@main
struct ScreenStayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var eventCoordinator: EventCoordinator?
    
    // Services
    private let accessibilityService = AccessibilityService()
    private let windowOrderService = WindowOrderService()
    private var profileManager: ProfileManager?
    private var windowPositionEnforcer: WindowPositionEnforcer?
    private var focusCycleController: FocusCycleController?
    
    // UI
    private var configurationWindow: ConfigurationWindow?
    private var profilesMenu: NSMenu?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        log("🎬 ScreenStay starting...")
        
        // Start as menu bar only app (no dock icon)
        NSApp.setActivationPolicy(.accessory)
        
        // Check all permissions
        PermissionManager.checkAndRequestPermissions()
        
        // Initialize services
        Task {
            let profileManager = ProfileManager()
            let windowPositionEnforcer = WindowPositionEnforcer(accessibilityService: accessibilityService)
            let focusCycleController = FocusCycleController(
                windowOrderService: windowOrderService,
                profileManager: profileManager
            )
            
            self.profileManager = profileManager
            self.windowPositionEnforcer = windowPositionEnforcer
            self.focusCycleController = focusCycleController
            
            // Create event coordinator
            let coordinator = EventCoordinator(
                profileManager: profileManager,
                windowPositionEnforcer: windowPositionEnforcer,
                focusCycleController: focusCycleController,
                accessibilityService: accessibilityService
            )
            self.eventCoordinator = coordinator
            
            // Setup menu bar
            setupMenuBar()
            
            // Start event listeners
            await coordinator.start()
            
            // Update menu to reflect active profile
            updateProfilesMenu()
            
            // Observe window lifecycle to manage dock visibility
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowWillClose),
                name: NSWindow.willCloseNotification,
                object: nil
            )
            
            log("✅ ScreenStay ready")
        }
    }
    
    @objc private func windowWillClose(_ notification: Notification) {
        // When any window closes, check if we should hide from dock
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let visibleWindows = NSApp.windows.filter { 
                $0.isVisible && 
                !$0.className.contains("NSStatusBarWindow") &&
                !$0.className.contains("NSMenuWindow")
            }
            
            if visibleWindows.isEmpty {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        eventCoordinator?.stop()
        log("👋 ScreenStay stopped")
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Don't quit when windows close - we're a menu bar app
        return false
    }
    
    // MARK: - Menu Bar
    
    private func setupMenuBar() {
        Task {
            await setupMenuBarAsync()
        }
    }
    
    private func setupMenuBarAsync() async {
        log("🎨 Setting up menu bar...")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            // Try SF Symbol first, fallback to text
            if let image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "ScreenStay") {
                button.image = image
                log("✅ Menu bar icon set (SF Symbol)")
            } else {
                button.title = "⊞"
                log("✅ Menu bar icon set (text)")
            }
        } else {
            log("❌ Failed to get status bar button")
        }
        
        let menu = NSMenu()
        log("📝 Building menu...")
        
        // Profiles submenu
        let profilesMenu = NSMenu()
        let profilesItem = NSMenuItem(title: "Profiles", action: nil, keyEquivalent: "")
        profilesItem.submenu = profilesMenu
        menu.addItem(profilesItem)
        self.profilesMenu = profilesMenu
        
        // Populate profiles submenu
        updateProfilesMenu()
        
        menu.addItem(NSMenuItem.separator())
        
        // Settings
        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(showSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        // Reload Config
        let reloadItem = NSMenuItem(
            title: "Reload Config",
            action: #selector(reloadConfig),
            keyEquivalent: ""
        )
        reloadItem.target = self
        menu.addItem(reloadItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Logs
        let openLogItem = NSMenuItem(
            title: "Logs",
            action: #selector(openLogFile),
            keyEquivalent: ""
        )
        openLogItem.target = self
        menu.addItem(openLogItem)
        
        // Clear Logs
        let clearLogsItem = NSMenuItem(
            title: "Clear Logs",
            action: #selector(clearLogs),
            keyEquivalent: ""
        )
        clearLogsItem.target = self
        menu.addItem(clearLogsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit
        let quitItem = NSMenuItem(
            title: "Quit ScreenStay",
            action: #selector(quit),
            keyEquivalent: ""
        )
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
        log("✅ Menu bar setup complete")
    }
    
    private func updateProfilesMenu() {
        Task {
            guard let profilesMenu = profilesMenu else { return }
            
            profilesMenu.removeAllItems()
            
            if let config = await profileManager?.getConfiguration() {
                log("🔄 Updating menu: \(config.profiles.count) profiles")
                
                if config.profiles.isEmpty {
                    // Show helpful message when no profiles exist
                    let noProfilesItem = NSMenuItem(
                        title: "No profiles yet",
                        action: nil,
                        keyEquivalent: ""
                    )
                    noProfilesItem.isEnabled = false
                    profilesMenu.addItem(noProfilesItem)
                    
                    profilesMenu.addItem(NSMenuItem.separator())
                    
                    let addProfileItem = NSMenuItem(
                        title: "Open Settings to Add Profile",
                        action: #selector(showSettings),
                        keyEquivalent: ""
                    )
                    addProfileItem.target = self
                    profilesMenu.addItem(addProfileItem)
                } else {
                    for profile in config.profiles {
                        log("   - \(profile.name): isActive=\(profile.isActive)")
                        let item = NSMenuItem(
                            title: profile.name,
                            action: #selector(switchProfile(_:)),
                            keyEquivalent: ""
                        )
                        item.target = self
                        item.representedObject = profile.id
                        item.state = profile.isActive ? .on : .off
                        profilesMenu.addItem(item)
                    }
                }
            }
        }
    }
    
    @objc private func showSettings() {
        // Lazy initialize configuration window if needed
        if configurationWindow == nil, let profileManager = profileManager, let eventCoordinator = eventCoordinator {
            configurationWindow = ConfigurationWindow(profileManager: profileManager, eventCoordinator: eventCoordinator)
        }
        
        // Make app visible in dock when settings window opens
        NSApp.setActivationPolicy(.regular)
        
        if let window = configurationWindow?.window, window.isVisible {
            // Window already open, just bring it to front
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Window not visible, show it (will reload data)
            configurationWindow?.show()
        }
    }
    
    @objc private func switchProfile(_ sender: NSMenuItem) {
        guard let profileID = sender.representedObject as? String else { return }
        
        Task {
            if let profile = await profileManager?.getProfile(by: profileID) {
                await profileManager?.setActiveProfile(profile)
                await windowPositionEnforcer?.enforceAllRegions(profile.regions)
                
                // Rebuild menu to update checkmarks
                setupMenuBar()
                
                log("✅ Switched to profile: \(profile.name)")
            }
        }
    }
    
    @objc private func reloadConfig() {
        Task {
            do {
                try await profileManager?.reload()
                
                // Reapply profile
                if let profile = await profileManager?.autoSelectProfile() {
                    await windowPositionEnforcer?.enforceAllRegions(profile.regions)
                }
                
                // Update keyboard shortcuts with new profile
                await eventCoordinator?.updateKeyboardShortcuts()
                
                showAlert(title: "Config Reloaded", message: "Configuration has been reloaded successfully.")
            } catch {
                showAlert(title: "Reload Failed", message: "Failed to reload configuration: \(error.localizedDescription)")
            }
        }
    }
    
    @objc private func openLogFile() {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let logFile = logsDir.appendingPathComponent("Logs/ScreenStay/screenstay.log")
        
        if FileManager.default.fileExists(atPath: logFile.path) {
            NSWorkspace.shared.open(logFile)
        } else {
            showAlert(title: "Log File Not Found", message: "The log file does not exist yet. It will be created when the app starts logging.")
        }
    }
    
    @objc private func clearLogs() {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let logFile = logsDir.appendingPathComponent("Logs/ScreenStay/screenstay.log")
        
        let alert = NSAlert()
        alert.messageText = "Clear Logs?"
        alert.informativeText = "This will permanently delete all log entries. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try "".write(to: logFile, atomically: true, encoding: .utf8)
                log("🧹 Logs cleared")
                showAlert(title: "Logs Cleared", message: "All log entries have been deleted.")
            } catch {
                showAlert(title: "Error", message: "Failed to clear logs: \(error.localizedDescription)")
            }
        }
    }
    
    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
    
    // MARK: - Alerts
    
    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
