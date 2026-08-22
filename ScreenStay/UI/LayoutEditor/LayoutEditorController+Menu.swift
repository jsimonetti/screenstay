import AppKit

/// Context menu construction and the edits it drives.
///
/// Every discrete action lives here. Moving, resizing and drawing stay on the
/// pointer, so they are deliberately absent.
@MainActor
extension LayoutEditorController {

    // MARK: - Presenting

    func showContextMenu(
        atRelative point: CGPoint,
        on display: DisplayRegistry.ResolvedDisplay,
        event: NSEvent,
        in view: LayoutEditorCanvasView
    ) {
        let hits = regions(under: point, on: display)
        let menu = hits.isEmpty
            ? emptySpaceMenu(at: point, on: display)
            : regionMenu(for: hits[0], alsoUnderPointer: hits, at: point, on: display)

        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    /// Regions containing a display-relative point, most specific first.
    ///
    /// Smallest area wins rather than topmost. Regions nest constantly - a
    /// profile may hold several full-screen regions stacked over smaller ones -
    /// and with plain topmost-first every click on the display lands on
    /// whichever full-screen region happens to be last in the array, leaving
    /// everything else unreachable. The smaller region is the more specific
    /// target, and matches what you were pointing at.
    ///
    /// Equal areas fall back to array order, last first, so genuinely stacked
    /// duplicates still resolve topmost first.
    func regions(under point: CGPoint, on display: DisplayRegistry.ResolvedDisplay) -> [Region] {
        currentRegions.enumerated()
            .filter { $0.element.displayKey == display.key && $0.element.relativeFrame.contains(point) }
            .sorted { lhs, rhs in
                let lhsArea = lhs.element.relativeFrame.width * lhs.element.relativeFrame.height
                let rhsArea = rhs.element.relativeFrame.width * rhs.element.relativeFrame.height
                if lhsArea != rhsArea { return lhsArea < rhsArea }
                return lhs.offset > rhs.offset
            }
            .map(\.element)
    }

    // MARK: - Menus

    private func regionMenu(
        for region: Region,
        alsoUnderPointer hits: [Region],
        at point: CGPoint,
        on display: DisplayRegistry.ResolvedDisplay
    ) -> NSMenu {
        let menu = NSMenu()
        let frame = region.relativeFrame

        menu.addItem(header("\(region.name)   \(Int(frame.width)) x \(Int(frame.height))"))
        menu.addItem(.separator())

        // Only worth offering when something is actually stacked here.
        if hits.count > 1 {
            let selectItem = NSMenuItem(title: "Select Region", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for (index, candidate) in hits.enumerated() {
                let detail = index == 0 ? "top" : "\(candidate.assignedApps.count) apps"
                let entry = menuItem(
                    "\(candidate.name)   \(detail)",
                    enabled: index != 0
                ) { [weak self] in
                    self?.showMenu(for: candidate, at: point, on: display)
                }
                entry.state = index == 0 ? .on : .off
                submenu.addItem(entry)
            }
            selectItem.submenu = submenu
            menu.addItem(selectItem)
            menu.addItem(.separator())
        }

        menu.addItem(menuItem("New Region Here   \(Int(LayoutEditorOperations.newRegionSize.width)) x "
                          + "\(Int(LayoutEditorOperations.newRegionSize.height))") { [weak self] in
            self?.addRegion(centredAt: point, on: display)
        })

        for (axis, title) in [(LayoutEditorOperations.SplitAxis.columns, "Split into Columns"),
                              (LayoutEditorOperations.SplitAxis.rows, "Split into Rows")] {
            let canSplit = LayoutEditorOperations.canSplit(region, into: axis)
            let halves: String
            if canSplit {
                let whole = axis == .columns ? frame.width : frame.height
                let first = (whole / 2).rounded(.down)
                halves = "\(Int(first)) | \(Int(whole - first))"
            } else {
                halves = "too small"
            }
            menu.addItem(menuItem("\(title)   \(halves)", enabled: canSplit) { [weak self] in
                self?.split(region, into: axis)
            })
        }

        menu.addItem(.separator())
        menu.addItem(snapMenu(for: region, on: display))
        menu.addItem(.separator())

        menu.addItem(menuItem("Rename\u{2026}") { [weak self] in self?.rename(region) })

        let appCount = region.assignedApps.count
        menu.addItem(menuItem("Assign Apps\u{2026}   \(appCount == 1 ? "1 app" : "\(appCount) apps")") {
            [weak self] in self?.editApps(of: region)
        })

        let shortcutText = region.keyboardShortcut.map { shortcut in
            shortcut.modifiers.map(Self.symbol(for:)).joined() + shortcut.key.uppercased()
        } ?? "none"
        menu.addItem(menuItem("Assign Shortcut\u{2026}   \(shortcutText)") {
            [weak self] in self?.editShortcut(of: region)
        })

        let focus = menuItem("Focus Region") { [weak self] in self?.toggleFocus(region) }
        focus.state = region.isFocusRegion ? .on : .off
        menu.addItem(focus)

        menu.addItem(.separator())
        menu.addItem(menuItem("Delete Region") { [weak self] in self?.delete(region) })

        return menu
    }

    private func emptySpaceMenu(at point: CGPoint, on display: DisplayRegistry.ResolvedDisplay) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(header("No region   at \(Int(point.x)), \(Int(point.y))"))
        menu.addItem(.separator())
        menu.addItem(menuItem("New Region Here   \(Int(LayoutEditorOperations.newRegionSize.width)) x "
                          + "\(Int(LayoutEditorOperations.newRegionSize.height))") { [weak self] in
            self?.addRegion(centredAt: point, on: display)
        })
        return menu
    }

    private func snapMenu(for region: Region, on display: DisplayRegistry.ResolvedDisplay) -> NSMenuItem {
        let parent = NSMenuItem(title: "Snap Edge", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let edges: [(LayoutEditorOperations.Edge, String)] = [
            (.left, "Left"), (.right, "Right"), (.top, "Top"), (.bottom, "Bottom")
        ]
        let others = currentRegions
        for (edge, title) in edges {
            let target = LayoutEditorOperations.snapTarget(region, edge: edge, against: others, on: display)
            let detail = target.map { "to \(Int($0))" } ?? "nothing to snap to"
            submenu.addItem(menuItem("\(title)   \(detail)", enabled: target != nil) { [weak self] in
                self?.snap(region, edge: edge, on: display)
            })
        }

        parent.submenu = submenu
        return parent
    }

    /// Reopen the menu targeting a different region in the stack.
    private func showMenu(for region: Region, at point: CGPoint, on display: DisplayRegistry.ResolvedDisplay) {
        let hits = regions(under: point, on: display)
        let reordered = [region] + hits.filter { $0.id != region.id }
        let menu = regionMenu(for: region, alsoUnderPointer: reordered, at: point, on: display)
        if let view = canvas(for: display) {
            let viewPoint = CoordinateSpace.axToCocoa(
                CGRect(origin: CGPoint(x: display.axBounds.minX + point.x,
                                       y: display.axBounds.minY + point.y), size: .zero)
            ).origin
            let displayOrigin = CoordinateSpace.axToCocoa(display.axBounds).origin
            menu.popUp(positioning: nil,
                       at: CGPoint(x: viewPoint.x - displayOrigin.x, y: viewPoint.y - displayOrigin.y),
                       in: view)
        }
    }

    // MARK: - Edits

    private func addRegion(centredAt point: CGPoint, on display: DisplayRegistry.ResolvedDisplay) {
        mutate("added a region") { regions in
            let region = LayoutEditorOperations.newRegion(
                centredAtRelative: point, on: display, existingNames: regions.map(\.name))
            regions.append(region)
        }
    }

    private func split(_ region: Region, into axis: LayoutEditorOperations.SplitAxis) {
        mutate("split \(region.name)") { regions in
            guard let index = regions.firstIndex(where: { $0.id == region.id }),
                  let result = LayoutEditorOperations.split(
                    region, into: axis, existingNames: regions.map(\.name)) else { return }
            regions[index] = result.kept
            regions.insert(result.added, at: index + 1)
        }
    }

    private func snap(_ region: Region, edge: LayoutEditorOperations.Edge,
                      on display: DisplayRegistry.ResolvedDisplay) {
        mutate("snapped \(region.name)") { regions in
            guard let index = regions.firstIndex(where: { $0.id == region.id }),
                  let moved = LayoutEditorOperations.snap(
                    region, edge: edge, against: regions, on: display) else { return }
            regions[index] = moved
        }
    }

    private func delete(_ region: Region) {
        mutate("deleted \(region.name)") { regions in
            regions.removeAll { $0.id == region.id }
        }
    }

    private func toggleFocus(_ region: Region) {
        mutate("changed the focus region") { regions in
            guard let index = regions.firstIndex(where: { $0.id == region.id }) else { return }
            let becomingFocus = !regions[index].isFocusRegion
            // A profile has at most one focus region.
            for other in regions.indices {
                regions[other].isFocusRegion = false
            }
            regions[index].isFocusRegion = becomingFocus
        }
    }

    private func editApps(of region: Region) {
        guard let updated = runModal({ LayoutEditorAssignmentSheets.editApps(for: region) }),
              updated != region.assignedApps else {
            return
        }

        mutate("changed the apps in \(region.name)") { regions in
            guard let index = regions.firstIndex(where: { $0.id == region.id }) else { return }
            regions[index].assignedApps = updated
        }
    }

    private func editShortcut(of region: Region) {
        // Everything already spoken for, so a clash can be pointed out. The two
        // global shortcuts count as well: a region shortcut that duplicates one
        // of them is swallowed before it ever reaches the region.
        var taken: [(shortcut: KeyboardShortcut, owner: String)] = currentRegions
            .filter { $0.id != region.id }
            .compactMap { other in
                other.keyboardShortcut.map { ($0, "region \u{201C}\(other.name)\u{201D}") }
            }
        for (shortcut, name) in globalShortcuts {
            taken.append((shortcut, name))
        }

        guard let choice = runModal({
            LayoutEditorAssignmentSheets.editShortcut(for: region, taken: taken)
        }) else {
            return
        }

        let updated = choice
        guard updated?.key != region.keyboardShortcut?.key
                || updated?.modifiers != region.keyboardShortcut?.modifiers else {
            return
        }

        mutate("changed the shortcut for \(region.name)") { regions in
            guard let index = regions.firstIndex(where: { $0.id == region.id }) else { return }
            regions[index].keyboardShortcut = updated
        }
    }

    private func rename(_ region: Region) {
        let alert = NSAlert()
        alert.messageText = "Rename region"
        alert.informativeText = "Give \u{201C}\(region.name)\u{201D} a new name."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = region.name
        alert.accessoryView = field

        let response = runModal { alert.runModal() }
        guard response == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != region.name else { return }

        mutate("renamed \(region.name) to \(name)") { regions in
            guard let index = regions.firstIndex(where: { $0.id == region.id }) else { return }
            regions[index].name = name
        }
    }

    // MARK: - Menu building helpers

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func menuItem(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: enabled ? #selector(ActionTarget.fire) : nil,
                              keyEquivalent: "")
        if enabled {
            let target = ActionTarget(action)
            item.target = target
            item.representedObject = target // keep the target alive as long as the menu
        }
        item.isEnabled = enabled
        return item
    }

    static func symbol(for modifier: String) -> String {
        switch modifier {
        case "control": return "\u{2303}"
        case "option": return "\u{2325}"
        case "shift": return "\u{21E7}"
        case "cmd": return "\u{2318}"
        default: return ""
        }
    }
}

/// Menu items need an Objective-C target; closures cannot be selectors.
@MainActor
private final class ActionTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}
