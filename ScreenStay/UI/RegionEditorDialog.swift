import AppKit

/// Dialog for adding or editing a region
@MainActor
class RegionEditorDialog: NSWindowController, NSTableViewDelegate, NSTableViewDataSource {
    private var region: Region?
    private var isNewRegion: Bool
    private var onSave: ((Region) -> Void)?
    private let displayTopology: DisplayTopology
    private var parentWindow: NSWindow?
    
    // UI Components
    private let nameField = NSTextField()
    private let displayIDPopup = NSPopUpButton()
    private let xField = NSTextField()
    private let yField = NSTextField()
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let paddingField = NSTextField()
    private let shortcutRecorder = KeyboardShortcutRecorder()
    private let appsTableView = NSTableView()
    private var appBundleIDs: [String] = []
    private let addAppButton = NSButton()
    private let removeAppButton = NSButton()
    
    init(region: Region? = nil, displayTopology: DisplayTopology, parentWindow: NSWindow?, onSave: @escaping (Region) -> Void) {
        self.region = region
        self.isNewRegion = region == nil
        self.onSave = onSave
        self.displayTopology = displayTopology
        self.parentWindow = parentWindow
        
        // Initialize app list
        if let region = region {
            self.appBundleIDs = region.assignedApps
        }
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 550, height: 650),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = region == nil ? "Add Region" : "Edit Region"
        window.center()
        window.isReleasedWhenClosed = false
        
        super.init(window: window)
        
        setupUI()
        
