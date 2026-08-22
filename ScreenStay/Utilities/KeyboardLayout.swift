import Carbon.HIToolbox
import Cocoa

/// Maps hardware key codes to the characters the current keyboard layout puts
/// on them.
///
/// Shortcuts are stored as characters, so "the Z key" follows the layout rather
/// than the physical position. Both the recorder and the event tap resolve
/// through here, which is the point: a hardcoded table in one place and
/// `charactersIgnoringModifiers` in the other cannot disagree if neither exists.
///
/// The table is built once per layout and cached. The event tap runs on the
/// window server's thread against a deadline, so it can afford a dictionary
/// lookup and nothing more; `TISCopyCurrentKeyboardLayoutInputSource` per
/// keystroke would not be affordable.
enum KeyboardLayout {

    /// Highest key code worth asking about. Above this are media and modifier
    /// keys that produce no character.
    private static let maxKeyCode: CGKeyCode = 127

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [CGKeyCode: String]?
    nonisolated(unsafe) private static var observing = false

    // MARK: - Lookup

    /// The character a key produces with no modifiers applied, lowercased.
    ///
    /// Nil for keys that produce nothing typable: function keys, arrows, escape,
    /// and anything else the layout has no character for.
    static func character(for keyCode: CGKeyCode) -> String? {
        lock.lock()
        if cache == nil {
            cache = buildTable()
            startObservingLayoutChanges()
        }
        let result = cache?[keyCode]
        lock.unlock()
        return result
    }

    /// Every character the current layout can produce as a shortcut key.
    static func availableCharacters() -> Set<String> {
        lock.lock()
        if cache == nil {
            cache = buildTable()
            startObservingLayoutChanges()
        }
        let result = Set(cache?.values ?? [:].values)
        lock.unlock()
        return result
    }

    /// Whether a stored shortcut key can ever be produced on this layout.
    ///
    /// A shortcut whose key is not in the table is dead: no key press will ever
    /// match it, silently.
    static func canProduce(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        return availableCharacters().contains(key.lowercased())
    }

    // MARK: - Building

    private static func buildTable() -> [CGKeyCode: String] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            log("Keyboard layout unavailable; shortcuts will not resolve")
            return [:]
        }

        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())

        var table: [CGKeyCode: String] = [:]
        data.withUnsafeBytes { buffer in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }

            for keyCode in 0...maxKeyCode {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)

                let status = UCKeyTranslate(
                    layout,
                    keyCode,
                    UInt16(kUCKeyActionDisplay),
                    0, // no modifiers: we want the key's own character
                    keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    characters.count,
                    &length,
                    &characters
                )

                guard status == noErr, length > 0 else { continue }
                let string = String(utf16CodeUnits: characters, count: length)
                guard isTypable(string) else { continue }
                table[keyCode] = string.lowercased()
            }
        }

        log("Keyboard layout table built: \(table.count) usable keys")
        return table
    }

    /// Reject anything that is not a real character a user could name.
    ///
    /// Function keys and arrows come back as private-use scalars rather than
    /// nothing, so length alone is not enough of a test.
    private static func isTypable(_ string: String) -> Bool {
        guard let scalar = string.unicodeScalars.first, string.unicodeScalars.count == 1 else {
            return false
        }
        if scalar.value < 0x20 || scalar.value == 0x7F { return false }      // control characters
        if (0xF700...0xF8FF).contains(scalar.value) { return false }         // private use: F-keys, arrows
        if scalar == " " { return false }                                    // unusable as a shortcut key
        return true
    }

    // MARK: - Invalidation

    /// Rebuild when the user switches input source, otherwise every shortcut
    /// would keep resolving against the layout that was active at first use.
    private static func startObservingLayoutChanges() {
        guard !observing else { return }
        observing = true

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { _ in
            lock.lock()
            cache = nil
            lock.unlock()
            log("Keyboard layout changed; shortcut table will be rebuilt")
        }
    }
}
