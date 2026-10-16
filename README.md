<div align="center">
  <img src="./banner.png" width="128" height="128" alt="Pinny" />

  <h1>Pinny</h1>

  <p><a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a></p>

  <p><strong>In-place screenshot, scrolling capture, screen recording (MP4 / GIF), annotation, and pin-to-screen for macOS</strong></p>

  <p>
    <img src="https://img.shields.io/badge/macOS-13.0%2B%20(Liquid%20Glass%2026%2B)-1d1d1f?logo=apple&logoColor=white" alt="macOS 13.0+" />
    <img src="https://img.shields.io/badge/Arch-Apple%20Silicon%20(arm64)-0a7cff" alt="Apple Silicon" />
    <img src="https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white" alt="Swift" />
    <a href="./LICENSE"><img src="https://img.shields.io/badge/License-BSD%203--Clause-30d158" alt="BSD 3-Clause License" /></a>
  </p>

  <p>
    <a href="#features">Features</a> •
    <a href="#keyboard-shortcuts">Shortcuts</a> •
    <a href="#build--install">Build & Install</a> •
    <a href="#icon-generation">Icons</a> •
    <a href="#documentation">Docs</a>
  </p>

  <img src="./docs/assets/pinny-overview.svg" width="100%" alt="Pinny Interface & Workflow Overview" />
</div>

---

Pinny unifies region capture, UI element inspection, in-place annotation, frame-paced scrolling capture, in-place screen recording playback, and clipboard pinning into two global shortcuts: **`F1` Capture** and **`F2` Pin**. There is no upfront mode selector and no corner floating card—everything happens directly in place on the selected region.

## Features

### 1. In-Place Capture (`F1`)

- **Region Selection & UI Element Detection**
  - Press `F1` to open the capture overlay across all connected displays simultaneously (~85 ms warm start in Release builds) with seamless cross-display selection dragging.
  - Hover to automatically highlight UI elements under the cursor via macOS Accessibility (`AXUIElement`). All cross-process queries run off the main thread with a `0.5 s` timeout so the UI never freezes.
  - **Scroll Wheel Hierarchy Switching**: Scroll up or down with the mouse wheel or trackpad to step through parent and child UI elements; click to lock the highlighted element, or click-and-drag to draw a custom region.
  - **Top-Left Quick Pills**: Instant access to `Full Screen ⌘A`, `Whole Window Tab` (queries live window bounds on demand), and `Last Region R` (shown when history exists; press `,` to cycle recent regions).
- **Resizing, Edge Snapping & Unified Cursors**
  - Drag empty space inside the selection to pan it directly, or drag any edge/corner to resize. Existing annotations keep their size during resize, and undo history automatically tracks top/left origin shifts.
  - Edges snap within `6 pt` to screen bounds, screen centerlines, visible window edges, and inspected element bounds with subtle trackpad haptic feedback (hold `⌘` to suspend snapping).
  - **Unified Cursor Rules**: Crosshair before selection; standard arrow outside selection and over toolbars; native directional resize cursors (`NSCursor.frameResize` on macOS 15+) on edges and corners; open/closed hand on empty selection space under the Select tool; crosshair inside the canvas under drawing tools with pointing/move hand over annotation edges.

### 2. In-Place Annotation & Dual-Capsule Toolbar

- **Dual-Capsule Native Liquid Glass Chrome (Option C)**
  - Anchored below the selection by default (flips above when bottom space is tight). Uses native Liquid Glass (`.glassEffect(.regular)`) on macOS 26+ with custom non-activating hover tooltips (above the main bar, below the secondary bar).
  - **Main Bar (`48 pt` capsule)**: `36 pt` circular buttons with `20 pt` Hugeicons Pro icons (`Stroke Rounded` idle, `Solid Rounded` active), organized into 4 groups separated by hairline dividers: `Annotation Tools` / `Undo & Redo` / `Scrolling Capture & Record` / `Copy, Pin, Save & Close`.
  - **Secondary Property Bar (`40 pt` capsule)**: Positioned `8 pt` below the main bar, left-aligned, and sized to fit its content. A pinned `More` button outside the scroll area houses secondary parameters such as corner radius in a downward popover (`⎋` closes the topmost popover first without canceling the capture).
