import Cocoa
import Carbon

/// Global keyboard handler using CGEventTap for reliable system-wide keyboard shortcuts
///
/// The tap callback is invoked by the window server on its own thread, so this
/// type is deliberately not `@MainActor`. Everything the callback touches lives
/// behind `lock`, and the only main-actor work it does is hop over to deliver a
/// matched shortcut. Doing anything slower than a dictionary lookup in the
/// callback risks the window server disabling the tap for exceeding its
/// deadline, which is why there is no logging on the hot path.
///
/// Note there is no Input Monitoring handling here. An event tap needs the
/// process to be a trusted Accessibility client *or* to hold Input Monitoring,
/// and ScreenStay already requires Accessibility to move windows at all. Asking
/// for Input Monitoring on top of that prompts for nothing, never adds the app
/// to that list in System Settings, and only confuses people looking for it.
final class GlobalKeyboardHandler: @unchecked Sendable {

    /// Guards every stored property; taken on both the tap thread and the main actor.
    private let lock = NSLock()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var shortcuts: [KeyboardShortcut] = []
    private var onShortcutTriggered: (@MainActor @Sendable (KeyboardShortcut) -> Void)?

    // MARK: - Lifecycle

    @MainActor
    func start(shortcuts: [KeyboardShortcut], onShortcutTriggered: @escaping @MainActor @Sendable (KeyboardShortcut) -> Void) {
        log("🎹 Starting keyboard handler with \(shortcuts.count) shortcuts")
        for shortcut in shortcuts {
            log("  - Shortcut: \(shortcut.modifiers.joined(separator: "+"))+\(shortcut.key)")
        }

        // Stop existing tap if any
        stop()

        lock.lock()
        self.shortcuts = shortcuts
        self.onShortcutTriggered = onShortcutTriggered
        lock.unlock()

        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let handler = Unmanaged<GlobalKeyboardHandler>.fromOpaque(refcon).takeUnretainedValue()
            return handler.handleEvent(type: type, event: event)
        }

        // cgSessionEventTap is the normal choice; cghidEventTap sits earlier in
        // the pipeline and occasionally succeeds when the session tap does not.
        var tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        if tap == nil {
            log("⚠️ cgSessionEventTap failed, trying cghidEventTap...")
            tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(eventMask),
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        }

        guard let tap else {
            log("❌ Could not create the keyboard event tap")
            showPermissionAlert()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        lock.lock()
        self.eventTap = tap
        self.runLoopSource = source
        lock.unlock()

        log("✅ Keyboard handler listening (tap enabled: \(CGEvent.tapIsEnabled(tap: tap)))")
    }

    @MainActor
    func stop() {
        lock.lock()
        let tap = eventTap
        let source = runLoopSource
        eventTap = nil
        runLoopSource = nil
        onShortcutTriggered = nil
        lock.unlock()

        guard let tap else { return }

        CGEvent.tapEnable(tap: tap, enable: false)
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        // Tear the port down explicitly rather than waiting for ARC; start()
        // calls stop() first, and taps would otherwise pile up across restarts.
        CFMachPortInvalidate(tap)
    }

    func updateShortcuts(_ shortcuts: [KeyboardShortcut]) {
        lock.lock()
        self.shortcuts = shortcuts
        lock.unlock()
    }

    // MARK: - Event tap callback

    /// Called on the window server's tap thread. Keep this cheap.
    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The tap is disabled if it ever exceeds its deadline, or when the user
        // triggers a secure input path. Re-enabling is the documented recovery.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let tap = eventTap
            lock.unlock()
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard let character = Self.keyCodeMap[keyCode] else {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags

        lock.lock()
        let match = shortcuts.first { Self.matches($0, flags: flags, character: character) }
        let handler = onShortcutTriggered
        lock.unlock()

        guard let match, let handler else {
            return Unmanaged.passUnretained(event)
        }

        // Deliver on the main actor; logging happens there too, off this thread.
        Task { @MainActor in
            log("🎯 Shortcut matched: \(match.modifiers.joined(separator: "+"))+\(match.key)")
            handler(match)
        }

        // Consume the event so the shortcut does not reach the focused app.
        return nil
    }

    private static func matches(_ shortcut: KeyboardShortcut, flags: CGEventFlags, character: String) -> Bool {
        var required: CGEventFlags = []
        if shortcut.modifiers.contains("cmd") { required.insert(.maskCommand) }
        if shortcut.modifiers.contains("shift") { required.insert(.maskShift) }
        if shortcut.modifiers.contains("option") { required.insert(.maskAlternate) }
        if shortcut.modifiers.contains("control") { required.insert(.maskControl) }

        return flags.contains(required) && character == shortcut.key.lowercased()
    }

    /// Key codes ScreenStay accepts as shortcut keys.
    private static let keyCodeMap: [Int: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        31: "o", 32: "u", 34: "i", 35: "p",
        37: "l", 38: "j", 40: "k",
        45: "n", 46: "m"
    ]

    // MARK: - Failure reporting

    @MainActor
    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Keyboard Shortcuts Unavailable"
        alert.informativeText = """
        ScreenStay could not listen for keyboard shortcuts.

        This needs Accessibility permission, the same permission used to move \
        windows. Enable ScreenStay in System Settings, Privacy & Security, \
        Accessibility, then restart ScreenStay.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            PermissionManager.openAccessibilitySettings()
        }
    }
}
