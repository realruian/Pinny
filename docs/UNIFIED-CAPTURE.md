# Unified screenshot workflow

The primary screenshot entry opens one inline capture session. Choose a detected component/window, drag a region, or select the display inside that session. Basic legacy capture entry points route to this same flow. Retired capture shortcuts are disabled and cleared, and cannot reclaim keys through settings reset or import.

- Scroll up/down to select parent/child candidates; Tab / Shift-Tab also work.
- Adjust the selection directly, then annotate in place.
- Copy, Return, or double-click empty image content: copy the rendered original-resolution image and exit. Text editing keeps Return and double-click behavior.
- Save / Command-S: explicitly save; a failed save or cancelled directory picker keeps the session open.
- Pin: create a floating image directly from memory at the selection's screen frame. It does not require a saved file. `inlinePinCopiesImage` defaults to true and is configurable in pin settings.
- Pinned images use the same square, image-only window for direct captures and clipboard images: drag to move; scroll to resize the entire image and window. Double-click copies original-resolution content and closes only that pin. Source geometry travels with the clipboard item, so re-pinning restores its current frame. External images without geometry are centered at natural logical size; only images exceeding the display are scaled down proportionally.

The capture shortcuts are Screenshot (F1) and Pin Clipboard Image (F2). F2 reads image representations or copied image file URLs from the clipboard and creates an independent pin; it never pins the current capture selection or mutates the clipboard. When our clipboard item includes source geometry, it restores the same position and size; unrelated clipboard images never inherit a previous capture frame. The inline toolbar Pin action remains selection-based.

The menu and screenshot shortcut help present one Screenshot action. Screenshot post-processing switches from the old save-first workflow are no longer exposed as controls for this flow. Recording controls remain unchanged.

Runtime validation and retained evidence are in the parent workspace's `validation/UNIFIED-CAPTURE-FLOW.md`. This change aligns the interaction, not an undocumented PixPin detection algorithm. Cross-app detection accuracy and mixed-scale multi-display behavior require separate live validation.
