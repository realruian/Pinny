//
//  QuickAccessPinWindowSizing.swift
//  Snapzy
//
//  Sizing policy for pinned screenshot windows.
//

import AppKit
import Foundation

enum QuickAccessPinWindowSizing {
  static let minimumInteractiveSize = CGSize(width: 240, height: 180)

  private static let absoluteMaxSize = CGSize(width: 1440, height: 920)
  private static let screenMaxRatio: CGFloat = 0.8
  private static let screenMargin: CGFloat = 24

  /// Limit interactive zoom without changing the original capture at presentation.
  static func maximumZoom(baseSize: CGSize, visibleSize: CGSize) -> CGFloat {
    guard baseSize.width > 0, baseSize.height > 0 else { return 1 }
    return min(8, max(1, min(visibleSize.width / baseSize.width, visibleSize.height / baseSize.height)))
  }

  /// Pins move freely (drag, zoom), across displays and over the menu bar. Only a pin that is
  /// completely off every display is moved onto the nearest one's visible area, keeping its size.
  static func frameKeptOnScreen(_ frame: CGRect, screens: [(frame: CGRect, visibleFrame: CGRect)]) -> CGRect {
    guard !screens.contains(where: { $0.frame.intersects(frame) }),
          let nearest = screens.min(by: { gap(frame, $0.frame) < gap(frame, $1.frame) }) else { return frame }
    let bounds = nearest.visibleFrame
    var result = frame
    result.origin.x = frame.width <= bounds.width
      ? min(max(frame.minX, bounds.minX), bounds.maxX - frame.width) : bounds.minX
    result.origin.y = frame.height <= bounds.height
      ? min(max(frame.minY, bounds.minY), bounds.maxY - frame.height) : bounds.maxY - frame.height
    return result
  }

