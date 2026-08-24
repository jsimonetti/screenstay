import AppKit

/// Owns a layout editing session.
///
/// A session puts one overlay on every display in the profile and drives them
/// as a unit: a single working copy of the regions, one undo stack, and one key
/// handler, because only one window can be key at a time while the shortcuts
/// have to work wherever the pointer is.
@MainActor
final class LayoutEditorController {

    /// Why a profile could not be opened for editing.
    enum RefusalReason {
        /// The profile describes displays that are not attached.
        case displaysMissing([String])
        /// The profile has no displays recorded at all.
        case profileHasNoDisplays
    }

    private struct Session {
        let profileID: String
        let profileName: String
        let originalRegions: [Region]
        var regions: [Region]

        /// Region is Equatable, so compare it whole.
        ///
        /// This used to list the fields to compare by hand and had already
        /// fallen behind: keyboardShortcut was missing, so changing only a
        /// shortcut left the session looking clean and Escape closed it without
        /// even offering to save.
        var isDirty: Bool {
            regions != originalRegions
        }
    }

    private var session: Session?
    /// One per display in the profile. Read by the drag and menu extensions.
    private(set) var overlays: [LayoutEditorOverlayWindow] = []
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var displayChangeObserver: NSObjectProtocol?
    private var undoStack: [[Region]] = []
    private var redoStack: [[Region]] = []
    private var savedPresentationOptions: NSApplication.PresentationOptions?
    /// Display bounds the session opened against, to tell a real reconfiguration
    /// from a notification about something else.
    private var openingDisplayBounds: [String: CGRect] = [:]

    /// Region the pointer and the context menu act on.
    var selectedRegionID: String?
    /// What the pointer is doing, if anything.
    var activeDrag: Drag?
    /// Regions as they were when the current drag started, for a single undo step.
    private var dragSnapshot: [Region]?

    /// Shortcuts claimed outside the profile's regions, supplied by the caller
    /// so a clash can be pointed out. A region shortcut duplicating one of these
    /// never fires: the global handler matches first and swallows it.
    var globalShortcuts: [(shortcut: KeyboardShortcut, name: String)] = []

    /// Called with the edited regions when a session is saved.
    var onSave: ((_ profileID: String, _ regions: [Region]) -> Void)?
    /// Called when a session ends, saved or not, so the caller can restore its UI.
    var onClose: (() -> Void)?

    var isOpen: Bool { session != nil }

    // MARK: - Opening

    /// Open the editor for a profile, or explain why it cannot be opened.
    @discardableResult
    func open(profile: Profile) -> RefusalReason? {
        guard !isOpen else { return nil }

        guard !profile.displayTopology.displays.isEmpty else {
            return .profileHasNoDisplays
        }

        DisplayRegistry.shared.refresh()
        let live = DisplayTopology.current()

        // Any successful match is enough. Insisting on an exact identity match
        // would lock out a profile whose legacy keys have never been bound.
        guard let match = profile.match(against: live) else {
            return .displaysMissing(missingDisplayDescriptions(in: profile, live: live))
        }

        // Bind provisional keys to the attached hardware before resolving any
        // geometry, otherwise regions still carrying `legacy:` keys would fall
        // back to the primary display.
        var bound = profile
        _ = ConfigurationMigration.adoptLiveKeys(in: &bound, match: match, live: live)

        session = Session(
            profileID: bound.id,
            profileName: bound.name,
            originalRegions: bound.regions,
            regions: bound.regions
        )

        undoStack.removeAll()
        redoStack.removeAll()

        presentOverlays(for: bound)
        startKeyMonitor()

        // Activate first. Presentation options are only applied while the app
        // is active; requesting them from an inactive app is silently ignored,
        // leaving currentSystemPresentationOptions empty and the menu bar up.
        NSApp.activate(ignoringOtherApps: true)

        // Window level alone does not get past the menu bar, so the editor has
        // to ask for it to be hidden. Restored in close(), and the system
        // restores it anyway as soon as another app becomes active.
        //
        // This must also happen before the display observer starts: hiding the
        // menu bar and the Dock changes every screen's visibleFrame, which
        // posts didChangeScreenParameters twice and would otherwise close the
        // session we are in the middle of opening.
        savedPresentationOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]

