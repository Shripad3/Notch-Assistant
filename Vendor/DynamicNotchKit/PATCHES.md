# Vendored DynamicNotchKit

Upstream: https://github.com/MrKai77/DynamicNotchKit at 1.1.0
(`cd0b3e52d537db115ad3a9d89601f20e0bee8d27`), MIT — see LICENSE.

Vendored rather than depended on because upstream's placement logic conflicts
with spec §5. Changes:

1. **Removed `observeScreenParameters()`.** Upstream rebuilt the window on
   `NSScreen.screens.first` on every display change, which is the external
   monitor whenever it is the main display, with no debounce, and even while
   hidden. `DisplayResolver` now owns placement.
2. **No default screen.** `expand(on:)` and `compact(on:)` no longer default
   to `NSScreen.screens[0]`; the caller always names the screen.
3. **Added `reposition(on:)`** to move the window in place after a
   reconfiguration instead of recreating it (spec §5 "reposition, don't
   recreate"). Window frame math factored into `panelFrame(on:)` for this.
4. **`.fullScreenAuxiliary`** added to the panel's collection behaviour.
5. Removed `DynamicNotchInfo` (unused, and it relied on the default screen)
   and the DocC catalogue.

Everything else is upstream as-is. Patched lines are marked `PATCH (Notch Assistant)`.
