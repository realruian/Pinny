# Unified screenshot, long screenshot, recording, and pin workflow

The primary screenshot shortcut (`F1`) opens an inline capture session across all connected displays. Within that session you can pick a detected UI element or window, drag a custom region, select the full display, annotate in place, capture a scrolling long screenshot, or record the selected region and play it back in place. Legacy capture entry points route to this flow, and retired global shortcuts are cleared so they cannot reclaim keys on reset or import.

## Selection, detection & cursor rules

- Moving the pointer highlights the accessibility element reported under the cursor (`AXUIElement`, queried off the main thread with a `0.5 s` timeout).
- Scroll up/down to move to parent/child elements (`⌘` + scroll zooms the magnifier).
- Dark capsule shortcut chips in the top-left corner (`82%` dark background, concentric key caps) show quick actions: `⌘A` full display, `Tab` whole window under pointer (fetches window list on demand), `R` last capture region (`,` cycles recent regions).
- Once a region is chosen, drag empty content to move the selection or drag any edge/corner to resize. Annotations keep their size while resizing, and left/top edge resizes shift undo history accordingly.
- Edges snap within `6 pt` to screen bounds, screen centerlines, visible windows, and detected elements (hold `⌘` to suspend snapping).
- The overlay panel enforces a single cursor rule on every mouse move: crosshair before selection, system edge/diagonal resize cursors (`NSCursor.frameResize` on macOS 15+) on selection borders and corners, open/closed hand on empty selection content (or when holding `Space`), crosshair for drawing tools, pointing/open hand on annotation edges, and standard arrow outside the selection and over toolbars.

## Dual-capsule toolbar & inline annotation

- **Option C Dual-Capsule Layout**:
  - The main toolbar (`48 pt` high capsule, `36 pt` round buttons, `20 pt` icons) sits below the selection by default (or above when bottom space is tight) and uses native Liquid Glass (`.glassEffect(.regular)`) on macOS 26+. Buttons are organized into 4 groups separated by hairline dividers: annotation tools / undo-redo / long screenshot & record / copy-pin-save-close.
  - The secondary properties bar is an independent `40 pt` capsule placed `8 pt` below the main toolbar, left-aligned and sized to its content, with `28 pt` controls and the `More` button pinned outside the scroll region. Popovers open downward below the secondary bar, and pressing `⎋` while a popover is open closes only the top popover (`InlineAreaPopoverStack`).
- **Tools & PixPin-style interaction**:
  - Tools are grouped into Shapes (rectangle, filled rectangle, oval) and Lines (arrow, line) with secondary-bar switching, alongside pencil, highlighter, text (`PingFang SC`), blur (pixelate / Gaussian with live preview and lighter minimum intensity), spotlight (with dim slider), counter, and watermark.
  - Tool letter shortcuts work immediately without clicking the canvas first.
  - **Direct edge drag with drawing tools**: pressing on any annotation's edge while a drawing tool is active grabs and moves that annotation immediately (including the item just drawn); clicking an edge selects it; dragging inside a shape draws a new item (hold `⌥` to draw over an edge).
  - **Per-tool parameter memory (`toolParameterDefaults.v2`)**: only outline tools share color and stroke width; blur, counter, highlighter, watermark, and spotlight keep independent defaults; rectangles default to square (`0` corner radius) and text to `6`; adjusting the item just drawn updates that tool's default; switching text to label/callout with a clear background automatically fills the background with the text color and sets black/white contrasting text.

## Scrolling capture (long screenshot)

- Clicking the scrolling capture button (`CarouselVertical`) starts a frame-paced long screenshot directly from the current selection with a live stitched preview on the right:
  - Matches vertical scroll per frame (confidence threshold `0.75`) with 3-screen tail relocalization and automatic tail trimming on reverse scroll.
  - Deduplicates top and bottom fixed headers/bars so they appear once, and preserves manual top crops as fixed rows.
  - Keeps a resident toolbar anchored below the selection with pixel dimensions, top/bottom crop (`Crop`), copy, pin, save, and close.

## In-place screen recording & playback

- Clicking the record button (`Video01`) swaps the main toolbar for a recording prep bar (pixel dimensions, system audio toggle, microphone toggle, red capsule `Start Recording` button, and close) while the selection remains movable and resizable (`↩` starts, `⎋` returns to the capture toolbar).
- During recording, a red frame surrounds the selection and a compact bar shows elapsed time (`0:12`), pause/resume, and stop (`F1` or the menu bar icon also stops). Neither the frame nor the bar appears in the recorded video.
- When stopped, the recorded MP4 loops in place at the exact selection frame with a playback bar offering play/pause, scrubber, `MP4 / GIF` capsule switch, Record Again, Copy (`↩` / `⌘C`), Save (`⌘S`), and Close (`⎋`).
- GIF conversion is streamed on demand only when copying or saving with `GIF` selected.
- Clicking **Record Again** hides the playback window and opens the prep bar with a dedicated **Back** (`ArrowLeft02`) button on the left: pressing `⎋` or clicking Back restores the previous recording, whereas starting a new recording discards the old one. Closing an unexported recording prompts for confirmation first.

## Output & pinning (`F2`)

- **Copy** (`↩`, `⌘C`, or double-click empty image content): hides the overlay immediately and encodes the original-resolution image on a background queue (latest copy wins, without bloated TIFF representations), writing source screen geometry to the pasteboard item.
- **Save** (`⌘S`): saves to `~/Downloads/Pinny` (`Pinny_` prefix; falls back to clipboard with a notification if saving fails, and avoids folders located in the Trash).
- **Pin**: creates a borderless, square-cornered floating image window directly from memory at the selection's screen frame (for long screenshots, top-left aligned and scaled down if taller than the display).
- **Pin Clipboard Image (`F2`)**: reads image data or copied image file URLs from the clipboard (skipping non-image files and notifying when no image is available) and opens a pin window. Clipboard items carrying Pinny source geometry restore their original screen position and logical size; external images open centered at natural logical size (scaled down only if larger than the display).
- **Pin interaction**: drag anywhere to move (including across the menu bar onto a display stacked above), scroll to scale smoothly around the pointer, double-click to copy original-resolution content (preserving current geometry) and close that pin, or press `⎋` to close only the focused pin (ignoring `⎋` pressed in other apps).