- **Annotation Tools & PixPin-Style Interaction**
  - **Shapes**: Rectangle (sharp `0` corners by default), Filled Rectangle, and Ellipse (switched in the secondary bar; resets to Rectangle each session).
  - **Lines**: Arrow (`ArrowUpRight03` with adaptive wing scaling for thick strokes) and Line (switched in the secondary bar; resets to Arrow each session).
  - **Brushes & Markers**: Pencil, Highlighter (with automatic text-line alignment), Text (fixed `PingFang SC`), Blur (Pixelate / Gaussian Blur with fine low-intensity steps and live preview), Spotlight (with background dimness slider), Counter (auto black/white contrast numerals), and Watermark.
  - **Direct Edge Dragging in Drawing Tools**: While any drawing tool (Rectangle, Arrow, etc.) is active, drag the edge of any existing annotation (including the one just drawn) to move it, click its edge to select it, or drag inside empty space to draw a new annotation (hold `⌥` to force drawing over an edge).
  - **Per-Tool Parameter Memory (`toolParameterDefaults.v2`)**: Stroke tools share color and stroke width, while Blur, Highlighter, Counter, Watermark, and Spotlight persist their parameters independently. Adjusting a newly drawn annotation updates that tool's default; editing an older annotation only affects itself.
  - **Auto Contrast Text Fill**: Switching Text to "Solid Fill" or "Speech Bubble" on a transparent background automatically promotes the current text color to the background fill and flips the text to high-contrast white or black while recalculating bounds.

### 3. Scrolling Capture (Long Screenshot)

- Click **Scrolling Capture** (`CarouselVertical` icon) in the `F1` toolbar to start capturing from the current selection with a live stitched preview window on the right.
- **Frame-Paced Stitching & Rollback Trimming**: Matches vertical displacement frame by frame (`0.75` confidence threshold); falls back to row-signature relocalization across the last three screen heights on fast flicks, and automatically trims excess tail content when scrolling back up.
- **Fixed Element Deduplication**: Automatically detects non-scrolling top navigation bars and bottom floating bars so they appear only once at the top and bottom of the stitched image.
- **Persistent Control Bar**: Displays live pixel dimensions, vertical Crop (`Crop`), Copy, Pin, Save, and Close below the selection, backed by a session-level key tap for `↩`, `⌘C`, `⌘S`, and `⎋`.

### 4. In-Place Screen Recording & Loop Playback

- **Recording Prep Bar**: Click **Record** (`Video01` icon) in the `F1` toolbar to switch in place to the preparation bar (pixel dimensions, System Audio toggle, Microphone toggle, red "Start Recording" capsule, and Close) while keeping the selection draggable and resizable. Press `↩` to start or `⎋` to return to the screenshot toolbar.
- **Active Recording**: Highlights the region with an outer red frame and a compact timer bar below (`0:12` elapsed time, Pause/Resume, Stop). Press `F1` again or click the menu bar indicator to stop. Neither the red frame nor the timer bar appears in the recorded video.
- **In-Place Loop Playback & On-Demand GIF Conversion**:
  - Immediately loops the recorded video in place at the exact capture bounds, with a bottom control bar offering Play/Pause, scrubbing, `MP4 / GIF` format toggle, Retake, Copy (`↩` / `⌘C`), Save (`⌘S`), and Close (`⎋`).
  - Always records high-frame-rate MP4; when switched to `GIF`, converts on the fly only when Copy or Save is triggered (showing a spinner only on the clicked button).
  - **Reversible Retake**: Clicking "Retake" hides the player and opens the prep bar with a dedicated Back (`ArrowLeft02`) button—press `⎋` or Back to restore the previous recording; the old clip is only discarded once a new recording actually starts. Closing an unsaved/uncopied recording prompts for confirmation.