  /// Squared distance between two rects (0 when they touch or overlap).
  private static func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let dx = max(b.minX - a.maxX, a.minX - b.maxX, 0)
    let dy = max(b.minY - a.maxY, a.minY - b.maxY, 0)
    return dx * dx + dy * dy
  }

  static func validSourceRect(_ rect: CGRect?) -> CGRect? {
    guard let rect, rect.origin.x.isFinite, rect.origin.y.isFinite,
          rect.size.width.isFinite, rect.size.height.isFinite,
          rect.size.width > 0, rect.size.height > 0 else { return nil }
    return rect
  }

  /// Capture coordinates are already in AppKit points. Do not fit, center, or
  /// clamp them to a visibleFrame: that would move edge and secondary-display captures.
  static func initialFrame(
    imageSize: CGSize, visibleFrame: CGRect, mode: QuickAccessPinZoomMode,
    sourceScreenRect: CGRect? = nil
  ) -> CGRect {
    if let rect = validSourceRect(sourceScreenRect) { return rect }
    // External images have no screen origin: center at their natural logical size.
    // Only downscale if the whole image would otherwise extend beyond this display.
    // TIFF DPI conversion can produce 50.00000000001 for an exact 50-point image.
    // Remove only floating-point noise so AppKit does not ceil it to 51 points.
    func naturalDimension(_ value: CGFloat) -> CGFloat {
      guard value.isFinite else { return 1 }
      let rounded = value.rounded()
      return max(abs(value - rounded) < 0.000_001 ? rounded : value, 1)
    }
    let source = CGSize(width: naturalDimension(imageSize.width), height: naturalDimension(imageSize.height))
    let scale = min(1, max(1, visibleFrame.width) / source.width, max(1, visibleFrame.height) / source.height)
    var centered = frame(size: CGSize(width: source.width * scale, height: source.height * scale),
                         centeredAt: CGPoint(x: visibleFrame.midX, y: visibleFrame.midY))
    // AppKit rounds a half-point centered origin outward and can add a point to the size.
    centered.origin.x = centered.origin.x.rounded()
    centered.origin.y = centered.origin.y.rounded()
    return centered
  }

  static func size(for imageSize: CGSize, visibleSize: CGSize, mode: QuickAccessPinZoomMode) -> CGSize {
    guard mode == .fixedViewport else { return size(for: imageSize, visibleSize: visibleSize) }
    let maxWidth = min(absoluteMaxSize.width, visibleSize.width * screenMaxRatio)
    let maxHeight = min(absoluteMaxSize.height, visibleSize.height * screenMaxRatio)
    let source = CGSize(width: max(imageSize.width, 1), height: max(imageSize.height, 1))
    let scale = min(1, maxWidth / source.width)
    let width = max(minimumInteractiveSize.width, source.width * scale)
    let imageHeight = source.height * scale
    let height = min(maxHeight, max(minimumInteractiveSize.height, imageHeight))
    return CGSize(width: min(width, maxWidth), height: height)
  }

  static func size(for imageSize: CGSize, visibleSize: CGSize) -> CGSize {
    let sourceSize = CGSize(width: max(imageSize.width, 1), height: max(imageSize.height, 1))
    let maxSize = CGSize(
      width: min(absoluteMaxSize.width, visibleSize.width * screenMaxRatio),
      height: min(absoluteMaxSize.height, visibleSize.height * screenMaxRatio)
    )
    let maxFitScale = min(maxSize.width / sourceSize.width, maxSize.height / sourceSize.height)
    let minFitScale = max(
      minimumInteractiveSize.width / sourceSize.width,
      minimumInteractiveSize.height / sourceSize.height
    )
    let preferredScale = max(1, minFitScale)
    let normalizedScale = min(preferredScale, maxFitScale)
    let fittedSize = CGSize(width: sourceSize.width * normalizedScale, height: sourceSize.height * normalizedScale)
    let baseSize = CGSize(
      width: min(max(fittedSize.width, minimumInteractiveSize.width), maxSize.width),
      height: min(max(fittedSize.height, minimumInteractiveSize.height), maxSize.height)
    )
    return baseSize
  }

  static func centeredFrame(size: CGSize, on screen: NSScreen) -> NSRect {
    let visibleFrame = screen.visibleFrame
    return NSRect(
      x: visibleFrame.midX - size.width / 2,
      y: visibleFrame.midY - size.height / 2,
      width: size.width,
      height: size.height
    )
  }

  static func frame(size: CGSize, centeredAt center: CGPoint) -> NSRect {
    NSRect(
      x: center.x - size.width / 2,
      y: center.y - size.height / 2,
      width: size.width,
      height: size.height
    )
  }

  static func resizedFrame(
    _ frame: NSRect,
    to size: CGSize,
    within visibleFrame: NSRect
  ) -> NSRect {
    let fittedSize = CGSize(
      width: min(size.width, visibleFrame.width),
      height: min(size.height, visibleFrame.height)
    )
    let centeredFrame = self.frame(
      size: fittedSize,
      centeredAt: CGPoint(x: frame.midX, y: frame.midY)
    )
    return NSRect(
      x: min(max(centeredFrame.minX, visibleFrame.minX), visibleFrame.maxX - fittedSize.width),
      y: min(max(centeredFrame.minY, visibleFrame.minY), visibleFrame.maxY - fittedSize.height),
      width: fittedSize.width,
      height: fittedSize.height
    )
  }

  static func resizedFrame(
    _ frame: NSRect,
    to size: CGSize,
    preservingAnchorFraction fraction: CGPoint
  ) -> NSRect {
    let anchor = CGPoint(
      x: frame.minX + frame.width * fraction.x,
      y: frame.minY + frame.height * fraction.y
    )
    return NSRect(
      x: anchor.x - size.width * fraction.x,
      y: anchor.y - size.height * fraction.y,
      width: size.width,
      height: size.height
    )
  }

  static func constrainedFrame(_ frame: NSRect, on screen: NSScreen) -> NSRect {
    constrainedFrame(frame, visibleFrame: screen.visibleFrame)
  }

  static func constrainedFrame(_ frame: NSRect, visibleFrame: NSRect) -> NSRect {
    let bounds = visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)
    let width = min(frame.width, max(bounds.width, 1))
    let height = min(frame.height, max(bounds.height, 1))
    return NSRect(
      x: min(max(frame.minX, bounds.minX), bounds.maxX - width),
      y: min(max(frame.minY, bounds.minY), bounds.maxY - height),
      width: width,
      height: height
    )
  }
}
