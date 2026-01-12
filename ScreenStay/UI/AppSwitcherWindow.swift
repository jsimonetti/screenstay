import AppKit

/// Floating window that displays app switcher UI when cycling through region apps
@MainActor
class AppSwitcherWindow: NSWindow {
    private let stackView = NSStackView()
    private var appLabels: [String: NSTextField] = [:]
    
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        setupWindow()
        setupUI()
    }
    
    private func setupWindow() {
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.85)
        level = .floating
        isMovableByWindowBackground = false
        hasShadow = true
        
        // Rounded corners
        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = 12
    }
    
    private func setupUI() {
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 8
        stackView.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        
        contentView?.addSubview(stackView)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: contentView!.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: contentView!.bottomAnchor)
        ])
    }
    
    /// Update the window with a list of apps
    func updateApps(_ apps: [(bundleID: String, name: String, isRunning: Bool)], selectedIndex: Int) {
        // Clear existing labels
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        appLabels.removeAll()
        
        for (index, app) in apps.enumerated() {
            // Create horizontal stack for icon + label
            let rowStack = NSStackView()
            rowStack.orientation = .horizontal
            rowStack.spacing = 8
            rowStack.alignment = .centerY
            
            // Get app icon
            let iconView = NSImageView()
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                iconView.widthAnchor.constraint(equalToConstant: 24),
                iconView.heightAnchor.constraint(equalToConstant: 24)
            ])
            
            if let icon = getAppIcon(bundleID: app.bundleID) {
                iconView.image = icon
            } else {
                // Default icon for apps that can't be found
                iconView.image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
            }
            
            // Create label
            let label = NSTextField(labelWithString: app.name)
            label.font = .systemFont(ofSize: 14, weight: index == selectedIndex ? .semibold : .regular)
            label.textColor = app.isRunning ? .labelColor : .secondaryLabelColor
            label.isBordered = false
            label.isBezeled = false
            label.drawsBackground = false
            
            rowStack.addArrangedSubview(iconView)
            rowStack.addArrangedSubview(label)
            
            if index == selectedIndex {
                // Selected item with blue background
                label.textColor = .white
                
                let container = NSView()
                container.wantsLayer = true
                container.layer?.cornerRadius = 6
                container.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.6).cgColor
                container.addSubview(rowStack)
                
                rowStack.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    rowStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
                    rowStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
                    rowStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
                    rowStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6)
                ])
                
                stackView.addArrangedSubview(container)
            } else {
                // Unselected item
                if !app.isRunning {
                    // Dim the icon for unstarted apps
                    iconView.alphaValue = 0.5
                }
                stackView.addArrangedSubview(rowStack)
            }
            
            appLabels[app.bundleID] = label
        }
        
        // Resize window to fit content
        stackView.layoutSubtreeIfNeeded()
        let contentSize = stackView.fittingSize
        setContentSize(NSSize(width: max(300, contentSize.width), height: contentSize.height))
    }
    
    /// Get the icon for an app by bundle ID
    private func getAppIcon(bundleID: String) -> NSImage? {
        // Try to get from running app
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let icon = app.icon {
            return icon
        }
        
        // Try to get from workspace
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        
        return nil
    }
    
    /// Show the window centered in the given region
    func show(centeredIn regionFrame: CGRect) {
        let windowSize = frame.size
        let centerX = regionFrame.midX - (windowSize.width / 2)
        let centerY = regionFrame.midY - (windowSize.height / 2)
        
        setFrameOrigin(NSPoint(x: centerX, y: centerY))
        orderFrontRegardless()
    }
    
    /// Hide the window
    func hide() {
        orderOut(nil)
    }
}
