import AppKit

/// Borderless window that shows region boundaries and labels
class RegionOverlayWindow: NSWindow {
    let region: Region
    private let labelView = NSTextField()
    var onDismiss: (() -> Void)?
    
    private var initialMouseLocation: NSPoint?
    private var initialWindowFrame: NSRect?
    private var resizeEdge: ResizeEdge = .none
    
    enum ResizeEdge {
        case none, top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight
    }
    
    /// - Parameter cocoaFrame: the region's absolute frame in Cocoa space,
    ///   already resolved against its display by `RegionGeometry`.
    init(region: Region, cocoaFrame: CGRect) {
        self.region = region

        super.init(
            contentRect: cocoaFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.ignoresMouseEvents = false
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]
        self.isMovableByWindowBackground = true

        setupOverlay()
    }

    /// Show the overlay exactly where the region is, including under the menu
    /// bar. The default implementation pushes windows clear of the menu bar,
    /// which would silently shift the frame we later read back as the region's
    /// new geometry.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
    
    private func setupOverlay() {
        guard let contentView = contentView else { return }
        
        contentView.wantsLayer = true
        
        // Choose color based on whether this is a focus region
        let overlayColor = region.isFocusRegion ? NSColor.systemOrange : NSColor.systemBlue
        
        // Border
        contentView.layer?.borderWidth = 3
        contentView.layer?.borderColor = overlayColor.withAlphaComponent(0.8).cgColor
        contentView.layer?.cornerRadius = 8
        
        // Semi-transparent background
        contentView.layer?.backgroundColor = overlayColor.withAlphaComponent(0.1).cgColor
        
        // Label with region name and shortcut
        labelView.isEditable = false
        labelView.isBordered = false
        labelView.drawsBackground = true
        labelView.backgroundColor = overlayColor.withAlphaComponent(0.9)
        labelView.textColor = .white
        labelView.font = .systemFont(ofSize: 16, weight: .semibold)
        labelView.alignment = .center
        
        let shortcutText: String
        if let shortcut = region.keyboardShortcut {
            let symbols = shortcut.modifiers.map { modifierToSymbol($0) }.joined()
            shortcutText = " (\(symbols)\(shortcut.key.uppercased()))"
        } else {
            shortcutText = ""
        }
        
        let focusIndicator = region.isFocusRegion ? " 🎯" : ""
        labelView.stringValue = region.name + focusIndicator + shortcutText
        
        labelView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(labelView)
        
        NSLayoutConstraint.activate([
            labelView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            labelView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            labelView.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, constant: -40),
            labelView.heightAnchor.constraint(equalToConstant: 40)
        ])
        
        labelView.wantsLayer = true
        labelView.layer?.cornerRadius = 8
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
    
    // MARK: - Mouse Events
    
    override func mouseDown(with event: NSEvent) {
        initialMouseLocation = NSEvent.mouseLocation
        initialWindowFrame = frame
        resizeEdge = determineResizeEdge(at: event.locationInWindow)
    }
    
    override func mouseDragged(with event: NSEvent) {
        guard let initialMouse = initialMouseLocation,
              let initialFrame = initialWindowFrame else { return }
        
        let currentMouse = NSEvent.mouseLocation
        let deltaX = currentMouse.x - initialMouse.x
        let deltaY = currentMouse.y - initialMouse.y
        
        var newFrame = initialFrame
        
        switch resizeEdge {
        case .none:
            // Move window
            newFrame.origin.x += deltaX
            newFrame.origin.y += deltaY
            
        case .left:
            newFrame.origin.x += deltaX
            newFrame.size.width -= deltaX
            
        case .right:
            newFrame.size.width += deltaX
            
        case .bottom:
            newFrame.origin.y += deltaY
            newFrame.size.height -= deltaY
            
        case .top:
            newFrame.size.height += deltaY
            
        case .topLeft:
            newFrame.origin.x += deltaX
            newFrame.size.width -= deltaX
            newFrame.size.height += deltaY
            
        case .topRight:
            newFrame.size.width += deltaX
            newFrame.size.height += deltaY
            
        case .bottomLeft:
            newFrame.origin.x += deltaX
            newFrame.size.width -= deltaX
            newFrame.origin.y += deltaY
            newFrame.size.height -= deltaY
            
        case .bottomRight:
            newFrame.size.width += deltaX
            newFrame.origin.y += deltaY
            newFrame.size.height -= deltaY
        }
        
        // Enforce minimum size
        newFrame.size.width = max(100, newFrame.size.width)
        newFrame.size.height = max(100, newFrame.size.height)
        
        setFrame(newFrame, display: true)
    }
    
