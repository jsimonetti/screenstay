# Layout editor design

Status: agreed, not yet implemented.
Branch: `feature/layout-editor`.

A full screen editor for arranging a profile's regions directly on the displays they apply to.

The `RegionEditorDialog` form on the Regions tab stays. It was meant to be retired once the editor was complete, and functionally it now is, but the two are not interchangeable: the form edits `profile.displayTopology`, the topology as stored, so it works for any profile whatever is plugged in, while the editor deliberately refuses when the profile's displays are absent. Removing the form would leave a profile uneditable away from its hardware. The editor is the primary way to arrange a layout; the form is the fallback for a profile you cannot currently see.

Giving the editor a scaled schematic mode for absent displays would make the form genuinely redundant. Until then it is not.

## Why not a divider model

The obvious design, and the one in the reference app this borrows its look from, partitions the screen: every pixel belongs to exactly one region, regions share edges, and dragging a divider resizes both neighbours.

That model cannot represent the existing data. Counting overlapping region pairs in the live configuration:

| Profile | Regions | Overlapping pairs |
| --- | --- | --- |
| Ultrawide Thuis | 6 | 1 |
| ON2IT Dell 1 | 6 | 5 |
| Laptop only | 5 | 10 (every possible pair) |
| AppleTV | 1 | 0 |

`Center` and `Focus` overlap by 2.77 M pixels. In `Laptop only`, `Center`, `Right` and `MacBook - Fullscreen` are three identical full screen rectangles stacked on each other. A partition model would destroy all of it on first open.

So the stored model stays exactly what it is today: a flat list of independent rectangles, any number of which may overlap. The divider affordance is reproduced as a *derived* one. When two region edges are already coincident the editor draws a single handle that drives both, and when an edge has no neighbour it draws a dimmer handle that moves only that region. The visual language survives without the constraint.

## Interaction model

Continuous manipulation stays on the pointer. Discrete actions live in the context menu. Nothing is bound to a modifier plus click.

| Gesture | Action |
| --- | --- |
| Drag inside a region | Move it |
| Drag an edge or handle | Resize. A linked edge moves both regions, a lone edge moves one |
| Drag on empty space | Draw a new region |
| Right click | Context menu |
| `Cmd Z` / `Shift Cmd Z` | Undo / redo |
| `Esc` | Prompt to save or discard |

Modifier plus click was rejected for three reasons. Control click is the system standard contextual menu gesture on macOS, so the reference app's `Ctrl + left click` collides with the platform and with any `NSMenu` attached to the view. Overlapping regions make "the region under the pointer" ambiguous, and a menu can offer a disambiguation list where a chord cannot. Layout editing is a rare, deliberate task, so discoverability matters more than speed.

## Context menu

The header always names the region the menu will act on, which matters when regions stack.

```
Focus                          2040 x 1360
------------------------------------------
Select Region                            >
------------------------------------------
New Region Here                  600 x 400
Split into Columns             1020 | 1020
Split into Rows                  680 | 680
------------------------------------------
Snap Edge                                >
------------------------------------------
Rename...
Assign Apps...                           0
Assign Shortcut...                    none
[x] Focus Region
------------------------------------------
Bring to Front                already front
Send to Back
------------------------------------------
Delete Region
```

`New Region Here` appears in every menu, over a region or not, and creates a region at the pointer. Over empty space the menu collapses to `New Region Here` and `Paste Region`.

`Select Region` lists every region under the pointer, topmost first, so a region buried under a full screen one stays reachable.

`Snap Edge` offers `Left`, `Right`, `Top` and `Bottom`, each extending or pulling that one edge until it meets the nearest region edge or the display edge. This is the deliberate way to create the coincident edges that linked handles depend on.

Splits are always 50/50 on the named axis. The labels are `Split into Columns` and `Split into Rows` rather than horizontal and vertical, which are ambiguous about whether they name the cut or the result. The top left half keeps the id, name, assigned apps, keyboard shortcut and focus flag. The other half is a new region with an auto generated name and nothing assigned.

## Displays

The editor opens one borderless overlay per display in the profile, all live at once, sharing a single undo stack and one key event monitor so `Esc` and `Cmd Z` work regardless of which display the pointer is over.

Regions are stored per display, so dragging one across a boundary re-keys it through `RegionGeometry.rebase`. Displays are not necessarily contiguous, and a shorter display leaves addressable space beside it that belongs to no display. A region dropped there snaps back to the display it came from.

The editor requires the profile's displays to be attached. It opens when `Profile.match(against:)` returns any successful match, not only an exact identity match, otherwise a profile whose `legacy:` keys have never been bound would be uneditable. When there is no match it refuses and names the displays that are missing.

## Z-order

Regions nest constantly, so neither hit testing nor painting follows array order.