        startDisplayChangeObserver()

        let menuBarHidden = NSApp.currentSystemPresentationOptions.contains(.hideMenuBar)
        log("Layout editor opened for '\(bound.name)' across \(overlays.count) display(s); "
            + "menu bar hidden: \(menuBarHidden)")
        return nil
    }

    private func presentOverlays(for profile: Profile) {
        let keysInProfile = Set(profile.displayTopology.displays.compactMap(\.key))

        for display in DisplayRegistry.shared.displays where keysInProfile.contains(display.key) {
            let overlay = LayoutEditorOverlayWindow(display: display, profileName: profile.name)
            overlay.canvas.regions = profile.regions.filter { $0.displayKey == display.key }
            overlay.canvas.onContextMenu = { [weak self] point, display, event, view in
                self?.showContextMenu(atRelative: point, on: display, event: event, in: view)
            }
            overlay.canvas.onMouseDown = { [weak self] point, display in
                self?.handleMouseDown(atRelative: point, on: display)
            }
            overlay.canvas.onMouseDragged = { [weak self] point, display in
                self?.handleMouseDragged(atRelative: point, on: display)
            }
            overlay.canvas.onMouseUp = { [weak self] point, display in
                self?.handleMouseUp(atRelative: point, on: display)
            }
            overlay.orderFrontRegardless()
            overlays.append(overlay)
        }

        // Key goes to the overlay on the display holding the pointer, so the
        // first thing the user interacts with is already focused.
        let pointer = CoordinateSpace.cocoaToAX(NSEvent.mouseLocation)
        let preferred = overlays.first { $0.display.axBounds.contains(pointer) } ?? overlays.first
        preferred?.makeKey()
    }

    // MARK: - Editing

    /// The working copy the menu acts on.
    var currentRegions: [Region] { session?.regions ?? [] }

    /// The canvas showing a given display, if the session has one.
    func canvas(for display: DisplayRegistry.ResolvedDisplay) -> LayoutEditorCanvasView? {
        overlays.first { $0.display.key == display.key }?.canvas
    }

    /// Apply an edit, recording it for undo and redrawing every overlay.
    func mutate(_ description: String, _ body: (inout [Region]) -> Void) {
        guard var session else { return }

        let before = session.regions
        body(&session.regions)
        guard session.regions != before else { return }

        undoStack.append(before)
        redoStack.removeAll()
        self.session = session
        refreshCanvases()
        refreshHandles()
        log("Layout editor: \(description)")
    }

    /// Apply an edit without touching the undo stack, for the frames of a drag.
    func updateLive(_ body: (inout [Region]) -> Void) {
        guard var session else { return }
        body(&session.regions)
        self.session = session
        refreshCanvases()
    }

    func beginDrag(_ drag: Drag) {
        activeDrag = drag
        dragSnapshot = currentRegions
    }

    /// Finish a drag, recording the whole gesture as one undo step.
    func endDrag() {
        defer {
            activeDrag = nil
            dragSnapshot = nil
        }
        guard let dragSnapshot, dragSnapshot != currentRegions else { return }
        undoStack.append(dragSnapshot)
        redoStack.removeAll()
    }

    func undo() {
        guard var session, let previous = undoStack.popLast() else { return }
        redoStack.append(session.regions)
        session.regions = previous
        self.session = session
        refreshCanvases()
        refreshHandles()
        log("Layout editor: undo")
    }

    func redo() {
        guard var session, let next = redoStack.popLast() else { return }
        undoStack.append(session.regions)
        session.regions = next
        self.session = session
        refreshCanvases()
        refreshHandles()
        log("Layout editor: redo")
    }

    private func refreshCanvases() {
        for overlay in overlays {
            overlay.canvas.regions = currentRegions.filter { $0.displayKey == overlay.display.key }
        }
    }

    /// Run a modal alert with the overlays dropped out of the way.
    ///
    /// Alerts sit at window level 8 and the overlays at 26, so without this the
    /// alert would be presented behind them and the app would look frozen.
    @discardableResult
    func runModal<T>(_ body: () -> T) -> T {
        let saved = overlays.map(\.level)
        for overlay in overlays {
            overlay.level = .normal
        }
        defer {
            for (overlay, level) in zip(overlays, saved) {
                overlay.level = level
            }
        }
        return body()
    }

    // MARK: - Closing

    /// Ask to close. Prompts when there are unsaved changes.
    func requestClose() {
        guard let session else { return }

        guard session.isDirty else {
            close(saving: false)
            return
        }

        switch promptForUnsavedChanges(session) {
        case .save: close(saving: true)
        case .discard: close(saving: false)
        case .cancel: break
        }
    }

    /// Tear the session down unconditionally.
    func close(saving: Bool) {
        guard let session else { return }

        if saving {
            onSave?(session.profileID, session.regions)
            log("Layout editor saved '\(session.profileName)'")
        } else {
            log("Layout editor closed '\(session.profileName)' without saving")
        }

        if let savedPresentationOptions {
            NSApp.presentationOptions = savedPresentationOptions
        }
        savedPresentationOptions = nil
        selectedRegionID = nil
        activeDrag = nil
        dragSnapshot = nil

        stopKeyMonitor()
        stopDisplayChangeObserver()
        for overlay in overlays {
            overlay.orderOut(nil)
        }
        overlays.removeAll()
        self.session = nil

        onClose?()
    }

    private enum UnsavedChoice { case save, discard, cancel }

    private func promptForUnsavedChanges(_ session: Session) -> UnsavedChoice {
        let alert = NSAlert()
        alert.messageText = "Save changes to \u{201C}\(session.profileName)\u{201D}?"
        alert.informativeText = changeSummary(session)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard")

        switch runModal({ alert.runModal() }) {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// Describe the edit in terms of what would be lost, not just what moved.
    private func changeSummary(_ session: Session) -> String {
        let originalIDs = Set(session.originalRegions.map(\.id))
        let currentIDs = Set(session.regions.map(\.id))

        let added = currentIDs.subtracting(originalIDs).count
        let removed = session.originalRegions.filter { !currentIDs.contains($0.id) }
        let changed = session.regions.filter { region in
            guard let original = session.originalRegions.first(where: { $0.id == region.id }) else { return false }
            return original.relativeFrame != region.relativeFrame || original.displayKey != region.displayKey
        }.count

        var parts: [String] = []
        if changed > 0 { parts.append(changed == 1 ? "moved 1 region" : "moved \(changed) regions") }
        if added > 0 { parts.append(added == 1 ? "added 1" : "added \(added)") }
        if !removed.isEmpty { parts.append(removed.count == 1 ? "deleted 1" : "deleted \(removed.count)") }

        var summary = parts.isEmpty ? "This layout has unsaved changes." : "You \(parts.joined(separator: ", "))."

        // Deleting a region takes its app assignments and shortcut with it.
        let costly = removed.filter { !$0.assignedApps.isEmpty || $0.keyboardShortcut != nil }
        if !costly.isEmpty {
            let names = costly.map { "\u{201C}\($0.name)\u{201D}" }.joined(separator: ", ")
            summary += " Discarding keeps them; saving also drops the app assignments on \(names)."
        }

        return summary
    }

    // MARK: - Keys

    /// One pair of monitors for the whole session, so shortcuts do not depend on
    /// which overlay happens to be key.
    ///
    /// The local monitor handles the normal case. The global one exists because
    /// the overlays sit above everything: if the user switches away with Cmd Tab
    /// the overlays stay on screen but stop receiving events, and without a
    /// global Escape there would be no way back. Global monitors cannot consume
    /// events, which is fine for Escape.
    private func startKeyMonitor() {
        stopKeyMonitor()

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen else { return event }
            return self.handle(event) ? nil : event
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen, event.keyCode == 53 else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.requestClose()
        }
    }

    private func stopKeyMonitor() {
        for monitor in [localKeyMonitor, globalKeyMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        localKeyMonitor = nil
        globalKeyMonitor = nil
    }

    // MARK: - Display changes

    /// A session is pinned to the displays it opened on. If the arrangement
    /// changes underneath it, every resolved rectangle is stale, so the session
    /// ends rather than writing geometry derived from displays that have moved.
    private func startDisplayChangeObserver() {
        stopDisplayChangeObserver()

        openingDisplayBounds = Dictionary(
            uniqueKeysWithValues: DisplayRegistry.shared.displays.map { ($0.key, $0.axBounds) })

        displayChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isOpen else { return }

                // The notification fires for things that do not move a display,
                // such as the Dock changing size or the menu bar being hidden.
                // Only the displays actually moving invalidates the session, and
                // CGDisplayBounds is unaffected by either of those.
                DisplayRegistry.shared.refresh()
                let current = Dictionary(
                    uniqueKeysWithValues: DisplayRegistry.shared.displays.map { ($0.key, $0.axBounds) })
                guard current != self.openingDisplayBounds else { return }

                log("Layout editor: display configuration changed, closing without saving")
                self.close(saving: false)

                let alert = NSAlert()
                alert.messageText = "Layout editor closed"
                alert.informativeText = "The display arrangement changed while you were editing, "
                    + "so the layout was left as it was. Reopen the editor to continue."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    private func stopDisplayChangeObserver() {
        if let displayChangeObserver {
            NotificationCenter.default.removeObserver(displayChangeObserver)
        }
        displayChangeObserver = nil
        openingDisplayBounds = [:]
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == 53 { // Escape
            requestClose()
            return true
        }

        if modifiers == [.command], event.charactersIgnoringModifiers == "z" {
            undo()
            return true
        }

        if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z" {
            redo()
            return true
        }

        return false
    }

    // MARK: - Refusal

    /// Profile displays with no counterpart attached, described for a human.
    private func missingDisplayDescriptions(in profile: Profile, live: DisplayTopology) -> [String] {
        var available = live.displays

        // Consume exact identity matches first so the leftovers are the ones
        // genuinely absent rather than ones a weaker rule happened to claim.
        var unmatched: [DisplayTopology.DisplayInfo] = []
        for stored in profile.displayTopology.displays {
            if let key = stored.key,
               !DisplayIdentity.isLegacy(key),
               let index = available.firstIndex(where: { $0.key == key }) {
                available.remove(at: index)
            } else {
                unmatched.append(stored)
            }
        }

        var missing: [String] = []
        for stored in unmatched {
            if let index = available.firstIndex(where: {
                $0.isBuiltIn == stored.isBuiltIn && $0.resolution == stored.resolution
            }) {
                available.remove(at: index)
            } else {
                let kind = stored.isBuiltIn ? "built-in" : "external"
                let size = "\(Int(stored.resolution.width))x\(Int(stored.resolution.height))"
                missing.append(stored.name.map { "\($0) (\(size))" } ?? "\(size) \(kind)")
            }
        }
        return missing
    }

    /// Human-readable text for a refusal, for the caller to present.
    static func refusalMessage(for reason: RefusalReason, profileName: String) -> (title: String, body: String) {
        switch reason {
        case .profileHasNoDisplays:
            return (
                "Can\u{2019}t open the layout editor for \u{201C}\(profileName)\u{201D}",
                "This profile has no displays recorded yet. Use Capture Current Displays first."
            )
        case .displaysMissing(let displays):
            let list = displays.isEmpty ? "a display it needs" : displays.joined(separator: "\n")
            return (
                "Can\u{2019}t open the layout editor for \u{201C}\(profileName)\u{201D}",
                "This profile needs a display that isn\u{2019}t connected:\n\n\(list)\n\n"
                    + "Connect it and try again, or use Capture Current Displays to point this "
                    + "profile at the displays you have."
            )
        }
    }
}
