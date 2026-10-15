//
//  LongScreenshotOutput.swift
//  Snapzy
//
//  Pinny: copy, pin or save a finished long screenshot, as asked from its toolbar.
//

import AppKit

nonisolated enum LongScreenshotPinGeometry {
  /// Pinned long image: top-left on the original selection at its logical size, shrunk
  /// proportionally when taller than the screen, and moved up only as far as needed to fit.
  static func pinRect(imageSize: CGSize, selectedRect: CGRect, visibleFrame: CGRect) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0 else { return selectedRect }
    let scale = min(1, visibleFrame.height / imageSize.height)
    let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    let top = min(selectedRect.maxY, visibleFrame.maxY)
    let y = max(top - size.height, visibleFrame.minY)
    return CGRect(origin: CGPoint(x: selectedRect.minX, y: y), size: size)
  }
}

@MainActor
enum LongScreenshotOutput {
  static func perform(
    _ result: ScrollingCaptureResult,
    format: ImageFormat,
    context: CaptureContext,
    saveDirectoryProvider: @escaping () -> URL?
  ) {
    let image = NSImage(cgImage: result.image, size: result.pointSize)
    let pinRect = LongScreenshotPinGeometry.pinRect(
      imageSize: result.pointSize, selectedRect: result.selectedRect,
      visibleFrame: screen(containing: result.selectedRect).visibleFrame)
    switch result.output {
    case .copy:
      SoundManager.play("Pop")
      ClipboardHelper.copyImageInBackground(image, sourceScreenRect: pinRect)
    case .pin:
      QuickAccessPinWindowManager.shared.show(image: image, sourceScreenRect: pinRect)
      let shouldCopy = UserDefaults.standard.object(forKey: "inlinePinCopiesImage") as? Bool ?? true
      if shouldCopy { ClipboardHelper.copyImageInBackground(image, sourceScreenRect: pinRect) }
    case .save:
      guard let directory = saveDirectoryProvider() else { return }
      Task { @MainActor in
        let saved = await ScreenCaptureManager.shared.saveProcessedImage(
          result.image, to: directory, format: format,
          scaleFactor: result.scaleFactor, emitCompletion: false, context: context
        )
        switch saved {
        case .success:
          SoundManager.playScreenshotCapture()
        case .failure(let error):
          AppToastManager.shared.show(message: error.localizedDescription, style: .error)
        }
      }
    }
  }

  private static func screen(containing rect: CGRect) -> NSScreen {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    return NSScreen.screens.first { $0.frame.contains(center) }
      ?? NSScreen.screens.first { $0.frame.intersects(rect) }
      ?? NSScreen.main ?? NSScreen.screens[0]
  }
}
