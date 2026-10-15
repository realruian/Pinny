//
//  QuickAccessPinWindowManager.swift
//  Snapzy
//
//  Manages independent always-on-top pinned screenshot windows.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class QuickAccessPinWindowManager {
  static let shared = QuickAccessPinWindowManager()

  private var controllers: [UUID: QuickAccessPinWindowController] = [:]

  private init() {
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        // A display was unplugged or rearranged: bring back pins left completely off-screen.
        for controller in QuickAccessPinWindowManager.shared.controllers.values { controller.keepOnScreen() }
      }
    }
  }

  @discardableResult
  func show(item: QuickAccessItem, sourceScreenRect: CGRect? = nil, onUserClose: @escaping (UUID) -> Void) -> Bool {
    guard !item.isVideo else { return false }

    if let controller = controllers[item.id] {
      controller.update(item: item)
      controller.orderFront()
      return true
    }

    let controller = QuickAccessPinWindowController(item: item, sourceScreenRect: sourceScreenRect)
    controller.onUserClose = { [weak self] id in
      self?.controllers[id] = nil
      onUserClose(id)
    }
    controllers[item.id] = controller
    controller.show()
    return true
  }

  @discardableResult
  func show(image: NSImage, sourceScreenRect: CGRect? = nil) -> UUID {
    let id = UUID()
    let controller = QuickAccessPinWindowController(id: id, url: nil, image: image,
      thumbnail: image, sourceScreenRect: sourceScreenRect)
    controller.onUserClose = { [weak self] id in self?.controllers[id] = nil }
    controllers[id] = controller
    controller.show()
    return id
  }

  /// Reads image file URLs copied in Finder, then image representations. Never changes the clipboard.
  /// File URLs come first: a non-image file copied in Finder also carries its icon as image data.
  static func clipboardImage(from pasteboard: NSPasteboard) -> NSImage? {
    let urls = pasteboard.readObjects(forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    let imageURLs = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
    if !urls.isEmpty, imageURLs.isEmpty { return nil }
    if let image = imageURLs.lazy.compactMap({ NSImage(contentsOf: $0) }).first { return image }
    if let image = NSImage(pasteboard: pasteboard), image.isValid { return image }
    return nil
  }

  @discardableResult
  func showClipboardImage(from pasteboard: NSPasteboard = .general) -> UUID? {
    guard let image = Self.clipboardImage(from: pasteboard) else {
      SoundManager.beep()
      AppToastManager.shared.show(message: L10n.Actions.pinClipboardNoImage, style: .info)
      return nil
    }
    return show(image: image, sourceScreenRect: PinClipboardGeometry.sourceRect(from: pasteboard))
  }

  func update(item: QuickAccessItem, imageOverride: NSImage? = nil) {
    controllers[item.id]?.update(item: item, imageOverride: imageOverride)
  }

  func setPinZoomMode(_ mode: QuickAccessPinZoomMode) {
    for controller in controllers.values { controller.setZoomMode(mode) }
  }

  func close(id: UUID) {
    controllers.removeValue(forKey: id)?.close()
  }

  func closeAll() {
    for controller in controllers.values {
      controller.close()
    }
    controllers.removeAll()
  }

  func suspendAllMouseMonitors() {
    for controller in controllers.values {
      controller.suspendMouseMonitors()
    }
  }

  func resumeAllMouseMonitors() {
    for controller in controllers.values {
      controller.resumeMouseMonitors()
    }
  }
}

@MainActor
private final class QuickAccessPinWindowController {
  var onUserClose: ((UUID) -> Void)?

  private let id: UUID
  private let state: QuickAccessPinWindowState
  private let window: QuickAccessPinWindow
  private let sourceSize: CGSize?

  convenience init(item: QuickAccessItem, sourceScreenRect: CGRect?) {
    self.init(id: item.id, url: item.url, image: Self.loadImage(for: item),
              thumbnail: item.thumbnail, sourceScreenRect: sourceScreenRect)
  }

  init(id: UUID, url: URL?, image: NSImage, thumbnail: NSImage, sourceScreenRect: CGRect?) {
    self.id = id
    // A stored position from a display that is gone is dropped: center like an external image.
    let sourceScreenRect = QuickAccessPinWindowSizing.validSourceRect(sourceScreenRect).flatMap { rect in
      NSScreen.screens.contains { $0.frame.intersects(rect) } ? rect : nil
    }
    sourceSize = sourceScreenRect?.size
    let screen = ScreenUtility.activeScreen()
    let mode: QuickAccessPinZoomMode = .windowFollowsImage
    let frame = QuickAccessPinWindowSizing.initialFrame(
      imageSize: image.size, visibleFrame: screen.visibleFrame, mode: mode,
      sourceScreenRect: sourceScreenRect
    )
    state = QuickAccessPinWindowState(
      id: id,
      url: url,
      image: image,
      thumbnail: thumbnail,
      baseSize: frame.size,
      zoomMode: mode,
      preservesSourceSize: sourceScreenRect != nil
    )

    window = QuickAccessPinWindow(contentRect: frame, state: state)
    state.onWindowResize = { [weak self] size, anchorFraction in
      self?.resize(to: size, preservingAnchorFraction: anchorFraction, animated: false)
    }
    window.contentView = hostingView(size: state.displaySize)
    window.onCopyAndCloseRequested = { [weak self] in
      self?.copyAndClose()
    }
    window.onEscapeRequested = { [weak self] in
      self?.handleUserClose()
    }
  }

  func show() {
    window.alphaValue = 1.0
    orderFront()
    DiagnosticLogger.shared.log(.info, .action, "Pinned screenshot presented", context: [
      "frame": NSStringFromRect(window.frame),
      "sourceSize": sourceSize.map { NSStringFromSize($0) } ?? "none",
    ])
  }

