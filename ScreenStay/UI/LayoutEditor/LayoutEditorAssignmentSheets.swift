import AppKit

/// Modal editors for the two things a region carries besides its rectangle.
///
/// Both are plain modal windows rather than sheets: the editor's overlays are
/// borderless and cover the display, so there is nothing sensible to attach a
/// sheet to. `LayoutEditorController.runModal` drops the overlays out of the
/// way while one of these is up.
@MainActor
enum LayoutEditorAssignmentSheets {

    // MARK: - Apps

    /// Edit the bundle identifiers assigned to a region.
    /// Returns nil if cancelled.
    static func editApps(for region: Region) -> [String]? {
        let controller = AppsSheetController(bundleIDs: region.assignedApps, regionName: region.name)
        return controller.run()
    }

    // MARK: - Shortcut

    /// Whether a shortcut is already claimed, and by what.
    ///
    /// Modifiers compare as a set, since the recorder and stored configurations
    /// do not agree on ordering, and the key compares case-insensitively for the
    /// same reason: the same configuration holds both "z" and "Z".
    static func conflictOwner(
        for shortcut: KeyboardShortcut,
        among taken: [(shortcut: KeyboardShortcut, owner: String)]
    ) -> String? {
        taken.first {
            $0.shortcut.key.lowercased() == shortcut.key.lowercased()
                && Set($0.shortcut.modifiers) == Set(shortcut.modifiers)
        }?.owner
    }

    /// Edit a region's keyboard shortcut.
    ///
    /// `taken` maps an already-used shortcut to the thing using it, so a clash
    /// can be pointed out rather than silently shadowing another region.
    /// Returns nil if cancelled, or `.some(nil)` to clear the shortcut.
    static func editShortcut(
        for region: Region,
        taken: [(shortcut: KeyboardShortcut, owner: String)]
    ) -> KeyboardShortcut?? {
        let controller = ShortcutSheetController(
            shortcut: region.keyboardShortcut, regionName: region.name, taken: taken)
        return controller.run()
    }
}

// MARK: - Apps sheet

@MainActor
private final class AppsSheetController: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private let window: NSWindow
    private let table = NSTableView()
    private let removeButton = NSButton()
    private var bundleIDs: [String]
    private var confirmed = false

    init(bundleIDs: [String], regionName: String) {
        self.bundleIDs = bundleIDs

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Apps in \u{201C}\(regionName)\u{201D}"
        window.isReleasedWhenClosed = false

        super.init()
        buildUI()
        reload()
    }

    func run() -> [String]? {
        window.center()
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return confirmed ? bundleIDs.filter { !$0.isEmpty } : nil
    }

    private func buildUI() {
        guard let content = window.contentView else { return }

        let caption = NSTextField(wrappingLabelWithString:
            "Windows belonging to these apps are placed in this region.")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(caption)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        table.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self
        table.delegate = self
        table.headerView = nil
        table.rowHeight = 24
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        column.width = 400
        table.addTableColumn(column)
        scroll.documentView = table
        content.addSubview(scroll)

        let addButton = NSButton(title: "Add\u{2026}", target: self, action: #selector(addApp))
        addButton.bezelStyle = .rounded
        addButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(addButton)

        removeButton.title = "Remove"
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeApp)
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(removeButton)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(cancel)

        let done = NSButton(title: "Done", target: self, action: #selector(confirm))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(done)

        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            caption.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            caption.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -12),

            addButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            addButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 8),
            removeButton.bottomAnchor.constraint(equalTo: addButton.bottomAnchor),

            done.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            done.bottomAnchor.constraint(equalTo: addButton.bottomAnchor),
            cancel.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -8),
            cancel.bottomAnchor.constraint(equalTo: addButton.bottomAnchor),
        ])
    }

    private func reload() {
        table.reloadData()
        removeButton.isEnabled = table.selectedRow >= 0
    }

    // MARK: Actions

    @objc private func addApp() {
        let menu = NSMenu()

        // Running apps first, since that is nearly always what is wanted.
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

        for app in running {
            guard let bundleID = app.bundleIdentifier, !bundleIDs.contains(bundleID) else { continue }
            let item = NSMenuItem(title: app.localizedName ?? bundleID,
                                  action: #selector(pickRunning(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = bundleID
            item.image = app.icon
            item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
        }

        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }

        // An app that is not running has no bundle identifier to read, so offer
        // to pick it from disk rather than making the identifier be typed.
        let browse = NSMenuItem(title: "Choose Application\u{2026}",
                                action: #selector(chooseApplication), keyEquivalent: "")
        browse.target = self
        menu.addItem(browse)

        let manual = NSMenuItem(title: "Enter Bundle Identifier\u{2026}",
                                action: #selector(enterBundleID), keyEquivalent: "")
        manual.target = self
        menu.addItem(manual)

        let button = window.contentView?.subviews.first { ($0 as? NSButton)?.title == "Add\u{2026}" }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button?.bounds.height ?? 0), in: button)
    }

    @objc private func pickRunning(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        append(bundleID)
    }

    @objc private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            append(id)
        }
    }

    @objc private func enterBundleID() {
        let alert = NSAlert()
        alert.messageText = "Bundle identifier"
        alert.informativeText = "For example com.apple.Safari."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "com.example.app"
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        append(field.stringValue.trimmingCharacters(in: .whitespaces))
    }

    private func append(_ bundleID: String) {
        guard !bundleID.isEmpty, !bundleIDs.contains(bundleID) else { return }
        bundleIDs.append(bundleID)
        reload()
    }

    @objc private func removeApp() {
        let row = table.selectedRow
        guard row >= 0, row < bundleIDs.count else { return }
        bundleIDs.remove(at: row)
        reload()
    }

    @objc private func confirm() {
        confirmed = true
        NSApp.stopModal()
    }

    @objc private func cancel() {
        confirmed = false
        NSApp.stopModal()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { bundleIDs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let bundleID = bundleIDs[row]
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            icon.image = NSWorkspace.shared.icon(forFile: url.path)
        }
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
        ])
        stack.addArrangedSubview(icon)

        let name = displayName(for: bundleID)
        let label = NSTextField(labelWithString: name == bundleID ? bundleID : "\(name)  \u{2014}  \(bundleID)")
        label.font = .systemFont(ofSize: 12)
        // An app that cannot be resolved is still valid, it just is not installed.
        label.textColor = icon.image == nil ? .secondaryLabelColor : .labelColor
        stack.addArrangedSubview(label)

        return stack
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = table.selectedRow >= 0
    }

    private func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}

