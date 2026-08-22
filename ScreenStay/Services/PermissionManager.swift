import Foundation
import ApplicationServices
import AppKit

/// Accessibility permission handling.
///
/// Accessibility is the only permission ScreenStay needs. It covers both moving
/// windows through the Accessibility API and listening for shortcuts through a
/// CGEventTap: a tap requires the process to be a trusted Accessibility client
/// *or* to hold Input Monitoring, and the former is already a hard requirement
/// here.
///
/// ScreenStay used to also ask for Input Monitoring. That request silently
/// resolved to "already granted" because of the Accessibility trust, so no
/// prompt ever appeared and the app never showed up under Input Monitoring in
/// System Settings, while the UI kept telling people to go and enable it there.
@MainActor
class PermissionManager {

    /// How often to re-check while waiting for the user to grant access.
    private static let pollInterval: TimeInterval = 2

    /// How long to wait before explaining ourselves. The system prompt is
    /// already on screen at launch, and stacking our own alert on top of it
    /// buries the one the user actually needs to answer.
    private static let explainAfter: TimeInterval = 30

    private static var pollTimer: Timer?
    private static var waitingSince: Date?
    private static var hasExplained = false

    // MARK: - Checking

    /// Whether Accessibility permission is granted.
    static func checkAccessibility() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Ask the system to prompt for Accessibility permission.
    ///
    /// The prompt only appears the first time an app asks under a given code
    /// signing identity. After that this is a no-op and the user has to go to
    /// System Settings themselves, which is what `waitForAccessibility` covers.
    static nonisolated func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Waiting

    /// Run `onGranted` as soon as Accessibility permission is available.
    ///
    /// Calls back immediately if it is already granted. Otherwise it triggers
    /// the system prompt and polls, so granting access takes effect without
    /// restarting the app.
    static func waitForAccessibility(onGranted: @escaping @MainActor () -> Void) {
        if checkAccessibility() {
            onGranted()
            return
        }

        log("Accessibility permission not granted; prompting and waiting")
        requestAccessibility()

        pollTimer?.invalidate()
        waitingSince = Date()
        hasExplained = false

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard checkAccessibility() else {
                    explainIfOverdue()
                    return
                }

                log("Accessibility permission granted")
                pollTimer?.invalidate()
                pollTimer = nil
                waitingSince = nil
                onGranted()
            }
        }
    }

    /// Stop waiting, e.g. on shutdown.
    static func cancelWaiting() {
        pollTimer?.invalidate()
        pollTimer = nil
        waitingSince = nil
    }

    /// Show a one-off explanation once the system prompt has had its chance.
    private static func explainIfOverdue() {
        guard !hasExplained,
              let waitingSince,
              Date().timeIntervalSince(waitingSince) >= explainAfter else {
            return
        }

        hasExplained = true
        showAccessibilityAlert()
    }

    private static func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
        ScreenStay needs Accessibility permission to position windows and to \
        listen for its keyboard shortcuts.

        Enable ScreenStay in System Settings, Privacy & Security, Accessibility.

        ScreenStay picks this up on its own, so there is no need to restart it.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }
}