    private func determineResizeEdge(at point: NSPoint) -> ResizeEdge {
        let edgeThreshold: CGFloat = 20
        let bounds = contentView?.bounds ?? .zero
        
        let nearLeft = point.x < edgeThreshold
        let nearRight = point.x > bounds.width - edgeThreshold
        let nearBottom = point.y < edgeThreshold
        let nearTop = point.y > bounds.height - edgeThreshold
        
        if nearTop && nearLeft { return .topLeft }
        if nearTop && nearRight { return .topRight }
        if nearBottom && nearLeft { return .bottomLeft }
        if nearBottom && nearRight { return .bottomRight }
        if nearTop { return .top }
        if nearBottom { return .bottom }
        if nearLeft { return .left }
        if nearRight { return .right }
        
        return .none
    }
}

/// Background overlay to capture ESC key to dismiss
class BackgroundOverlayWindow: NSWindow {
    var onDismiss: (() -> Void)?
    
    init() {
        // Cover every screen, not just one
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        let allScreens = union.isNull ? NSRect(x: 0, y: 0, width: 1920, height: 1080) : union

        super.init(
            contentRect: allScreens,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.ignoresMouseEvents = true  // Ignore mouse, only handle keyboard
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]
    }
    
    override func keyDown(with event: NSEvent) {
        // Dismiss on ESC key
        if event.keyCode == 53 {
            onDismiss?()
        } else {
            super.keyDown(with: event)
        }
    }
    
    override var canBecomeKey: Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

/// Manager for showing/hiding region overlays
@MainActor
class RegionOverlayManager {
    private var overlayWindows: [RegionOverlayWindow] = []
    private var backgroundOverlay: BackgroundOverlayWindow?
    var onRegionsUpdated: (([Region]) -> Void)?
    
    func showOverlays(for regions: [Region]) {
        hideOverlays()
        
        // Create background overlay first
        let background = BackgroundOverlayWindow()
        background.onDismiss = { [weak self] in
            self?.hideOverlays(saveChanges: true)
        }
        background.orderFrontRegardless()
        background.makeKey()
        self.backgroundOverlay = background
        
        // Create region overlays
        for region in regions {
            guard let cocoaFrame = RegionGeometry.absoluteCocoaFrame(for: region) else {
                log("Not showing overlay for region '\(region.name)': no attached display")
                continue
            }

            let overlay = RegionOverlayWindow(region: region, cocoaFrame: cocoaFrame)
            overlay.onDismiss = { [weak self] in
                self?.hideOverlays(saveChanges: true)
            }
            overlay.orderFrontRegardless()
            overlayWindows.append(overlay)
        }
    }

    func hideOverlays(saveChanges: Bool = false) {
        // If saving changes, collect updated regions
        if saveChanges && !overlayWindows.isEmpty {
            var updatedRegions: [Region] = []
            for overlay in overlayWindows {
                var region = overlay.region

                // The overlay frame is in Cocoa space. Convert back to AX and
                // rebase onto whichever display it now covers, so dragging a
                // region to another monitor reassigns it rather than storing
                // coordinates that belong to the old one.
                let axFrame = CoordinateSpace.cocoaToAX(overlay.frame)
                if let rebased = RegionGeometry.rebase(absoluteAX: axFrame) {
                    region.displayKey = rebased.display.key
                    region.relativeFrame = rebased.relativeFrame
                    updatedRegions.append(region)
                }
            }
            onRegionsUpdated?(updatedRegions)
        }

        backgroundOverlay?.orderOut(nil)
        backgroundOverlay = nil
        
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
    }
    
    func isShowing() -> Bool {
        return !overlayWindows.isEmpty
    }
}
