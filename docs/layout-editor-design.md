# Layout editor design

Status: agreed, not yet implemented.
Branch: `feature/layout-editor`.

A full screen editor for arranging a profile's regions directly on the displays they apply to, replacing the `RegionEditorDialog` form and the `RegionOverlay` drag surface once it is complete. Both of those stay in place and untouched during development.

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

Array order in `Profile.regions` is the z-order, last is topmost. `Bring to Front` and `Send to Back` reorder the array. No schema change, and runtime behaviour is unaffected because regions are addressed by keyboard shortcut and bundle identifier, never by point.

## Gutter

Per region `padding` is removed in favour of a single `GlobalSettings.windowGap`, applied in `RegionGeometry.contentAXFrame` at placement time and never stored in the geometry.

This is deliberate rather than cosmetic. Baking a 3 point inset into each rectangle moves `Center`'s right edge from 3414 to 3411 and `Right`'s left edge from 3414 to 3417. They stop touching, and all six exactly shared edges in the configuration become zero, so the linked handle never appears again. Keeping the gutter out of the geometry keeps the edges coincident and the affordance alive.

The gap applies to every region uniformly. The existing per region values do not encode a rule worth preserving: `3` appears twelve times, `0` five times across both focus and non focus regions, and `5` once on a region that is `0` in a sibling profile.

## Safety

Every region shows a badge with what it carries, for example `4 apps, Ctrl Cmd C`, so a delete never silently discards assignments. Undo and redo cover every action. `Esc` prompts and names what would be lost.

## Migration

`v2` to `v3`, on load, with a backup written alongside as the v1 migration does. Drop `Region.padding`, add `GlobalSettings.windowGap` defaulting to `3`. Geometry is untouched.

Four regions change by a few points as a result: the three focus regions and the two `MacBook - Fullscreen` regions that had `0` gain a 3 point inset, and Ultrawide's `MacBook - Fullscreen` loses 2.

## Out of scope for the first version

Snapping while dragging. `Snap Edge` covers creating shared edges deliberately, so drag snapping is a convenience that can follow.

Auto tidying existing layouts on open. The 25 point gap between `Left Top` and `Left Bottom` is left exactly as it is, and gaps are marked but never closed automatically.

`Fill Display`, which was considered and dropped as rarely useful.

## Reference

`layout-editor-mock.html` in this directory is the agreed visual mock: multi display layout, the context menu and its submenus, the gutter arrangement, and the save and refusal dialogs.
