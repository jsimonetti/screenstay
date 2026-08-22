import AppKit

/// Pointer handling: selection, moving a region, and dragging an edge.
///
/// Everything continuous lives here. The context menu covers the discrete
/// actions, and the two never overlap.
@MainActor
extension LayoutEditorController {

    /// What the pointer is currently doing.
    enum Drag {
        /// Sliding a whole region, remembering where inside it the grab landed.
        case move(regionID: String, grabOffset: CGSize)
        /// Dragging one edge, carrying any linked neighbours with it.
        case resize(handle: LayoutEditorOperations.Handle)
    }

    // MARK: - Press

    func handleMouseDown(atRelative point: CGPoint, on display: DisplayRegistry.ResolvedDisplay) {
        // Handles win over regions: they sit on the boundary, where a region is
        // also hit, and the smaller target is the more deliberate one.
        if let handle = handle(under: point, on: display) {
            beginDrag(.resize(handle: handle))
            return
        }

        guard let region = regions(under: point, on: display).first else {
            select(nil)
            return
        }

        select(region.id)
        beginDrag(.move(
            regionID: region.id,
            grabOffset: CGSize(width: point.x - region.relativeFrame.minX,
                               height: point.y - region.relativeFrame.minY)
        ))
    }

    func handleMouseDragged(atRelative point: CGPoint, on display: DisplayRegistry.ResolvedDisplay) {
        guard let drag = activeDrag else { return }

        switch drag {
        case .move(let regionID, let grabOffset):
            updateLive { regions in
                guard let index = regions.firstIndex(where: { $0.id == regionID }) else { return }
                regions[index] = LayoutEditorOperations.move(
                    regions[index],
                    toRelativeOrigin: CGPoint(x: point.x - grabOffset.width,
                                              y: point.y - grabOffset.height),
                    on: display
                )
            }

        case .resize(let handle):
            let value = handle.isHorizontalEdge ? point.y : point.x
            updateLive { regions in
                regions = LayoutEditorOperations.resize(
                    regions, handle: handle, toRelative: value, on: display)
            }
        }

        refreshHandles()
    }

    func handleMouseUp(atRelative point: CGPoint, on display: DisplayRegistry.ResolvedDisplay) {
        endDrag()
        refreshHandles()
    }

    // MARK: - Selection

    func select(_ regionID: String?) {
        guard selectedRegionID != regionID else { return }
        selectedRegionID = regionID
        refreshSelection()
        refreshHandles()
    }

    /// Push the current selection and its handles out to every overlay.
    func refreshSelection() {
        for overlay in overlays {
            overlay.canvas.selectedRegionID = selectedRegionID
        }
    }

    func refreshHandles() {
        guard let selectedRegionID,
              let region = currentRegions.first(where: { $0.id == selectedRegionID }) else {
            for overlay in overlays {
                overlay.canvas.handles = []
            }
            return
        }

        let handles = LayoutEditorOperations.handles(for: region, among: currentRegions)
        for overlay in overlays {
            // Handles belong to the display the selected region lives on.
            overlay.canvas.handles = overlay.display.key == region.displayKey ? handles : []
        }
    }

    // MARK: - Hit testing

    /// The handle under a point, if the pointer is close enough to grab one.
    func handle(under point: CGPoint, on display: DisplayRegistry.ResolvedDisplay) -> LayoutEditorOperations.Handle? {
        guard let selectedRegionID,
              let region = currentRegions.first(where: { $0.id == selectedRegionID }),
              region.displayKey == display.key else {
            return nil
        }

        let slop = LayoutEditorOperations.handleGrabSlop
        return LayoutEditorOperations.handles(for: region, among: currentRegions)
            .first { $0.rect.insetBy(dx: -slop, dy: -slop).contains(point) }
    }
}
