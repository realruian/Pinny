//
//  QuickAccessPinWindowManager.swift
//  Snapzy
//
//  Manages independent always-on-top pinned screenshot windows.
//

import AppKit
import SwiftUI

@MainActor
final class QuickAccessPinWindowManager {
  static let shared = QuickAccessPinWindowManager()

  private var controllers: [UUID: QuickAccessPinWindowController] = [:]

  private init() {}

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

  init(item: QuickAccessItem, sourceScreenRect: CGRect?) {
    id = item.id

    let image = Self.loadImage(for: item)
    let sourceScreenRect = QuickAccessPinWindowSizing.validSourceRect(sourceScreenRect)
    sourceSize = sourceScreenRect?.size
    let screen = ScreenUtility.activeScreen()
    let mode: QuickAccessPinZoomMode = sourceScreenRect == nil ? QuickAccessPinZoomModeStore.shared.mode : .windowFollowsImage
    let frame = QuickAccessPinWindowSizing.initialFrame(
      imageSize: image.size, visibleFrame: screen.visibleFrame, mode: mode,
      sourceScreenRect: sourceScreenRect
    )
    state = QuickAccessPinWindowState(
      id: item.id,
      url: item.url,
      image: image,
      thumbnail: item.thumbnail,
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
    let baseSize = sourceSize ?? QuickAccessPinWindowSizing.size(for: image.size, visibleSize: screen.visibleFrame.size, mode: state.zoomMode)
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
    // Copy the full-resolution image retained by this pin, including edits.
    // It remains available even when the source file has moved or disappeared.
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    guard pasteboard.writeObjects([state.image]) else {
      NSSound.beep()
      return
    }
    handleUserClose()
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
    let screen = window.screen ?? ScreenUtility.activeScreen()
    let visibleFrame = QuickAccessPinWindowSizing.repositionAfterZoom(frame, within: screen.visibleFrame)
    window.setFrame(visibleFrame, display: true, animate: animated)
    window.contentView?.frame = NSRect(origin: .zero, size: size)
    window.updateMousePassthrough()
  }

  private static func loadImage(for item: QuickAccessItem) -> NSImage {
    let access = SandboxFileAccessManager.shared.beginAccessingURL(item.url)
    defer { access.stop() }
    return NSImage(contentsOf: item.url) ?? item.thumbnail
  }
}
