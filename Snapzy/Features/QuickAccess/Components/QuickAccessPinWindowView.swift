//
//  QuickAccessPinWindowView.swift
//  Snapzy
//
//  Image-only pinned screenshot. Window events handle double-click copy/close.
//

import AppKit
import SwiftUI

struct QuickAccessPinWindowView: View {
  @ObservedObject var state: QuickAccessPinWindowState

  var body: some View {
    QuickAccessPinImageViewport(state: state)
      .frame(width: state.displaySize.width, height: state.displaySize.height)
      .clipped()
      .background(Color.clear)
  }
}

/// NSView marker that opts a region of the pin window out of background
/// window dragging. `QuickAccessPinWindow` hit-tests for this class before
/// starting a native-or-manual background drag, so chrome controls keep
/// their clicks and future interactive controls only need to be wrapped in
/// `PinWindowDragExclusionRepresentable`.
final class PinWindowDragExclusionView: NSView {
  override var mouseDownCanMoveWindow: Bool { false }
}

struct PinWindowDragExclusionRepresentable: NSViewRepresentable {
  func makeNSView(context: Context) -> PinWindowDragExclusionView {
    PinWindowDragExclusionView(frame: .zero)
  }

  func updateNSView(_ nsView: PinWindowDragExclusionView, context: Context) {}
}
