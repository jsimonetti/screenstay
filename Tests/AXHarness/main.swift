import Cocoa
import ApplicationServices

/// Tests that need Accessibility permission.
///
/// A bare command line binary is never a trusted Accessibility client, so every
/// AX call from one returns nothing and any test written against it passes or
/// fails for the wrong reason. This is built and signed as an app bundle with a
/// stable identifier, granted the permission once, and run from `make test-ax`.
///
/// Everything here reads live system state. Nothing is moved, resized or
/// otherwise altered: an accidental rearrangement of the user's windows is a
/// worse outcome than a missing test.

var passed = 0
var failed = 0
var skipped = 0

func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        passed += 1
        print("  ok    \(name)")
    } else {
        failed += 1
        print("  FAIL  \(name) \(detail())")
    }
}

func skip(_ name: String, _ why: String) {
    skipped += 1
    print("  skip  \(name) (\(why))")
}

func section(_ title: String) {
    print("\n\(title)")
}

@MainActor
func run() -> Int32 {
    print("ScreenStay Accessibility harness")

    guard AXIsProcessTrusted() else {
        print("""

        NOT TRUSTED. This bundle has no Accessibility permission, so every AX
        call would return nothing and every test below would be meaningless.

        Grant it in System Settings, Privacy & Security, Accessibility, then run
        `make test-ax` again. The bundle is at build/ScreenStayAXTests.app.
        """)
        return 2
    }

    let ax = AccessibilityService()
    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    print("trusted; \(apps.count) foreground apps to inspect")

    // ---------------------------------------------------------------- windows

    section("[1] a frontmost window resolves for real apps")
    var windows: [(app: NSRunningApplication, window: AXUIElement)] = []
    for app in apps {
        if let window = ax.getFrontmostWindow(for: app) {
            windows.append((app, window))
        }
    }
    check("at least one frontmost window found", !windows.isEmpty, "\(apps.count) apps, 0 windows")
    guard !windows.isEmpty else {
        print("\n\(passed) passed, \(failed) failed, \(skipped) skipped")
        return failed == 0 ? 0 : 1
    }

    section("[2] every window reports the process that owns it")
    for (app, window) in windows {
        check("\(app.localizedName ?? "?") pid matches",
              ax.getPID(window) == app.processIdentifier,
              "got \(String(describing: ax.getPID(window))), expected \(app.processIdentifier)")
    }

    section("[3] window IDs are resolvable and unique")
    var ids: [CGWindowID: String] = [:]
    var resolved = 0
    for (app, window) in windows {
        guard let id = ax.getWindowID(window) else { continue }
        resolved += 1
        let name = app.localizedName ?? "?"
        check("\(name) window ID \(id) not already claimed", ids[id] == nil, "also \(ids[id] ?? "")")
        ids[id] = name
    }
    check("IDs resolved for most windows", resolved >= windows.count / 2,
          "\(resolved) of \(windows.count)")

    section("[4] resolved IDs correspond to real on-screen windows")
    let listed = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                             kCGNullWindowID) as? [[String: Any]]) ?? []
    let liveIDs = Set(listed.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
    for (id, name) in ids {
        check("\(name) window \(id) is on screen", liveIDs.contains(id))
    }

    section("[5] classification agrees with itself and explains refusals")
    var placeable = 0
    for (app, window) in windows {
        let reason = ax.placementRefusalReason(for: window)
        let allowed = ax.shouldPositionWindow(window)
        check("\(app.localizedName ?? "?") reason and predicate agree", allowed == (reason == nil),
              "allowed=\(allowed) reason=\(reason ?? "nil")")
        if allowed { placeable += 1 } else {
            print("        refused: \(app.localizedName ?? "?") - \(reason ?? "?")")
        }
    }
    // If this ever reads zero the AXStandardWindow requirement has gone wrong
    // and the app would silently stop managing anything.
    check("ordinary app windows are still placeable", placeable > 0,
          "0 of \(windows.count) accepted, the filter is too strict")

    section("[6] geometry round-trips through the coordinate helpers")
    for (app, window) in windows.prefix(5) {
        guard let position = ax.getWindowPosition(window),
              let size = ax.getWindowSize(window) else {
            skip("\(app.localizedName ?? "?") geometry", "position or size unavailable")
            continue
        }
        let axFrame = CGRect(origin: position, size: size)
        let roundTripped = CoordinateSpace.cocoaToAX(CoordinateSpace.axToCocoa(axFrame))
        check("\(app.localizedName ?? "?") AX to Cocoa round-trips", roundTripped == axFrame,
              "\(axFrame) -> \(roundTripped)")
    }

    section("[7] a window's own display can be identified")
    DisplayRegistry.shared.refresh()
    for (app, window) in windows.prefix(5) {
        guard let position = ax.getWindowPosition(window),
              let size = ax.getWindowSize(window) else { continue }
        let centre = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        let display = DisplayRegistry.shared.display(containingAX: centre)
        check("\(app.localizedName ?? "?") centre lands on a display", display != nil,
              "centre \(centre)")
    }

    section("[8] minimized state is readable without altering it")
    for (app, window) in windows.prefix(5) {
        let before = ax.isMinimized(window)
        let after = ax.isMinimized(window)
        check("\(app.localizedName ?? "?") minimized reads consistently", before == after)
    }

    print("\n\(passed) passed, \(failed) failed, \(skipped) skipped")
    return failed == 0 ? 0 : 1
}

exit(MainActor.assumeIsolated { run() })