### 5. Output & Borderless Pin Windows (`F2`)

- **Instant Copy, Save & In-Place Pinning**
  - **Copy** (`↩` / `⌘C` / double-click empty selection space): Dismisses the overlay immediately and encodes full-resolution PNG in the background (coalescing rapid copies without writing bloated TIFF data) while embedding source screen coordinates and logical size in the pasteboard item.
  - **Pin**: Pins the current selection (with annotations) directly at its original screen position and logical size; tall scrolling captures align to the top-left of the selection and scale down proportionally if taller than the display.
  - **Save** (`⌘S`): Saves to `~/Downloads/Pinny` (defaults to `~/Desktop/Pinny` on fresh installs, with automatic fallback if the folder is in Trash) using the `Pinny_` prefix; falls back to copying to clipboard with a toast notification if saving fails.
- **Borderless Sharp-Cornered Pin (`F2`)**
  - Reads images or copied image files from the clipboard and pins them on screen (waits automatically if a background `F1` copy is still finishing).
  - Restores Pinny captures at their exact original screen coordinates and logical size; centers external images without upscaling small images and scales oversized images proportionally to fit.
  - **Pure Image Interaction**: Borderless, sharp-cornered image window with zero floating chrome. Supports cross-display dragging (including across the menu bar into an upper external monitor), smooth cursor-centered scroll zooming, automatic clamping on display topology changes, and **double-clicking to copy full-resolution image data and close the pin** (pressing `F2` again restores its last position and zoom). Only the focused pin responds to `⎋`.

---

## Keyboard Shortcuts

### Global Shortcuts

| Shortcut | Action |
| :--- | :--- |
| `F1` | Open in-place capture overlay (or stop an active screen recording) |
| `F2` | Pin image or image file from the clipboard onto the screen |

### Selection Phase (Before Region Is Locked)

| Input / Shortcut | Action |
| :--- | :--- |
| Move cursor | Highlight UI element or window under the cursor |
| Scroll Up / Down | Switch to parent / child UI element (`⌘` + Scroll zooms the magnifier) |
| Left Click / Drag | Lock highlighted element, or drag a custom selection rect |
| `⌘A` | Select full screen on the current display |
| `Tab` | Select whole window under the cursor |
| `R` / `,` | Reuse last capture region / cycle recent capture regions |
| `C` | Copy current pixel color from the magnifier |
| `⎋` / Right Click | Cancel capture |

### Annotation Phase (After Region Is Locked)

| Input / Shortcut | Action |
| :--- | :--- |
| Drag empty selection area | Move selection (directly under Select tool, or hold `Space` under drawing tools) |
| Drag edges / corners | Resize selection (hold `⌘` to pause snapping; existing annotations keep their size) |
| Arrow keys | Nudge selection by 1 px |
| `⌘` / `⌥` + Arrow keys | Expand / shrink selection edges |
| `1` – `9`, `0` or tool keys | Switch annotation tool (press again to return to Select tool) |
| Drag any annotation edge | **Move that annotation directly** (works even under drawing tools; click edge to select, `⌥` + drag to force drawing) |
| `,` / `.` | Decrease / increase stroke width |
| `⌘Z` / `⇧⌘Z` | Undo / Redo |
| `⌫` | Delete selected annotation |
| `↩` / `⌘C` / Double-click | Copy full-resolution capture and dismiss overlay immediately |
| `⌘S` | Save capture to export directory |
| `⎋` | Close open secondary popover first; otherwise cancel capture |

### Scrolling Capture & Screen Recording