The smallest region under the pointer wins a click. Plain topmost-first makes everything unreachable the moment a full-screen region exists: in `Laptop only` every point on the display is inside all five regions, three of which are full-screen, so every click landed on the same one. The smaller region is the more specific target and is what you were pointing at. Equal areas fall back to array order, last first, so genuinely stacked duplicates still resolve topmost first.

Painting is the inverse: largest first, so a small region nested inside a big one stays visible rather than being covered by it. What is drawn on top is what a click will reach. The selection outline is stroked again after everything else, since the selected region's own pass may sit underneath a smaller one.

There is deliberately no way to reorder from the editor. `Bring to Front` and `Send to Back` existed briefly and were removed: `Select Region` already reaches a region buried under another, which was their only real use, and reordering is not as free as it looks. `EventCoordinator` picks a region for a launching app with `regions.first(where:)`, so if an app is ever assigned to two regions the array order silently decides which one wins. Exposing that as a cosmetic editor action invites changing runtime behaviour by accident. If duplicate assignments become a problem the answer is to warn about them, not to hand out z-order controls.

## Gutter

Per region `padding` is removed in favour of a single `GlobalSettings.windowGap`, applied in `RegionGeometry.contentAXFrame` at placement time and never stored in the geometry.

This is deliberate rather than cosmetic. Baking a 3 point inset into each rectangle moves `Center`'s right edge from 3414 to 3411 and `Right`'s left edge from 3414 to 3417. They stop touching, and all six exactly shared edges in the configuration become zero, so the linked handle never appears again. Keeping the gutter out of the geometry keeps the edges coincident and the affordance alive.

The gap applies to every region uniformly. The existing per region values do not encode a rule worth preserving: `3` appears twelve times, `0` five times across both focus and non focus regions, and `5` once on a region that is `0` in a sibling profile.

## The menu bar

macOS will not let a window sit under the menu bar, so part of a display is not placeable. The editor hides the menu bar while it is open, which would otherwise make that strip look available when it is not.

`RegionGeometry.contentAXFrame` intersects the resolved frame with the display minus the menu bar, before applying the gutter. Intersecting matters: macOS constrains only a window's *origin*, so a region starting at the top of a display gets pushed down while keeping its height and its bottom edge ends up past the end of the display. Intersecting shortens it instead. Clamping runs before the gutter so the window sits a gutter's width below the menu bar rather than flush against it.

The clamp is to the menu bar only, not to `visibleFrame`. That also excludes the Dock, but macOS does not enforce the Dock: windows may sit under it and it floats above them. Clamping to it would shrink windows further than the system does, and would resize every bottom-edge window the day the Dock stops auto-hiding.

The editor draws the reserved strip hatched, over the regions rather than under them, since a region may be authored to overlap it and the point is to show what will be cut away. The measurement comes from the display as captured when the session opened; reading it live reports nothing, because hiding the menu bar grows every screen's `visibleFrame`.

`Snap Edge` offers the placeable edge as a candidate, so stored geometry can be made to match where a window actually lands.

## Safety

Every region shows a badge with what it carries, for example `4 apps, Ctrl Cmd C`, so a delete never silently discards assignments. Undo and redo cover every action. `Esc` prompts and names what would be lost.

## Migration

`v2` to `v3`, on load, with a backup written alongside as the v1 migration does. The backup is named after the version it came from, so a later migration cannot overwrite an earlier snapshot. Drop `Region.padding`, add `GlobalSettings.windowGap`. Geometry is untouched.

The new gap is whichever padding value the configuration used most often, so the common case keeps the spacing it had, falling back to `3` when there is nothing to infer from.

Six regions change by a few points as a result. The three focus regions and the three `MacBook - Fullscreen` regions that had `0` gain a 3 point inset, except Ultrawide's `MacBook - Fullscreen`, which had `5` and loses 2.

## Testing

Region geometry, matching, migration and the editor's own operations are pure functions and are covered by harnesses under the session scratch directory.

Anything touching the Accessibility API is not, unless it runs from `make test-ax`. A plain command line binary is never a trusted Accessibility client, so AX calls from one return nothing and a test written against them passes or fails for reasons that have nothing to do with the code. `Tests/AXHarness` is built and signed as an app bundle with a stable identifier so the permission can be granted once and kept.

## Out of scope for the first version

Snapping while dragging. `Snap Edge` covers creating shared edges deliberately, so drag snapping is a convenience that can follow.

Auto tidying existing layouts on open. The 25 point gap between `Left Top` and `Left Bottom` is left exactly as it is, and gaps are marked but never closed automatically.

`Fill Display`, which was considered and dropped as rarely useful.

## Reference

`layout-editor-mock.html` in this directory is the agreed visual mock: multi display layout, the context menu and its submenus, the gutter arrangement, and the save and refusal dialogs.
