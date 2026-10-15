# Unified screenshot and pin workflow

The primary screenshot shortcut (`F1`) opens a single inline capture session per display. Within that session you can pick a detected UI element or window, drag a custom region, or select the full display. Legacy capture entry points route to this flow, and retired global shortcuts are cleared so they cannot reclaim keys on reset or import.

## Selection & detection

- Moving the pointer highlights the accessibility element reported under the cursor (`AXUIElement`, queried off the main thread with a 0.5 s timeout).
- Scroll up/down to move to parent/child elements (`⌘` + scroll zooms the magnifier).
- Shortcut labels in the top-left corner show quick actions: `⌘A` full display, `Tab` whole window under pointer, `R` last capture region (`,` cycles recent regions).
- Once a region is chosen, drag empty content to move the selection or drag any edge/corner to resize. Edges snap within 6 pt to screen bounds, screen centerlines, visible windows, and detected elements (hold `⌘` to suspend snapping).

## Inline annotation & scrolling capture

- The toolbar sits below the selection by default (or above when bottom space is tight) and uses native Liquid Glass (`.glassEffect(.regular)`) on macOS 26+.
- Tools are grouped into Shapes (rectangle, filled rectangle, oval) and Lines (arrow, line) with secondary-bar switching, alongside pencil, highlighter, text (`PingFang SC`), blur (pixelate / Gaussian), spotlight, counter, and watermark.
- Clicking the scrolling capture button (`CarouselVertical`) starts a frame-paced long screenshot directly from the current selection:
  - Matches vertical scroll per frame with 3-screen tail relocalization and automatic tail trimming on reverse scroll.
  - Deduplicates top and bottom fixed headers/bars so they appear once.
  - Keeps the toolbar anchored below the selection with dimensions, top/bottom crop (`Crop`), copy, pin, save, and close.

## Output & pinning (`F2`)

- **Copy** (`↩`, `⌘C`, or double-click empty image content): hides the overlay immediately and encodes the original-resolution image on a background queue, writing source screen geometry to the pasteboard item.
- **Save** (`⌘S`): saves to `~/Downloads/Pinny` (`Pinny_` prefix).
- **Pin**: creates a borderless, square-cornered floating image window directly from memory at the selection's screen frame (for long screenshots, top-left aligned and scaled down if taller than the display).
- **Pin Clipboard Image (`F2`)**: reads image data or copied image file URLs from the clipboard and opens a pin window. Clipboard items carrying Pinny source geometry restore their original screen position and logical size; external images open centered at natural logical size (scaled down only if larger than the display).
- **Pin interaction**: drag anywhere to move (including across the menu bar onto a display stacked above), scroll to scale around the pointer, and double-click to copy original-resolution content and close that pin.