// MARK: - Shortcut sheet

@MainActor
private final class ShortcutSheetController: NSObject {

    private let window: NSWindow
    private let recorder = KeyboardShortcutRecorder()
    private let conflictLabel = NSTextField(labelWithString: "")
    private let taken: [(shortcut: KeyboardShortcut, owner: String)]
    private var result: KeyboardShortcut?
    private var confirmed = false

    init(shortcut: KeyboardShortcut?, regionName: String,
         taken: [(shortcut: KeyboardShortcut, owner: String)]) {
        self.taken = taken
        self.result = shortcut

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 190),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Shortcut for \u{201C}\(regionName)\u{201D}"
        window.isReleasedWhenClosed = false

        super.init()
        buildUI()
        if let shortcut {
            recorder.setShortcut(modifiers: shortcut.modifiers, key: shortcut.key)
        }
        updateConflict()
    }

    /// nil means cancelled; .some(nil) means the shortcut was cleared.
    func run() -> KeyboardShortcut?? {
        window.center()
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return confirmed ? .some(result) : nil
    }

    private func buildUI() {
        guard let content = window.contentView else { return }

        let caption = NSTextField(wrappingLabelWithString:
            "Press the keys you want. This shortcut cycles focus through the apps in this region.")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(caption)

        recorder.translatesAutoresizingMaskIntoConstraints = false
        recorder.onShortcutChanged = { [weak self] shortcut in
            guard let self else { return }
            self.result = shortcut.map { KeyboardShortcut(modifiers: $0.modifiers, key: $0.key) }
            self.updateConflict()
        }
        content.addSubview(recorder)

        conflictLabel.font = .systemFont(ofSize: 11)
        conflictLabel.textColor = .systemOrange
        conflictLabel.lineBreakMode = .byWordWrapping
        conflictLabel.maximumNumberOfLines = 2
        conflictLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(conflictLabel)

        let clear = NSButton(title: "Clear", target: self, action: #selector(clearShortcut))
        clear.bezelStyle = .rounded
        clear.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(clear)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(cancel)

        let done = NSButton(title: "Done", target: self, action: #selector(confirm))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(done)

        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            caption.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            caption.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            recorder.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 14),
            recorder.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            recorder.widthAnchor.constraint(equalToConstant: 220),
            recorder.heightAnchor.constraint(equalToConstant: 30),

            conflictLabel.topAnchor.constraint(equalTo: recorder.bottomAnchor, constant: 10),
            conflictLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            conflictLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            clear.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            clear.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            done.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            done.bottomAnchor.constraint(equalTo: clear.bottomAnchor),
            cancel.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -8),
            cancel.bottomAnchor.constraint(equalTo: clear.bottomAnchor),
        ])
    }

    /// Warn rather than refuse. A duplicate shortcut is resolved by whichever
    /// region comes first, which is silent and confusing, but it is the user's
    /// layout and they may be mid-way through swapping two of them.
    private func updateConflict() {
        guard let result else {
            conflictLabel.stringValue = ""
            return
        }
        let owner = LayoutEditorAssignmentSheets.conflictOwner(for: result, among: taken)
        conflictLabel.stringValue = owner.map {
            "Already used by \($0). Whichever comes first in the profile will win."
        } ?? ""
    }

    @objc private func clearShortcut() {
        result = nil
        recorder.setShortcut(modifiers: [], key: "")
        updateConflict()
    }

    @objc private func confirm() {
        confirmed = true
        NSApp.stopModal()
    }

    @objc private func cancel() {
        confirmed = false
        NSApp.stopModal()
    }
}
