import Cocoa
import Carbon

/// Global keyboard handler using CGEventTap for reliable system-wide keyboard shortcuts
@MainActor
class GlobalKeyboardHandler {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onShortcutTriggered: ((KeyboardShortcut) -> Void)?
    private var shortcuts: [KeyboardShortcut] = []
    
    func start(shortcuts: [KeyboardShortcut], onShortcutTriggered: @escaping (KeyboardShortcut) -> Void) {
        self.shortcuts = shortcuts
        self.onShortcutTriggered = onShortcutTriggered
        
        log("🎹 Starting keyboard handler with \(shortcuts.count) shortcuts")
        
        // Stop existing tap if any
        stop()
        
        // Create event tap
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        
        log("🎹 Creating event tap with mask: \(eventMask)")
        
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon in
                let handler = Unmanaged<GlobalKeyboardHandler>.fromOpaque(refcon!).takeUnretainedValue()
                return handler.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log("❌ Failed to create event tap - Input Monitoring permission may be missing")
            showInputMonitoringAlert()
            return
        }
        
        self.eventTap = eventTap
        
        // Add to run loop
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        
        log("✅ Global keyboard handler started with \(shortcuts.count) shortcuts")
    }
    
    private func showInputMonitoringAlert() {
        let alert = NSAlert()
        alert.messageText = "Input Monitoring Permission Required"
        alert.informativeText = """
        ScreenStay needs Input Monitoring permission to capture keyboard shortcuts.
        
        Please enable it in:
        System Settings → Privacy & Security → Input Monitoring
        
        Then restart ScreenStay.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
        }
    }
    
    func stop() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            if let runLoopSource = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            }
            self.eventTap = nil
            self.runLoopSource = nil
        }
    }
    
    func updateShortcuts(_ shortcuts: [KeyboardShortcut]) {
        let oldCount = self.shortcuts.count
        self.shortcuts = shortcuts
        log("🔄 Updated keyboard shortcuts: \(oldCount) -> \(shortcuts.count)")
    }
    
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Handle tap disabled (requires re-enable)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap = eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        
        // Only process keyDown events
        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }
        
        // Get key code and modifiers
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        
        // Convert key code to character
        guard let characters = keyCodeToString(Int(keyCode)) else {
            return Unmanaged.passUnretained(event)
        }
        
        // Check if any shortcut matches
        for shortcut in shortcuts {
            if matchesShortcut(shortcut, flags: flags, characters: characters) {
                log("⌨️ Keyboard shortcut matched: \(shortcut.modifiers.joined(separator: "+"))+\(shortcut.key)")
                
                // Trigger handler on main thread
                Task { @MainActor in
                    self.onShortcutTriggered?(shortcut)
                }
                
                // Consume the event (return nil to prevent propagation)
                return nil
            }
        }
        
        // Pass through unmatched events
        return Unmanaged.passUnretained(event)
    }
    
    private func matchesShortcut(_ shortcut: KeyboardShortcut, flags: CGEventFlags, characters: String) -> Bool {
        // Check modifiers
        var requiredFlags: CGEventFlags = []
        if shortcut.modifiers.contains("cmd") { requiredFlags.insert(.maskCommand) }
        if shortcut.modifiers.contains("shift") { requiredFlags.insert(.maskShift) }
        if shortcut.modifiers.contains("option") { requiredFlags.insert(.maskAlternate) }
        if shortcut.modifiers.contains("control") { requiredFlags.insert(.maskControl) }
        
        // Check if all required modifiers are pressed
        let hasRequiredModifiers = flags.contains(requiredFlags)
        
        // Check key match
        let matchesKey = characters.lowercased() == shortcut.key.lowercased()
        
        return hasRequiredModifiers && matchesKey
    }
    
    private func keyCodeToString(_ keyCode: Int) -> String? {
        // Map common key codes to characters
        let keyCodeMap: [Int: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
            11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
            31: "o", 32: "u", 34: "i", 35: "p",
            37: "l", 38: "j", 40: "k",
            45: "n", 46: "m"
        ]
        
        return keyCodeMap[keyCode]
    }
}
