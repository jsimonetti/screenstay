import Foundation

/// Well-known macOS shortcuts that ScreenStay would swallow.
///
/// The event tap sits at the head of the session and consumes anything it
/// matches, so binding one of these does not merely shadow the system
/// behaviour, it removes it for every app for as long as ScreenStay is running.
/// That is worth saying out loud rather than leaving to be discovered.
///
/// Deliberately short. Only combinations that are documented, system-wide, and
/// expressible as a modifier set plus a single character are listed; guessing
/// would produce false warnings, which are worse than none.
enum SystemShortcuts {

    struct Entry {
        let modifiers: Set<String>
        let key: String
        let name: String
    }

    static let all: [Entry] = [
        Entry(modifiers: ["control", "cmd"], key: "f", name: "Enter or Exit Full Screen"),
        Entry(modifiers: ["control", "cmd"], key: "q", name: "Lock Screen"),
        Entry(modifiers: ["control", "cmd"], key: "d", name: "Look Up"),
        Entry(modifiers: ["cmd", "shift"], key: "3", name: "Screenshot the screen"),
        Entry(modifiers: ["cmd", "shift"], key: "4", name: "Screenshot a selection"),
        Entry(modifiers: ["cmd", "shift"], key: "5", name: "Screenshot and recording options"),
        Entry(modifiers: ["cmd", "shift"], key: "/", name: "Help menu"),
        Entry(modifiers: ["cmd", "option"], key: "d", name: "Show or hide the Dock"),
        Entry(modifiers: ["cmd", "option", "shift"], key: "v", name: "Paste and Match Style"),
    ]

    /// What a shortcut would take over, if anything.
    static func conflict(with shortcut: KeyboardShortcut) -> String? {
        all.first {
            $0.key == shortcut.key.lowercased() && $0.modifiers == Set(shortcut.modifiers)
        }?.name
    }
}
