import AppKit

/// A view that captures keyboard shortcuts like System Settings
class KeyboardShortcutRecorder: NSView {
    private let textField = NSTextField()
    private let clearButton = NSButton()
    
    var onShortcutChanged: ((modifiers: [String], key: String)?) -> Void = { _ in }
    
    private var currentModifiers: [String] = []
    private var currentKey: String = ""
    private var isRecording = false
    
    var currentShortcut: (modifiers: [String], key: String)? {
        guard !currentModifiers.isEmpty && !currentKey.isEmpty else { return nil }
        return (currentModifiers, currentKey)
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }
    
    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        
        // Text field to show shortcut
        textField.isEditable = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.font = .systemFont(ofSize: 13)
        textField.alignment = .center
        textField.stringValue = "Click to record"
        textField.translatesAutoresizingMaskIntoConstraints = false
        
        // Clear button (x)
        clearButton.title = "×"
        clearButton.bezelStyle = .inline
        clearButton.isBordered = false
        clearButton.font = .systemFont(ofSize: 16, weight: .medium)
        clearButton.target = self
        clearButton.action = #selector(clearShortcut)
        clearButton.isHidden = true
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        
        addSubview(textField)
        addSubview(clearButton)
        
        NSLayoutConstraint.activate([
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            textField.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -4),
            
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            clearButton.widthAnchor.constraint(equalToConstant: 20)
        ])
    }
    
    override var acceptsFirstResponder: Bool { true }
    
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        startRecording()
    }
    
    private func startRecording() {
        isRecording = true
        textField.stringValue = "Type shortcut..."
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 2
    }
    
    private func stopRecording() {
        isRecording = false
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        updateDisplay()
    }
    
    override func keyDown(with event: NSEvent) {
        guard isRecording else { return }
        
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers ?? ""
        
        // Ignore modifier-only presses
        guard !key.isEmpty else { return }
        
        // Extract modifier keys
        var modifierList: [String] = []
        if modifiers.contains(.control) { modifierList.append("control") }
        if modifiers.contains(.option) { modifierList.append("option") }
        if modifiers.contains(.shift) { modifierList.append("shift") }
        if modifiers.contains(.command) { modifierList.append("cmd") }
        
        // Require at least one modifier
        guard !modifierList.isEmpty else {
            NSSound.beep()
            return
        }
        
        currentModifiers = modifierList
        currentKey = key
        
        stopRecording()
        onShortcutChanged((modifiers: currentModifiers, key: currentKey))
    }
    
    override func flagsChanged(with event: NSEvent) {
        // Just for visual feedback while recording
        if isRecording {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var symbols: [String] = []
            if modifiers.contains(.control) { symbols.append("⌃") }
            if modifiers.contains(.option) { symbols.append("⌥") }
            if modifiers.contains(.shift) { symbols.append("⇧") }
            if modifiers.contains(.command) { symbols.append("⌘") }
            
            if symbols.isEmpty {
                textField.stringValue = "Type shortcut..."
            } else {
                textField.stringValue = symbols.joined() + "..."
            }
        }
    }
    
    private func updateDisplay() {
        if currentModifiers.isEmpty || currentKey.isEmpty {
            textField.stringValue = "Click to record"
            clearButton.isHidden = true
        } else {
            let symbols = currentModifiers.map { modifierToSymbol($0) }
            textField.stringValue = symbols.joined() + currentKey.uppercased()
            clearButton.isHidden = false
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
    
    @objc private func clearShortcut() {
        currentModifiers = []
        currentKey = ""
        updateDisplay()
        onShortcutChanged(nil)
    }
    
    func setShortcut(modifiers: [String], key: String) {
        currentModifiers = modifiers
        currentKey = key
        updateDisplay()
    }
}