  func orderFront() {
    window.orderFrontRegardless()
    window.updateMousePassthrough()
  }

  func update(item: QuickAccessItem, imageOverride: NSImage? = nil) {
    let image = imageOverride ?? Self.loadImage(for: item)
    let screen = window.screen ?? ScreenUtility.activeScreen()
    let baseSize = sourceSize ?? QuickAccessPinWindowSizing.initialFrame(imageSize: image.size, visibleFrame: screen.visibleFrame, mode: .windowFollowsImage).size
    let newSize = state.update(
      url: item.url,
      image: image,
      thumbnail: item.thumbnail,
      baseSize: baseSize
    )
    resize(to: newSize, animated: false)
  }

  func close() {
    window.close()
  }

  func suspendMouseMonitors() {
    window.suspendMouseMonitors()
  }

  func resumeMouseMonitors() {
    window.resumeMouseMonitors()
  }

  private func hostingView(size: CGSize) -> NSHostingView<QuickAccessPinWindowView> {
    let view = QuickAccessPinWindowView(state: state)
    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = NSRect(origin: .zero, size: size)
    return hostingView
  }

  private func copyAndClose() {
    // Copy the full-resolution image retained by this pin, including edits, in the same
    // format as an F1 copy. The current frame goes with it so F2 puts it back here.
    // It remains available even when the source file has moved or disappeared.
    ClipboardHelper.copyImageInBackground(state.image, sourceScreenRect: window.frame)
    handleUserClose()
  }

  func keepOnScreen() {
    let frame = QuickAccessPinWindowSizing.frameKeptOnScreen(window.frame, screens: Self.screenGeometry)
    guard frame != window.frame else { return }
    window.setFrameOrigin(frame.origin)
    window.updateMousePassthrough()
  }

  private static var screenGeometry: [(frame: CGRect, visibleFrame: CGRect)] {
    NSScreen.screens.map { ($0.frame, $0.visibleFrame) }
  }

  private func handleUserClose() {
    QuickAccessManager.shared.setWindowOpen(id: id, isOpen: false)
    self.close()
    self.onUserClose?(self.id)
  }

  private func resize(to size: CGSize, animated: Bool) {
    let currentFrame = window.frame
    let center = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
    let proposedFrame = NSRect(
      x: center.x - size.width / 2,
      y: center.y - size.height / 2,
      width: size.width,
      height: size.height
    )
    let screen = window.screen ?? ScreenUtility.activeScreen()
    let targetFrame = sourceSize == nil
      ? QuickAccessPinWindowSizing.constrainedFrame(proposedFrame, on: screen)
      : proposedFrame
    window.setFrame(targetFrame, display: true, animate: animated)
    window.contentView?.frame = NSRect(origin: .zero, size: targetFrame.size)
    window.updateMousePassthrough()
  }

  func setZoomMode(_ mode: QuickAccessPinZoomMode) {
    // Legacy configuration imports cannot restore a different pin interaction.
    let mode: QuickAccessPinZoomMode = .windowFollowsImage
    let screen = window.screen ?? ScreenUtility.activeScreen()
    let size = sourceSize ?? QuickAccessPinWindowSizing.size(for: state.image.size, visibleSize: screen.visibleFrame.size, mode: mode)
    guard state.setZoomMode(mode, baseSize: size) else { return }
    let frame = QuickAccessPinWindowSizing.resizedFrame(
      window.frame,
      to: size,
      within: screen.visibleFrame
    )
    window.setFrame(frame, display: true, animate: false)
    window.contentView?.frame = NSRect(origin: .zero, size: size)
    window.updateMousePassthrough()
  }

  private func resize(to size: CGSize, preservingAnchorFraction fraction: CGPoint, animated: Bool) {
    let oldFrame = window.frame
    let frame = QuickAccessPinWindowSizing.resizedFrame(
      oldFrame,
      to: size,
      preservingAnchorFraction: fraction
    )
    // Zoom stays anchored at the pointer like a free drag; only a pin pushed off every display comes back.
    let keptFrame = QuickAccessPinWindowSizing.frameKeptOnScreen(frame, screens: Self.screenGeometry)
    window.setFrame(keptFrame, display: true, animate: animated)
    window.contentView?.frame = NSRect(origin: .zero, size: size)
    window.updateMousePassthrough()
  }

  private static func loadImage(for item: QuickAccessItem) -> NSImage {
    let access = SandboxFileAccessManager.shared.beginAccessingURL(item.url)
    defer { access.stop() }
    return NSImage(contentsOf: item.url) ?? item.thumbnail
  }
}

/// Private clipboard geometry; never inferred from the last capture or an unrelated clipboard item.
enum PinClipboardGeometry {
  static let pasteboardType = NSPasteboard.PasteboardType("com.tianruian.openshot.pin-source-rect.v1")

  static func write(_ rect: CGRect?, to pasteboard: NSPasteboard) {
    guard let rect = QuickAccessPinWindowSizing.validSourceRect(rect) else { return }
    pasteboard.addTypes([pasteboardType], owner: nil)
    pasteboard.setPropertyList([rect.origin.x, rect.origin.y, rect.width, rect.height], forType: pasteboardType)
  }

  static func sourceRect(from pasteboard: NSPasteboard) -> CGRect? {
    guard let values = pasteboard.propertyList(forType: pasteboardType) as? [Double], values.count == 4 else { return nil }
    return QuickAccessPinWindowSizing.validSourceRect(CGRect(x: values[0], y: values[1], width: values[2], height: values[3]))
  }
}
