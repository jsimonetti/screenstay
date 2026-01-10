import AppKit

/// Interactive region drawing overlay
@MainActor
class RegionDrawingOverlay: NSWindow {
    private var startPoint: NSPoint?
    private var currentRect: NSRect?
    private var onComplete: ((NSRect) -> Void)?
    private let drawingView: RegionDrawingView
    
    init(onComplete: @escaping (NSRect) -> Void) {
        self.onComplete = onComplete
        self.drawingView = RegionDrawingView()
        
        // Get main screen bounds
        let screenRect = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        
        super.init(
            contentRect: screenRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = NSColor.black.withAlphaComponent(0.3)
        self.ignoresMouseEvents = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.acceptsMouseMovedEvents = true
        self.isReleasedWhenClosed = false
        
        setupContentView()
        setupInstructions()
    }
    
    private func setupContentView() {
        guard let contentView = contentView else { return }
        
        drawingView.frame = contentView.bounds
        drawingView.autoresizingMask = [.width, .height]
        contentView.addSubview(drawingView)
    }
    
    private func setupInstructions() {
        let label = NSTextField(labelWithString: "Click and drag to draw a region. Press ESC to cancel.")
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textColor = .white
        label.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        label.isBezeled = false
        label.drawsBackground = true
        label.alignment = .center
        
        guard let contentView = contentView else { return }
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 40),
            label.widthAnchor.constraint(equalToConstant: 500),
            label.heightAnchor.constraint(equalToConstant: 40)
        ])
    }
    
    override func mouseDown(with event: NSEvent) {
        startPoint = event.locationInWindow
        currentRect = nil
        drawingView.selectionRect = nil
        drawingView.needsDisplay = true
    }
    
    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let current = event.locationInWindow
        
        let x = min(start.x, current.x)
        let y = min(start.y, current.y)
        let width = abs(current.x - start.x)
        let height = abs(current.y - start.y)
        
        currentRect = NSRect(x: x, y: y, width: width, height: height)
        drawingView.selectionRect = currentRect
        drawingView.dimensionText = "x: \(Int(x))  y: \(Int(y))  width: \(Int(width))  height: \(Int(height))"
        drawingView.needsDisplay = true
    }
    
    override func mouseUp(with event: NSEvent) {
        guard let rect = currentRect, rect.width > 10 && rect.height > 10 else {
            cancel()
            return
        }
        
        // Convert from window coordinates to screen coordinates
        let screenRect = convertToScreen(NSRect(origin: rect.origin, size: rect.size))
        onComplete?(screenRect)
        close()
    }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC key
            cancel()
        } else {
            super.keyDown(with: event)
        }
    }
    
    override var canBecomeKey: Bool {
        return true
    }
    
    override var acceptsFirstResponder: Bool {
        return true
    }
    
    private func cancel() {
        log("📐 Region drawing cancelled")
        close()
    }
}

/// Custom view to draw the selection rectangle
class RegionDrawingView: NSView {
    var selectionRect: NSRect?
    var dimensionText: String = ""
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        guard let rect = selectionRect else { return }
        
        // Draw selection rectangle
        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 3
        path.stroke()
        
        // Fill with semi-transparent blue
        NSColor.systemBlue.withAlphaComponent(0.2).setFill()
        path.fill()
        
        // Draw dimensions text
        if !dimensionText.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            
            let textSize = dimensionText.size(withAttributes: attributes)
            let bgRect = NSRect(
                x: rect.midX - textSize.width / 2 - 4,
                y: rect.midY - textSize.height / 2 - 2,
                width: textSize.width + 8,
                height: textSize.height + 4
            )
            
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: bgRect, xRadius: 4, yRadius: 4).fill()
            
            dimensionText.draw(at: NSPoint(x: bgRect.minX + 4, y: bgRect.minY + 2), withAttributes: attributes)
        }
    }
}

