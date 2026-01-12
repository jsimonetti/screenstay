import AppKit
import SwiftUI

/// Main settings window with tabs for Profiles, Regions, and Global Settings
@MainActor
class ConfigurationWindow: NSWindowController {
    private let profileManager: ProfileManager
    private weak var eventCoordinator: EventCoordinator?
    private let overlayManager = RegionOverlayManager()
    
    private var config: AppConfiguration?
    private var selectedProfileID: String?
    
    // Retain the region editor dialog so it doesn't get deallocated
    private var regionEditorDialog: RegionEditorDialog?
    
    // UI Components
    private let tabView = NSTabView()
    
    // Profiles Tab
    private let profilesTableView = NSTableView()
    private let captureDisplaysButton = NSButton()
    private let activateProfileButton = NSButton()
    private let addProfileButton = NSButton()
    private let deleteProfileButton = NSButton()
    
    // Regions Tab
    private let regionsTableView = NSTableView()
    private let regionProfileSelector = NSPopUpButton()
    private let regionProfileLabel = NSTextField()
    private let toggleOverlayButton = NSButton()
    private let addRegionButton = NSButton()
    private let editRegionButton = NSButton()
    private let deleteRegionButton = NSButton()
    private let designateFocusRegionButton = NSButton()
    
    // Global Settings Tab
    private let autoSwitchCheckbox = NSButton()
    private let autoRepositionCheckbox = NSButton()
    private let requireConfirmCheckbox = NSButton()
    private var resetWindowShortcutRecorder: KeyboardShortcutRecorder?
    private var focusWindowShortcutRecorder: KeyboardShortcutRecorder?
    
    init(profileManager: ProfileManager, eventCoordinator: EventCoordinator) {
        self.profileManager = profileManager
        self.eventCoordinator = eventCoordinator
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ScreenStay Settings"
        window.center()
        window.isReleasedWhenClosed = false
        
        super.init(window: window)
        
        // Setup callback for region updates from overlay
        overlayManager.onRegionsUpdated = { [weak self] updatedRegions in
            self?.updateRegionsFromOverlay(updatedRegions)
        }
        
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    
    private func loadConfiguration() async {
        self.config = await profileManager.getConfiguration()
        self.selectedProfileID = config?.profiles.first?.id
    }
    
    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        
        // Add save button at the bottom
        let saveButton = NSButton(title: "Save Changes", target: self, action: #selector(saveConfiguration))
        saveButton.bezelStyle = .rounded
        saveButton.setButtonType(.momentaryPushIn)
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(saveButton)
        
        tabView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabView)
        
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor),
            tabView.bottomAnchor.constraint(equalTo: saveButton.topAnchor, constant: -12),
            
            saveButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            saveButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            saveButton.widthAnchor.constraint(equalToConstant: 150)
        ])
        
        setupProfilesTab()
        setupRegionsTab()
        setupGlobalSettingsTab()
    }
    
    // MARK: - Profiles Tab
    
    private func setupProfilesTab() {
        let tabItem = NSTabViewItem(identifier: "profiles")
        tabItem.label = "Profiles"
        
        let containerView = NSView()
        
        // Table view with scroll
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        
        profilesTableView.translatesAutoresizingMaskIntoConstraints = false
        profilesTableView.delegate = self
        profilesTableView.dataSource = self
        
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Profile Name"
        nameColumn.width = 200
        profilesTableView.addTableColumn(nameColumn)
        
        let displaysColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("displays"))
        displaysColumn.title = "Display Topology"
        displaysColumn.width = 400
        profilesTableView.addTableColumn(displaysColumn)
        
        scrollView.documentView = profilesTableView
        containerView.addSubview(scrollView)
        
        // Buttons
        let buttonStack = NSStackView()
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        
        addProfileButton.title = "Add Profile"
        addProfileButton.bezelStyle = .rounded
        addProfileButton.setButtonType(.momentaryPushIn)
        addProfileButton.target = self
        addProfileButton.action = #selector(addProfile)
        
        deleteProfileButton.title = "Delete Profile"
        deleteProfileButton.bezelStyle = .rounded
        deleteProfileButton.setButtonType(.momentaryPushIn)
        deleteProfileButton.target = self
        deleteProfileButton.action = #selector(deleteProfile)
        
        captureDisplaysButton.title = "Capture Current Displays"
        captureDisplaysButton.bezelStyle = .rounded
        captureDisplaysButton.setButtonType(.momentaryPushIn)
        captureDisplaysButton.target = self
        captureDisplaysButton.action = #selector(captureDisplays)
        
        activateProfileButton.title = "Activate Profile"
        activateProfileButton.bezelStyle = .rounded
        activateProfileButton.setButtonType(.momentaryPushIn)
        activateProfileButton.target = self
        activateProfileButton.action = #selector(activateProfile)
        
        buttonStack.addArrangedSubview(addProfileButton)
        buttonStack.addArrangedSubview(deleteProfileButton)
        buttonStack.addArrangedSubview(captureDisplaysButton)
        buttonStack.addArrangedSubview(activateProfileButton)
        
        containerView.addSubview(buttonStack)
        
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 20),
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -20),
            
            buttonStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            buttonStack.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -20)
        ])
        
        tabItem.view = containerView
        tabView.addTabViewItem(tabItem)
    }
    
    @objc private func addProfile() {
        // Ask for profile name
        let alert = NSAlert()
        alert.messageText = "Create New Profile"
        alert.informativeText = "Enter a name for the new profile:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "Profile Name"
        alert.accessoryView = input
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            
            // Capture current display topology
            let topology = DisplayCapture.captureCurrentTopology()
            
            // Create new profile
            let newProfile = Profile(
                id: UUID().uuidString,
                name: name,
                displayTopology: topology,
                regions: []
            )
            
            config?.profiles.append(newProfile)
            profilesTableView.reloadData()
            
            // Select the new profile
            if let index = config?.profiles.firstIndex(where: { $0.id == newProfile.id }) {
                profilesTableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        }
    }
    
    @objc private func deleteProfile() {
        let selectedRow = profilesTableView.selectedRow
        guard selectedRow >= 0, let profile = config?.profiles[safe: selectedRow] else {
            showAlert(message: "Please select a profile to delete")
            return
        }
        
        // Confirm deletion
        let alert = NSAlert()
        alert.messageText = "Delete Profile?"
        alert.informativeText = "Are you sure you want to delete the profile '\(profile.name)'? This will also delete all its regions."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            config?.profiles.remove(at: selectedRow)
            profilesTableView.reloadData()
            regionsTableView.reloadData()
            
            // Select another profile if available
            if let profiles = config?.profiles, !profiles.isEmpty {
                let newSelection = min(selectedRow, profiles.count - 1)
                profilesTableView.selectRowIndexes(IndexSet(integer: newSelection), byExtendingSelection: false)
            } else {
                selectedProfileID = nil
            }
        }
    }
    
    @objc private func captureDisplays() {
        let topology = DisplayCapture.captureCurrentTopology()
        let description = DisplayCapture.describeTopology(topology)
        
        let alert = NSAlert()
        alert.messageText = "Display Topology Captured"
        alert.informativeText = "\(description)\n\nDo you want to update the selected profile with this topology?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Update Profile")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Update selected profile
            let selectedRow = profilesTableView.selectedRow
            if selectedRow >= 0, var profile = config?.profiles[safe: selectedRow] {
                profile.displayTopology = topology
                config?.profiles[selectedRow] = profile
                profilesTableView.reloadData()
            }
        }
    }
    
    @objc private func activateProfile() {
        let selectedRow = profilesTableView.selectedRow
        guard selectedRow >= 0, let profile = config?.profiles[safe: selectedRow] else {
            showAlert(message: "Please select a profile to activate")
            return
        }
        
        Task {
            await profileManager.setActiveProfile(profile)
            
            // Refresh the menu to update profile checkmarks
            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = "Profile Activated"
                alert.informativeText = "The profile '\(profile.name)' is now active."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }
    
    @objc private func profileNameChanged(_ sender: NSTextField) {
        let row = sender.tag
        let newName = sender.stringValue.trimmingCharacters(in: .whitespaces)
        
        guard !newName.isEmpty, row >= 0, row < (config?.profiles.count ?? 0) else {
            // Revert to original name if invalid
            profilesTableView.reloadData()
            return
        }
        
        config?.profiles[row].name = newName
    }
    
    // MARK: - Regions Tab
    
    private func setupRegionsTab() {
        let tabItem = NSTabViewItem(identifier: "regions")
        tabItem.label = "Regions"
        
        let containerView = NSView()
        
        // Profile selector
        regionProfileSelector.translatesAutoresizingMaskIntoConstraints = false
        regionProfileSelector.target = self
        regionProfileSelector.action = #selector(profileSelectorChanged)
        containerView.addSubview(regionProfileSelector)
        
        // Profile label
        regionProfileLabel.isEditable = false
        regionProfileLabel.isBordered = false
        regionProfileLabel.drawsBackground = false
        regionProfileLabel.font = .systemFont(ofSize: 11, weight: .regular)
        regionProfileLabel.textColor = .secondaryLabelColor
        regionProfileLabel.stringValue = "Profile:"
        regionProfileLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(regionProfileLabel)
        
        // Table view with scroll
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        
        regionsTableView.translatesAutoresizingMaskIntoConstraints = false
        regionsTableView.delegate = self
        regionsTableView.dataSource = self
        
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("regionName"))
        nameColumn.title = "Region Name"
        nameColumn.width = 150
        regionsTableView.addTableColumn(nameColumn)
        
        let frameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("frame"))
        frameColumn.title = "Frame"
        frameColumn.width = 200
        regionsTableView.addTableColumn(frameColumn)
        
        let shortcutColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("shortcut"))
        shortcutColumn.title = "Keyboard Shortcut"
        shortcutColumn.width = 150
        regionsTableView.addTableColumn(shortcutColumn)
        
        scrollView.documentView = regionsTableView
        containerView.addSubview(scrollView)
        
        // Buttons
        let buttonStack = NSStackView()
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        
        addRegionButton.title = "Add Region"
        addRegionButton.bezelStyle = .rounded
        addRegionButton.target = self
        addRegionButton.action = #selector(addRegion)
        
        editRegionButton.title = "Edit Region"
        editRegionButton.bezelStyle = .rounded
        editRegionButton.target = self
        editRegionButton.action = #selector(editRegion)
        
        deleteRegionButton.title = "Delete Region"
        deleteRegionButton.bezelStyle = .rounded
        deleteRegionButton.target = self
        deleteRegionButton.action = #selector(deleteRegion)
        
        toggleOverlayButton.title = "Show Overlay"
        toggleOverlayButton.bezelStyle = .rounded
        toggleOverlayButton.target = self
        toggleOverlayButton.action = #selector(toggleOverlay)
        
        designateFocusRegionButton.title = "Designate as Focus Region"
        designateFocusRegionButton.bezelStyle = .rounded
        designateFocusRegionButton.target = self
        designateFocusRegionButton.action = #selector(designateFocusRegion)
        
        buttonStack.addArrangedSubview(addRegionButton)
        buttonStack.addArrangedSubview(editRegionButton)
        buttonStack.addArrangedSubview(deleteRegionButton)
        buttonStack.addArrangedSubview(designateFocusRegionButton)
        buttonStack.addArrangedSubview(toggleOverlayButton)
        
        containerView.addSubview(buttonStack)
        
        NSLayoutConstraint.activate([
            regionProfileLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 23),
            regionProfileLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            
            regionProfileSelector.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 18),
            regionProfileSelector.leadingAnchor.constraint(equalTo: regionProfileLabel.trailingAnchor, constant: 8),
            regionProfileSelector.widthAnchor.constraint(greaterThanOrEqualToConstant: 250),
            
            scrollView.topAnchor.constraint(equalTo: regionProfileSelector.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -20),
            
            buttonStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            buttonStack.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -20)
        ])
        
        tabItem.view = containerView
        tabView.addTabViewItem(tabItem)
    }
    
    @objc private func addRegion() {
        guard let config = config, let profileID = selectedProfileID else { return }
        guard let profileIndex = config.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        
        let profile = config.profiles[profileIndex]
        let editor = RegionEditorDialog(
            region: nil,
            displayTopology: profile.displayTopology,
            parentWindow: window
        ) { [weak self] newRegion in
            guard let self = self else { return }
            
            // Add region to the selected profile
            self.config?.profiles[profileIndex].regions.append(newRegion)
            self.regionsTableView.reloadData()
            
            // Clear the reference when done
            self.regionEditorDialog = nil
        }
        
        // Retain the editor so it doesn't get deallocated
        self.regionEditorDialog = editor
        editor.show()
    }
    
    @objc private func editRegion() {
        guard let config = config, let profileID = selectedProfileID else { return }
        guard let profileIndex = config.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        
        let selectedRow = regionsTableView.selectedRow
        guard selectedRow >= 0 && selectedRow < config.profiles[profileIndex].regions.count else {
            showAlert(message: "Please select a region to edit")
            return
        }
        
        let region = config.profiles[profileIndex].regions[selectedRow]
        let profile = config.profiles[profileIndex]
        
        let editor = RegionEditorDialog(
            region: region,
            displayTopology: profile.displayTopology,
            parentWindow: window
        ) { [weak self] updatedRegion in
            guard let self = self else { return }
            
            // Update region in the selected profile
            self.config?.profiles[profileIndex].regions[selectedRow] = updatedRegion
            self.regionsTableView.reloadData()
            
            // Update overlay if showing
            if self.overlayManager.isShowing() {
                self.overlayManager.showOverlays(for: self.config!.profiles[profileIndex].regions)
            }
            
            // Clear the reference when done
            self.regionEditorDialog = nil
        }
        
        // Retain the editor so it doesn't get deallocated
        self.regionEditorDialog = editor
        editor.show()
    }
    
    @objc private func deleteRegion() {
        guard let config = config, let profileID = selectedProfileID else { return }
        guard let profileIndex = config.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        
        let selectedRow = regionsTableView.selectedRow
        guard selectedRow >= 0 && selectedRow < config.profiles[profileIndex].regions.count else {
            showAlert(message: "Please select a region to delete")
            return
        }
        
        let region = config.profiles[profileIndex].regions[selectedRow]
        
        let alert = NSAlert()
        alert.messageText = "Delete Region"
        alert.informativeText = "Are you sure you want to delete the region '\(region.name)'?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            self.config?.profiles[profileIndex].regions.remove(at: selectedRow)
            self.regionsTableView.reloadData()
            
            // Update overlay if showing
            if overlayManager.isShowing() {
                overlayManager.showOverlays(for: self.config!.profiles[profileIndex].regions)
            }
        }
    }
    
    @objc private func designateFocusRegion() {
        guard let config = config, let profileID = selectedProfileID else { return }
        guard let profileIndex = config.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        
        let selectedRow = regionsTableView.selectedRow
        guard selectedRow >= 0 && selectedRow < config.profiles[profileIndex].regions.count else {
            showAlert(message: "Please select a region to designate as focus region")
            return
        }
        
        // Clear any existing focus region in this profile
        for i in 0..<config.profiles[profileIndex].regions.count {
            self.config?.profiles[profileIndex].regions[i].isFocusRegion = false
        }
        
        // Set the selected region as focus region
        self.config?.profiles[profileIndex].regions[selectedRow].isFocusRegion = true
        
        let regionName = config.profiles[profileIndex].regions[selectedRow].name
        
        // Reload table to show updated state
        regionsTableView.reloadData()
        
        showAlert(message: "Region '\(regionName)' is now the focus region for this profile")
    }
    
    @objc private func toggleOverlay() {
        guard let config = config, let profileID = selectedProfileID else { return }
        
        if overlayManager.isShowing() {
            overlayManager.hideOverlays(saveChanges: true)
            toggleOverlayButton.title = "Show Overlay"
        } else {
            if let profile = config.profiles.first(where: { $0.id == profileID }) {
                overlayManager.showOverlays(for: profile.regions)
                toggleOverlayButton.title = "Hide Overlay"
            }
        }
    }
    
    private func updateRegionsFromOverlay(_ updatedRegions: [Region]) {
        guard var config = config, let profileID = selectedProfileID else { return }
        guard let profileIndex = config.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        
        // Update the regions in the profile
        for updatedRegion in updatedRegions {
            if let regionIndex = config.profiles[profileIndex].regions.firstIndex(where: { $0.id == updatedRegion.id }) {
                config.profiles[profileIndex].regions[regionIndex].frame = updatedRegion.frame
            }
        }
        
        self.config = config
        regionsTableView.reloadData()
    }
    
    @objc private func profileSelectorChanged() {
        guard let config = config else { return }
        
        let selectedIndex = regionProfileSelector.indexOfSelectedItem
        guard selectedIndex >= 0 && selectedIndex < config.profiles.count else { return }
        
        let profile = config.profiles[selectedIndex]
        selectedProfileID = profile.id
        regionsTableView.reloadData()
        
        // Sync the Profiles tab selection
        profilesTableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        
        // Update overlay if showing
        if overlayManager.isShowing() {
            overlayManager.showOverlays(for: profile.regions)
        }
    }
    
    // MARK: - Global Settings Tab
    
    private func setupGlobalSettingsTab() {
        let tabItem = NSTabViewItem(identifier: "settings")
        tabItem.label = "Global Settings"
        
        let containerView = NSView()
        
        let stackView = NSStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 20
        
        // Auto-switch profiles
        autoSwitchCheckbox.setButtonType(.switch)
        autoSwitchCheckbox.title = "Automatically switch profiles when display configuration changes"
        autoSwitchCheckbox.state = config?.globalSettings.enableAutoProfileSwitch ?? true ? .on : .off
        autoSwitchCheckbox.target = self
        autoSwitchCheckbox.action = #selector(settingsChanged)
        stackView.addArrangedSubview(autoSwitchCheckbox)
        
        // Auto-reposition windows
        autoRepositionCheckbox.setButtonType(.switch)
        autoRepositionCheckbox.title = "Automatically reposition windows when apps launch"
        autoRepositionCheckbox.state = config?.globalSettings.repositionOnAppLaunch ?? true ? .on : .off
        autoRepositionCheckbox.target = self
        autoRepositionCheckbox.action = #selector(settingsChanged)
        stackView.addArrangedSubview(autoRepositionCheckbox)
        
        // Require confirm for launch
        requireConfirmCheckbox.setButtonType(.switch)
        requireConfirmCheckbox.title = "Require confirmation before launching unstarted apps"
        requireConfirmCheckbox.state = config?.globalSettings.requireConfirmToLaunchApps ?? false ? .on : .off
        requireConfirmCheckbox.target = self
        requireConfirmCheckbox.action = #selector(settingsChanged)
        stackView.addArrangedSubview(requireConfirmCheckbox)
        
        // Reset window keyboard shortcut
        let shortcutLabel = NSTextField(labelWithString: "Reset Window to Region Shortcut:")
        shortcutLabel.font = .systemFont(ofSize: 13, weight: .medium)
        stackView.addArrangedSubview(shortcutLabel)
        
        let recorder = KeyboardShortcutRecorder()
        recorder.translatesAutoresizingMaskIntoConstraints = false
        
        // Set initial shortcut from config
        if let shortcut = config?.globalSettings.resetWindowShortcut {
            recorder.setShortcut(modifiers: shortcut.modifiers, key: shortcut.key)
        }
        
        recorder.onShortcutChanged = { [weak self] shortcutTuple in
            self?.resetWindowShortcutChanged(shortcutTuple)
        }
        self.resetWindowShortcutRecorder = recorder
        stackView.addArrangedSubview(recorder)
        
        NSLayoutConstraint.activate([
            recorder.widthAnchor.constraint(equalToConstant: 300),
            recorder.heightAnchor.constraint(equalToConstant: 30)
        ])
        
        // Focus window keyboard shortcut
        let focusShortcutLabel = NSTextField(labelWithString: "Focus Window to Region Shortcut:")
        focusShortcutLabel.font = .systemFont(ofSize: 13, weight: .medium)
        stackView.addArrangedSubview(focusShortcutLabel)
        
        let focusRecorder = KeyboardShortcutRecorder()
        focusRecorder.translatesAutoresizingMaskIntoConstraints = false
        
        // Set initial shortcut from config
        if let shortcut = config?.globalSettings.focusWindowShortcut {
            focusRecorder.setShortcut(modifiers: shortcut.modifiers, key: shortcut.key)
        }
        
        focusRecorder.onShortcutChanged = { [weak self] shortcutTuple in
            self?.focusWindowShortcutChanged(shortcutTuple)
        }
        self.focusWindowShortcutRecorder = focusRecorder
        stackView.addArrangedSubview(focusRecorder)
        
        NSLayoutConstraint.activate([
            focusRecorder.widthAnchor.constraint(equalToConstant: 300),
            focusRecorder.heightAnchor.constraint(equalToConstant: 30)
        ])
        
        containerView.addSubview(stackView)
        
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 40),
            stackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: containerView.trailingAnchor, constant: -40)
        ])
        
        tabItem.view = containerView
        tabView.addTabViewItem(tabItem)
    }
    
    @objc private func settingsChanged() {
        // Settings are already updated via checkbox bindings and saved when Save is clicked
    }
    
    private func resetWindowShortcutChanged(_ shortcutTuple: (modifiers: [String], key: String)?) {
        // Convert tuple to KeyboardShortcut
        if let tuple = shortcutTuple {
            config?.globalSettings.resetWindowShortcut = KeyboardShortcut(modifiers: tuple.modifiers, key: tuple.key)
        } else {
            config?.globalSettings.resetWindowShortcut = nil
        }
    }
    
    private func focusWindowShortcutChanged(_ shortcutTuple: (modifiers: [String], key: String)?) {
        // Convert tuple to KeyboardShortcut
        if let tuple = shortcutTuple {
            config?.globalSettings.focusWindowShortcut = KeyboardShortcut(modifiers: tuple.modifiers, key: tuple.key)
        } else {
            config?.globalSettings.focusWindowShortcut = nil
        }
    }
    
    // MARK: - Public Methods
    
    func show() {
        Task {
            await loadConfiguration()
            populateProfileSelector()
            profilesTableView.reloadData()
            regionsTableView.reloadData()
            
            // Update global settings UI with loaded config
            if let config = config {
                autoSwitchCheckbox.state = config.globalSettings.enableAutoProfileSwitch ? .on : .off
                autoRepositionCheckbox.state = config.globalSettings.repositionOnAppLaunch ? .on : .off
                requireConfirmCheckbox.state = config.globalSettings.requireConfirmToLaunchApps ? .on : .off
                
                // Update shortcut recorders with loaded config
                if let shortcut = config.globalSettings.resetWindowShortcut {
                    resetWindowShortcutRecorder?.setShortcut(modifiers: shortcut.modifiers, key: shortcut.key)
                }
                if let shortcut = config.globalSettings.focusWindowShortcut {
                    focusWindowShortcutRecorder?.setShortcut(modifiers: shortcut.modifiers, key: shortcut.key)
                }
            }
            
            // Select the active profile (or first profile if none active)
            if let config = config {
                let activeIndex = config.profiles.firstIndex { $0.isActive } ?? 0
                
                if activeIndex < config.profiles.count {
                    profilesTableView.selectRowIndexes(IndexSet(integer: activeIndex), byExtendingSelection: false)
                    selectedProfileID = config.profiles[activeIndex].id
                    regionsTableView.reloadData()
                    
                    // Update profile selector
                    regionProfileSelector.selectItem(at: activeIndex)
                }
            }
            
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    private func populateProfileSelector() {
        regionProfileSelector.removeAllItems()
        
        guard let config = config else { return }
        
        for profile in config.profiles {
            regionProfileSelector.addItem(withTitle: profile.name)
        }
    }
    
    override func close() {
        overlayManager.hideOverlays(saveChanges: false)
        super.close()
        
        // Activation policy is managed at app level via window close notification
    }
    
    @objc private func saveConfiguration() {
        guard var config = config else { return }
        
        // Update global settings from UI
        config.globalSettings.enableAutoProfileSwitch = autoSwitchCheckbox.state == .on
        config.globalSettings.repositionOnAppLaunch = autoRepositionCheckbox.state == .on
        config.globalSettings.requireConfirmToLaunchApps = requireConfirmCheckbox.state == .on
        
        // Get current shortcut from recorder
        if let shortcutTuple = resetWindowShortcutRecorder?.currentShortcut {
            config.globalSettings.resetWindowShortcut = KeyboardShortcut(modifiers: shortcutTuple.modifiers, key: shortcutTuple.key)
        } else {
            config.globalSettings.resetWindowShortcut = nil
        }
        
        if let shortcutTuple = focusWindowShortcutRecorder?.currentShortcut {
            config.globalSettings.focusWindowShortcut = KeyboardShortcut(modifiers: shortcutTuple.modifiers, key: shortcutTuple.key)
        } else {
            config.globalSettings.focusWindowShortcut = nil
        }
        
        Task {
            do {
                // Update the profile manager's configuration
                await profileManager.updateConfiguration(config)
                
                // Save to disk
                try await profileManager.save()
                
                // Reload configuration
                try await profileManager.reload()
                
                // Update keyboard shortcuts to reflect changes
                await self.eventCoordinator?.updateKeyboardShortcuts()
                
                await MainActor.run {
                    // Close the settings window
                    self.close()
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Save Failed"
                    alert.informativeText = "Failed to save configuration: \(error.localizedDescription)"
                    alert.alertStyle = .critical
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }
}

// MARK: - Table View Delegate & Data Source

extension ConfigurationWindow: NSTableViewDelegate, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == profilesTableView {
            return config?.profiles.count ?? 0
        } else if tableView == regionsTableView {
            guard let config = config, let profileID = selectedProfileID else { return 0 }
            return config.profiles.first(where: { $0.id == profileID })?.regions.count ?? 0
        }
        return 0
    }
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("")
        
        if tableView == profilesTableView {
            guard let profile = config?.profiles[safe: row] else { return nil }
            
            let textField = NSTextField()
            textField.isBordered = false
            textField.backgroundColor = .clear
            
            if identifier.rawValue == "name" {
                textField.stringValue = profile.name
                textField.isEditable = true
                textField.target = self
                textField.action = #selector(profileNameChanged(_:))
                textField.tag = row
            } else if identifier.rawValue == "displays" {
                textField.stringValue = DisplayCapture.describeTopology(profile.displayTopology)
                textField.isEditable = false
            }
            
            return textField
        } else if tableView == regionsTableView {
            guard let config = config,
                  let profileID = selectedProfileID,
                  let profile = config.profiles.first(where: { $0.id == profileID }),
                  let region = profile.regions[safe: row] else { return nil }
            
            let textField = NSTextField()
            textField.isEditable = false
            textField.isBordered = false
            textField.backgroundColor = .clear
            
            if identifier.rawValue == "regionName" {
                var name = region.name
                if region.isFocusRegion {
                    name += " 🎯"
                }
                textField.stringValue = name
            } else if identifier.rawValue == "frame" {
                textField.stringValue = "[\(Int(region.frame.origin.x)), \(Int(region.frame.origin.y))] [\(Int(region.frame.width)), \(Int(region.frame.height))]"
            } else if identifier.rawValue == "shortcut" {
                if let shortcut = region.keyboardShortcut {
                    let symbols = shortcut.modifiers.map { modifierToSymbol($0) }.joined()
                    textField.stringValue = "\(symbols)\(shortcut.key.uppercased())"
                } else {
                    textField.stringValue = "—"
                }
            }
            
            return textField
        }
        
        return nil
    }
    
    func tableViewSelectionDidChange(_ notification: Notification) {
        if let tableView = notification.object as? NSTableView {
            if tableView == profilesTableView {
                let selectedRow = tableView.selectedRow
                if selectedRow >= 0, let profile = config?.profiles[safe: selectedRow] {
                    selectedProfileID = profile.id
                    regionsTableView.reloadData()
                    
                    // Sync the profile selector
                    regionProfileSelector.selectItem(at: selectedRow)
                    
                    // Update overlay if showing
                    if overlayManager.isShowing() {
                        overlayManager.showOverlays(for: profile.regions)
                    }
                } else {
                    if overlayManager.isShowing() {
                        overlayManager.hideOverlays(saveChanges: false)
                        toggleOverlayButton.title = "Show Overlay"
                    }
                }
            }
        }
    }
    
    private func modifierToSymbol(_ modifier: String) -> String {
        switch modifier {
        case "control": return "⌃"
        case "option": return "⌥"
        case "shift": return "⇧"
        case "cmd": return "⌘"
        default: return ""
        }
    }
    
    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Action Required"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Array Safe Index Extension

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
