//
//  ScrollingCaptureHUDWindow.swift
//  Snapzy
//
//  Floating control HUD for scrolling capture sessions.
//

import AppKit
import Combine
import SwiftUI

final class ScrollingCaptureHUDWindow: NSPanel {
  private var anchorRect: CGRect
  private var modelObservation: AnyCancellable?

  init(
    anchorRect: CGRect,
    model: ScrollingCaptureSessionModel,
    onStart: @escaping () -> Void,
    onDone: @escaping () -> Void,
    onCancel: @escaping () -> Void,
    onToggleAutoScroll: @escaping () -> Void
  ) {
    self.anchorRect = anchorRect

    super.init(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    isFloatingPanel = true
    level = .popUpMenu
    isOpaque = false
    backgroundColor = .clear
    sharingType = .none
    hasShadow = true
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    appearance = ThemeManager.shared.nsAppearance
    contentView = FirstClickHostingView(rootView: ScrollingCaptureHUDView(
      model: model,
      onStart: onStart,
      onDone: onDone,
      onCancel: onCancel,
      onToggleAutoScroll: onToggleAutoScroll
    ))

    // Only the phase changes the buttons. The model also publishes live preview frames many
    // times a second; re-laying out the panel on each of them could swallow a click on Done.
    modelObservation = model.$phase.removeDuplicates().map { _ in () }
      .merge(with: model.$isAutoScrolling.removeDuplicates().map { _ in () })
      .sink { [weak self] _ in
      DispatchQueue.main.async {
        self?.refreshContentSize()
      }
    }

    refreshContentSize()
  }

  func updateAnchorRect(_ rect: CGRect) {
    anchorRect = rect
    refreshContentSize()
  }

  func refreshContentSize() {
    guard let contentView else { return }

    contentView.layoutSubtreeIfNeeded()
    let size = Self.resolvedContentSize(for: contentView.fittingSize)
    setContentSize(size)
    position(near: anchorRect, size: size)
  }

  nonisolated static func resolvedContentSize(for fittingSize: CGSize) -> CGSize {
    CGSize(
      width: max(180, fittingSize.width.rounded(.up)),
      height: max(34, fittingSize.height.rounded(.up))
    )
  }

  private func position(near rect: CGRect, size: CGSize) {
    guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main else {
      return
    }

    let visible = screen.visibleFrame
    let x = min(max(visible.minX + 12, rect.midX - size.width / 2), visible.maxX - size.width - 12)
    let y = min(visible.maxY - size.height - 12, rect.maxY + 16)
    setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: false)
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// While the user scrolls another app, Pinny is not active; without this the first click on
/// the non-activating HUD only activates the app and Done needs a second click.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