| Mode | Input / Shortcut | Action |
| :--- | :--- | :--- |
| **Scrolling Capture** | Scroll Down / Up | Stitch frames vertically / auto-trim tail when scrolling back up |
| | `↩` / `⌘C` | Copy stitched image and finish |
| | `⌘S` | Save stitched image to export directory |
| | `⎋` | Cancel scrolling capture |
| **Recording Prep** | `↩` | Start recording current selection |
| | `⎋` | Return to screenshot toolbar (or return to previous playback if entered via Retake) |
| **Recording Active** | `F1` / Click Stop | Stop recording and open in-place loop playback |
| **Playback Bar** | `↩` / `⌘C` | Copy recording in selected format (`MP4` or `GIF`) and close |
| | `⌘S` | Save recording in selected format to export directory |
| | `⎋` | Close playback (prompts for confirmation if neither copied nor saved) |

### Pin Window

| Input / Shortcut | Action |
| :--- | :--- |
| Left Drag | Move pin window (freely crosses the menu bar to upper displays) |
| Scroll Wheel / Trackpad | Smooth cursor-centered proportional zoom |
| Double-Click | Copy full-resolution image (preserving current position & size) and close pin |
| `⎋` | Close focused pin window |

---

## Build & Install

**Requirements**: macOS 13.0+ (macOS 26+ for native Liquid Glass), Xcode 15.0+, Apple Silicon (`arm64`).

Daily installation uses a **Release build** signed with a stable local certificate so macOS Screen Recording, Accessibility, and Microphone TCC permissions persist across updates.

### One-Step Build, Sign & Install (Recommended)

```bash
./scripts/install-pinny.sh --identity 'V2Do Dev'
```

This script automatically:
1. Builds the optimized `Release` binary (`../build/release`);
2. Packages `../build/preview-staged/Pinny.app` via `scripts/package-preview.py` (Bundle ID `com.tianruian.openshot.preview`, strips Sparkle auto-update, and verifies `--deep --strict` code signing);
3. Quits any running Pinny instance, backs up the previous `/Applications/Pinny.app` to a single `.bak` bundle in `../build/preview/`, installs to `/Applications/Pinny.app`, and launches it.

> If the Release binary is already built and you only need to repackage and install:
> ```bash
> ./scripts/install-pinny.sh --identity 'V2Do Dev' --skip-build
> ```

After installing, verify in **Settings → Permissions** and **Settings → Screenshot** that **Screen Recording** and **Accessibility** are granted and both window/element detection toggles are enabled.

---

## Icon Generation

- **App Icon & Menu Bar Template** (Hugeicons Pro `Aperture` Solid Rounded; requires `librsvg` and `Pillow`):
  ```bash
  python3 scripts/generate-pinny-icon.py
  ```
- **Inline Toolbar & Recording Bar Icons** (`CaptureTool-*.imageset`):
  ```bash
  python3 scripts/generate-toolbar-icons.py <hugeicons-pro-unpacked-dir>
  ```
  See [docs/HUGEICONS.md](docs/HUGEICONS.md) for icon mappings and specifications.

---

## Documentation

- [Core Context & Product Rules](CONTEXT.md)
- [Unified In-Place Capture, Scrolling Capture, Recording & Pinning](docs/UNIFIED-CAPTURE.md)
- [Hugeicons Pro Toolbar Specification](docs/HUGEICONS.md)
- [Local Development & Testing Guide](docs/DEVELOPMENT.md)
- [Build & Packaging Guide](docs/BUILD.md)
- [Documentation Index](docs/README.md)
- [Codebase & Runtime Structure](docs/STRUCTURE.md)

---

## License & Credits

- Released under the [BSD 3-Clause License](LICENSE).
- Derived from [Snapzy](https://github.com/duongductrong/Snapzy) by Trong Duong Duc, extensively redesigned around the `F1` in-place capture workflow and `F2` borderless pin-to-screen experience.
- Configuration is stored at `~/.config/pinny/config.toml` (auto-migrated from `~/.config/snapzy` on first launch). To preserve system TCC permissions and user data, the Xcode target, `snapzy://` URL scheme, and `~/Library/Application Support/Snapzy` directory retain their original identifiers.