        // Populate fields if editing
        if let region = region {
            populateFields(with: region)
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    
    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        
        let stackView = NSStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.spacing = 16
        stackView.alignment = .leading
        contentView.addSubview(stackView)
        
        // Name
        addLabeledField(to: stackView, label: "Name:", field: nameField, placeholder: "e.g. Left Monitor")
        
        // Display ID popup
        let displayLabel = NSTextField(labelWithString: "Display:")
        displayLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        stackView.addArrangedSubview(displayLabel)
        
        displayIDPopup.translatesAutoresizingMaskIntoConstraints = false
        for display in displayTopology.displays {
            let title = display.isBuiltIn ? 
                "Display \(display.displayID) (Built-in) - \(Int(display.resolution.width))x\(Int(display.resolution.height))" :
                "Display \(display.displayID) (External) - \(Int(display.resolution.width))x\(Int(display.resolution.height))"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = display.displayID
            displayIDPopup.menu?.addItem(item)
        }
        stackView.addArrangedSubview(displayIDPopup)
        
        NSLayoutConstraint.activate([
            displayIDPopup.widthAnchor.constraint(equalToConstant: 450)
        ])
        
        // Frame section with draw button
        let frameHeaderStack = NSStackView()
        frameHeaderStack.orientation = .horizontal
        frameHeaderStack.spacing = 12
        
        let frameLabel = NSTextField(labelWithString: "Frame (x, y, width, height):")
        frameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        frameHeaderStack.addArrangedSubview(frameLabel)
        
        let drawButton = NSButton(title: "📐 Draw Region", target: self, action: #selector(drawRegion))
        drawButton.bezelStyle = .rounded
        drawButton.setButtonType(.momentaryPushIn)
        drawButton.translatesAutoresizingMaskIntoConstraints = false
        frameHeaderStack.addArrangedSubview(drawButton)
        
        stackView.addArrangedSubview(frameHeaderStack)
        
        let frameStack = NSStackView()
        frameStack.orientation = .horizontal
        frameStack.spacing = 8
        
        xField.placeholderString = "X"
        xField.translatesAutoresizingMaskIntoConstraints = false
        yField.placeholderString = "Y"
        yField.translatesAutoresizingMaskIntoConstraints = false
        widthField.placeholderString = "Width"
        widthField.translatesAutoresizingMaskIntoConstraints = false
        heightField.placeholderString = "Height"
        heightField.translatesAutoresizingMaskIntoConstraints = false
        
        frameStack.addArrangedSubview(xField)
        frameStack.addArrangedSubview(yField)
        frameStack.addArrangedSubview(widthField)
        frameStack.addArrangedSubview(heightField)
        stackView.addArrangedSubview(frameStack)
        
        NSLayoutConstraint.activate([
            xField.widthAnchor.constraint(equalToConstant: 80),
            yField.widthAnchor.constraint(equalToConstant: 80),
            widthField.widthAnchor.constraint(equalToConstant: 90),
            heightField.widthAnchor.constraint(equalToConstant: 90)
        ])
        
        // Padding
        addLabeledField(to: stackView, label: "Padding (pixels):", field: paddingField, placeholder: "0")
        
        NSLayoutConstraint.activate([
            paddingField.widthAnchor.constraint(equalToConstant: 100)
        ])
        
        // Keyboard shortcut
        let shortcutLabel = NSTextField(labelWithString: "Keyboard Shortcut:")
        shortcutLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        stackView.addArrangedSubview(shortcutLabel)
        
        shortcutRecorder.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(shortcutRecorder)
        
        NSLayoutConstraint.activate([
            shortcutRecorder.widthAnchor.constraint(equalToConstant: 200),
            shortcutRecorder.heightAnchor.constraint(equalToConstant: 30)
        ])
        
        // Apps section
        let appsHeaderStack = NSStackView()
        appsHeaderStack.orientation = .horizontal
        appsHeaderStack.spacing = 12
        
        let appsLabel = NSTextField(labelWithString: "Assigned Apps:")
        appsLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        appsHeaderStack.addArrangedSubview(appsLabel)
        
        addAppButton.title = "+"
        addAppButton.bezelStyle = .rounded
        addAppButton.setButtonType(.momentaryPushIn)
        addAppButton.translatesAutoresizingMaskIntoConstraints = false
        addAppButton.target = self
        addAppButton.action = #selector(addApp)
        appsHeaderStack.addArrangedSubview(addAppButton)
        
        removeAppButton.title = "-"
        removeAppButton.bezelStyle = .rounded
        removeAppButton.setButtonType(.momentaryPushIn)
        removeAppButton.translatesAutoresizingMaskIntoConstraints = false
        removeAppButton.target = self
        removeAppButton.action = #selector(removeApp)
        appsHeaderStack.addArrangedSubview(removeAppButton)
        
        stackView.addArrangedSubview(appsHeaderStack)
        
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        
        appsTableView.translatesAutoresizingMaskIntoConstraints = false
        appsTableView.delegate = self
        appsTableView.dataSource = self
        
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bundleID"))
        column.title = "Bundle ID"
        column.width = 410
        appsTableView.addTableColumn(column)
        
        scrollView.documentView = appsTableView
        stackView.addArrangedSubview(scrollView)
        
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalToConstant: 450),
            scrollView.heightAnchor.constraint(equalToConstant: 150)
        ])
        
        // Buttons
        let buttonStack = NSStackView()
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 12
        
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.setButtonType(.momentaryPushIn)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.keyEquivalent = "\u{1b}" // Escape key
        
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.setButtonType(.momentaryPushIn)
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.keyEquivalent = "\r"
        
        buttonStack.addArrangedSubview(cancelButton)
        buttonStack.addArrangedSubview(saveButton)
        stackView.addArrangedSubview(buttonStack)
        
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])
    }
    
    private func addLabeledField(to stackView: NSStackView, label: String, field: NSTextField, placeholder: String) {
        let label = NSTextField(labelWithString: label)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        stackView.addArrangedSubview(label)
        
        field.placeholderString = placeholder
        field.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(field)
        
        NSLayoutConstraint.activate([
            field.widthAnchor.constraint(equalToConstant: 300)
        ])
    }
    
    private func populateFields(with region: Region) {
        nameField.stringValue = region.name
        
        // Select the display in popup
        if let index = displayTopology.displays.firstIndex(where: { $0.displayID == region.displayID }) {
            displayIDPopup.selectItem(at: index)
        }
        
        // Parse frame - handle both direct values and nested arrays
        let frame = region.frame
        let xVal = "\(Int(frame.origin.x))"
        let yVal = "\(Int(frame.origin.y))"
        let wVal = "\(Int(frame.width))"
        let hVal = "\(Int(frame.height))"
        
        xField.stringValue = xVal
        yField.stringValue = yVal
        widthField.stringValue = wVal
        heightField.stringValue = hVal
        paddingField.stringValue = "\(Int(region.padding))"
        
        if let shortcut = region.keyboardShortcut {
            shortcutRecorder.setShortcut(modifiers: shortcut.modifiers, key: shortcut.key)
        }
    }
    
    @objc private func drawRegion() {
        // Hide this dialog temporarily
        window?.orderOut(nil)
        
        // Show drawing overlay
        let overlay = RegionDrawingOverlay { [weak self] drawnRect in
            guard let self = self else { return }
            
            // Update fields with drawn rectangle
            self.xField.stringValue = "\(Int(drawnRect.origin.x))"
            self.yField.stringValue = "\(Int(drawnRect.origin.y))"
            self.widthField.stringValue = "\(Int(drawnRect.width))"
            self.heightField.stringValue = "\(Int(drawnRect.height))"
            
            // Show dialog again after a brief delay to ensure overlay is fully closed
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.window?.makeKeyAndOrderFront(nil)
            }
        }
        
        // Ensure overlay is shown and can receive events
        overlay.orderFrontRegardless()
        overlay.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func addApp() {
        // Show menu with running apps
        let menu = NSMenu()
        
        let runningApps = NSWorkspace.shared.runningApplications.filter { 
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil 
        }.sorted { 
            ($0.localizedName ?? "") < ($1.localizedName ?? "")
        }
        
        for app in runningApps {
            guard let bundleID = app.bundleIdentifier else { continue }
            let name = app.localizedName ?? bundleID
            let item = NSMenuItem(title: "\(name) (\(bundleID))", action: #selector(selectRunningApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = bundleID
            menu.addItem(item)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        let customItem = NSMenuItem(title: "Enter Custom Bundle ID...", action: #selector(enterCustomBundleID), keyEquivalent: "")
        customItem.target = self
        menu.addItem(customItem)
        
        // Show menu at button
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: addAppButton.bounds.height), in: addAppButton)
    }
    
    @objc private func selectRunningApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        if !appBundleIDs.contains(bundleID) {
            appBundleIDs.append(bundleID)
            appsTableView.reloadData()
        }
    }
    
    @objc private func enterCustomBundleID() {
        let alert = NSAlert()
        alert.messageText = "Enter Bundle ID"
        alert.informativeText = "Enter the app's bundle identifier (e.g. com.apple.Safari)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "com.example.app"
        alert.accessoryView = input
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let bundleID = input.stringValue.trimmingCharacters(in: .whitespaces)
            if !bundleID.isEmpty && !appBundleIDs.contains(bundleID) {
                appBundleIDs.append(bundleID)
                appsTableView.reloadData()
            }
        }
    }
    
    @objc private func removeApp() {
        let selectedRow = appsTableView.selectedRow
        guard selectedRow >= 0 && selectedRow < appBundleIDs.count else {
            return
        }
        
        appBundleIDs.remove(at: selectedRow)
        appsTableView.reloadData()
    }
    
    // MARK: - NSTableViewDataSource
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return appBundleIDs.count
    }
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let textField = NSTextField()
        textField.isEditable = true
        textField.isBordered = false
        textField.backgroundColor = .clear
        textField.stringValue = appBundleIDs[row]
        textField.tag = row
        textField.target = self
        textField.action = #selector(appBundleIDChanged(_:))
        return textField
    }
    
    @objc private func appBundleIDChanged(_ sender: NSTextField) {
        let row = sender.tag
        if row >= 0 && row < appBundleIDs.count {
            appBundleIDs[row] = sender.stringValue
        }
    }
    
    @objc private func save() {
        // Validate and create region
        guard !nameField.stringValue.isEmpty else {
            showAlert(message: "Please enter a region name")
            return
        }
        
        guard let selectedItem = displayIDPopup.selectedItem,
              let displayID = selectedItem.representedObject as? CGDirectDisplayID else {
            showAlert(message: "Please select a display")
            return
        }
        
        guard let x = Double(xField.stringValue),
              let y = Double(yField.stringValue),
              let width = Double(widthField.stringValue),
              let height = Double(heightField.stringValue) else {
            showAlert(message: "Please enter valid numbers for frame dimensions")
            return
        }
        
        let padding = Double(paddingField.stringValue) ?? 0
        
        let frame = CGRect(x: x, y: y, width: width, height: height)
        
        // Get keyboard shortcut
        let shortcut: KeyboardShortcut?
        if let currentShortcut = shortcutRecorder.currentShortcut {
            shortcut = KeyboardShortcut(
                modifiers: currentShortcut.modifiers,
                key: currentShortcut.key
            )
        } else {
            shortcut = nil
        }
        
        let newRegion = Region(
            id: region?.id ?? UUID().uuidString,
            name: nameField.stringValue,
            displayID: displayID,
            frame: frame,
            assignedApps: appBundleIDs.filter { !$0.isEmpty },
            keyboardShortcut: shortcut,
            padding: padding
        )
        
        onSave?(newRegion)
        closeSheet()
    }
    
    @objc private func cancel() {
        closeSheet()
    }
    
    private func closeSheet() {
        if let parentWindow = parentWindow, let window = window, parentWindow.sheets.contains(window) {
            parentWindow.endSheet(window)
        }
        close()
    }
    
    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Invalid Input"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    func show() {
        if let parentWindow = parentWindow, let window = window {
            parentWindow.beginSheet(window)
        } else {
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
        }
        
        // Ensure window can accept key events
        window?.makeFirstResponder(window?.contentView)
    }
}
