//
//  LongScreenshotSessionUI.swift
//  Snapzy
//
//  Pinny: the long screenshot keeps the F1 toolbar under the selection (size, crop, copy,
//  pin, save, close) and a preview rail beside it showing how much has been stitched.
//  Copy, pin and save end the session directly; there is no separate Done step.
//

import AppKit
import Combine
import SwiftUI

/// Where the long screenshot toolbar sits: the F1 rule, centered under the selection, above
/// it when there is no room below, inside its bottom edge when neither fits.
nonisolated enum LongScreenshotToolbarGeometry {
  static func frame(size: CGSize, selection: CGRect, visibleFrame: CGRect) -> CGRect {
    let gap = InlineAreaLayout.selectionGap
    let padding = InlineAreaLayout.screenPadding
    let x = min(max(selection.midX - size.width / 2, visibleFrame.minX + padding),
                visibleFrame.maxX - padding - size.width)
    let below = selection.minY - gap - size.height
    let above = selection.maxY + gap
    let y: CGFloat
    if below >= visibleFrame.minY + padding {
      y = below
    } else if above + size.height <= visibleFrame.maxY - padding {
      y = above
    } else {
      y = max(visibleFrame.minY + padding, selection.minY + gap)
    }
    return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
  }
}

/// The toolbar and rail stay out of screen captures so they are never stitched into the image.
/// `debug.captureLongScreenshotChrome` lets verification screenshots include them.
enum LongScreenshotChrome {
  static var sharingType: NSWindow.SharingType {
    UserDefaults.standard.bool(forKey: "debug.captureLongScreenshotChrome") ? .readOnly : .none
  }
}

struct LongScreenshotToolbarActions {
  let toggleCrop: () -> Void
  let copy: () -> Void
  let pin: () -> Void
  let save: () -> Void
  let close: () -> Void
}

/// Non-activating, so the scrolled app stays in front; accepts the first click so a button
/// works while another app is active. Its shortcuts come from `LongScreenshotKeyTap`.
final class LongScreenshotToolbarWindow: NSPanel {
  private let selection: CGRect
  private var observation: AnyCancellable?
  private var keyTap: LongScreenshotKeyTap?

  init(selection: CGRect, model: ScrollingCaptureSessionModel, actions: LongScreenshotToolbarActions) {
    self.selection = selection
    super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
               backing: .buffered, defer: false)
    isFloatingPanel = true
    level = .popUpMenu
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    sharingType = LongScreenshotChrome.sharingType
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    contentView = LongScreenshotFirstClickHostingView(
      rootView: LongScreenshotToolbarView(model: model, actions: actions))
    // The label switches between the size and the scrolled-too-fast hint.
    observation = model.$guidanceKind.map { _ in () }
      .merge(with: model.$isTrimming.map { _ in () })
      .sink { [weak self] _ in DispatchQueue.main.async { self?.layoutToSelection() } }
    layoutToSelection()
    keyTap = LongScreenshotKeyTap { key in
      switch key {
      case .copy: actions.copy()
      case .save: actions.save()
      case .close: actions.close()
      }
    }
  }

  func show() {
    makeKeyAndOrderFront(nil)
  }

  private func layoutToSelection() {
    guard let contentView else { return }
    contentView.layoutSubtreeIfNeeded()
    let size = contentView.fittingSize
    let screen = NSScreen.screens.first { $0.frame.intersects(selection) } ?? NSScreen.main
    guard let visible = screen?.visibleFrame else { return }
    setFrame(LongScreenshotToolbarGeometry.frame(size: size, selection: selection, visibleFrame: visible),
             display: true)
  }

  override func close() {
    keyTap?.invalidate()
    keyTap = nil
    super.close()
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// The scrolled app stays active during a long screenshot, so a window key monitor never sees
/// the toolbar shortcuts. A session event tap takes Return / Enter / ⌘C (copy), ⌘S (save) and
/// Esc (close) before that app does; every other key passes through. Without the tap (no
/// accessibility permission) the shortcuts work only while a Pinny window has the keyboard.
final class LongScreenshotKeyTap {
  enum Key { case copy, save, close }

  private let handler: (Key) -> Void
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var localMonitor: Any?

  init(handler: @escaping (Key) -> Void) {
    self.handler = handler
    if !installEventTap() {
      localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, let key = Self.key(keyCode: event.keyCode,
                                           flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))
        else { return event }
        self.handler(key)
        return nil
      }
    }
  }

  deinit { invalidate() }

  func invalidate() {
    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
      CFRunLoopSourceInvalidate(runLoopSource)
    }
    if let eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: false)
      CFMachPortInvalidate(eventTap)
    }
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    runLoopSource = nil
    eventTap = nil
    localMonitor = nil
  }

  /// Plain Return / keypad Enter / Esc, or ⌘C / ⌘S with no other modifier.
  nonisolated static func key(keyCode: UInt16, flags: CGEventFlags) -> Key? {
    let modifiers = flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
    switch (keyCode, modifiers) {
    case (36, []), (76, []): return .copy
    case (8, .maskCommand): return .copy
    case (1, .maskCommand): return .save
    case (53, []): return .close
    default: return nil
    }
  }

  private func installEventTap() -> Bool {
    let mask = CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue)
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
      eventsOfInterest: mask, callback: Self.callback,
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    ) else { return false }
    guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
      CFMachPortInvalidate(tap)
      return false
    }
    eventTap = tap
    runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
  }

  private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<LongScreenshotKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated { tap.handle(type: type, event: event) }
  }

  private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
      return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown,
          let key = Self.key(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                             flags: event.flags)
    else { return Unmanaged.passUnretained(event) }
    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
      // Defer so the session can tear this tap down from inside the action.
      DispatchQueue.main.async { [handler] in handler(key) }
    }
    return nil
  }
}

private final class LongScreenshotFirstClickHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct LongScreenshotToolbarView: View {
  @ObservedObject var model: ScrollingCaptureSessionModel
  let actions: LongScreenshotToolbarActions

  private var keptHeight: Int {
    model.trimmedRows(forHeight: model.stitchedPixelHeight).count
  }

  var body: some View {
    HStack(spacing: 0) {
      Group {
        if model.isLost {
          Text(L10n.PinnyLongScreenshot.lostToolbarHint)
            .foregroundColor(.orange)
        } else {
          Text("\(model.stitchedPixelWidth) × \(keptHeight)")
            .foregroundColor(InlineAreaChrome.secondaryText)
        }
      }
      .font(.system(size: 11, weight: .medium).monospacedDigit())
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 6)

      InlineAreaDivider()
      LongScreenshotToggleButton(icon: "crop", tooltip: L10n.PinnyLongScreenshot.crop,
                                 isOn: model.isTrimming, action: actions.toggleCrop)
      InlineAreaDivider()
      HStack(spacing: InlineAreaToolbarMetrics.itemSpacing) {
        InlineAreaIconButton(icon: "copy",
          tooltip: L10n.Common.withShortcut(L10n.AnnotateUI.copyToClipboard, "\(L10n.AnnotateUI.pinnyReturnKey) / ⌘C"),
          action: actions.copy)
        InlineAreaIconButton(icon: "pin", tooltip: L10n.PreferencesQuickAccess.pinToScreenAction,
                             action: actions.pin)
        InlineAreaIconButton(icon: "save", tooltip: L10n.Common.withShortcut(L10n.Common.save, "⌘S"),
                             action: actions.save)
        InlineAreaIconButton(icon: "cancel", tooltip: L10n.Common.withShortcut(L10n.Common.close, "Esc"),
                             action: actions.close)
      }
    }
    .padding(.horizontal, InlineAreaToolbarMetrics.horizontalPadding)
    .padding(.vertical, InlineAreaToolbarMetrics.verticalPadding)
    .inlineAreaPanelChrome()
    .padding(12) // room for the panel shadow
    .fixedSize()
  }
}

private struct LongScreenshotToggleButton: View {
  let icon: String
  let tooltip: String
  let isOn: Bool
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      InlineAreaGlyph(name: icon, isSelected: isOn, size: InlineAreaToolbarMetrics.iconSize)
        .foregroundColor(isOn ? InlineAreaChrome.toolbarIconSelectedForeground : .primary.opacity(isHovering ? 1 : 0.85))
        .frame(width: InlineAreaChrome.controlSize, height: InlineAreaChrome.controlSize)
        .background(
          RoundedRectangle(cornerRadius: InlineAreaChrome.controlCornerRadius, style: .continuous)
            .fill(isOn ? InlineAreaChrome.itemSelectedBackground
                  : (isHovering ? InlineAreaChrome.toolbarHoverBackground : .clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: InlineAreaChrome.controlCornerRadius, style: .continuous))
    }
    .buttonStyle(InlineAreaToolbarButtonStyle())
    .help(tooltip)
    .accessibilityLabel(tooltip)
    .accessibilityAddTraits(isOn ? .isSelected : [])
    .onHover { isHovering = $0 }
  }
}

/// The rail beside the selection: the whole stitched image, the current view framed in green,
/// and top/bottom handles while cropping (the only time it takes the mouse).
final class LongScreenshotPreviewWindow: NSPanel {
  private let selection: CGRect
  private var observations: Set<AnyCancellable> = []

  init(selection: CGRect, model: ScrollingCaptureSessionModel) {
    self.selection = selection
    super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
               backing: .buffered, defer: false)
    isFloatingPanel = true
    level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    sharingType = LongScreenshotChrome.sharingType
    hidesOnDeactivate = false
    ignoresMouseEvents = true
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    contentView = LongScreenshotFirstClickHostingView(rootView: LongScreenshotPreviewView(model: model))
    model.$isTrimming.sink { [weak self] trimming in
      self?.ignoresMouseEvents = !trimming
    }.store(in: &observations)
    model.$previewImage.map { _ in () }.merge(with: model.$livePreviewImage.map { _ in () })
      .sink { [weak self] _ in DispatchQueue.main.async { self?.layoutBesideSelection() } }
      .store(in: &observations)
    layoutBesideSelection()
  }

  private func layoutBesideSelection() {
    guard let contentView else { return }
    contentView.layoutSubtreeIfNeeded()
    let size = contentView.fittingSize
    guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(selection) }) ?? NSScreen.main else {
      return
    }
    let visible = screen.visibleFrame
    let right = selection.maxX + 8
    let x = right + size.width <= visible.maxX - 4 ? right : max(visible.minX + 4, selection.minX - size.width - 8)
    let y = min(max(visible.minY + 4, selection.maxY - size.height + 12), visible.maxY - size.height)
    setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: true)
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

nonisolated enum LongScreenshotPreviewLayout {
  static let width: CGFloat = 168
  static let maximumHeight: CGFloat = 420

  /// The whole stitched image fits: full rail width, or narrower once it gets long.
  static func imageSize(pixelSize: CGSize) -> CGSize {
    guard pixelSize.width > 0, pixelSize.height > 0 else { return CGSize(width: width, height: 120) }
    let scale = min(width / pixelSize.width, maximumHeight / pixelSize.height)
    return CGSize(width: (pixelSize.width * scale).rounded(), height: (pixelSize.height * scale).rounded())
  }
}

private struct LongScreenshotPreviewView: View {
  @ObservedObject var model: ScrollingCaptureSessionModel

  private var image: CGImage? { model.previewImage ?? model.livePreviewImage }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(L10n.PinnyLongScreenshot.capturedHeight(model.stitchedPixelHeight))
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundColor(InlineAreaChrome.secondaryText)
      if let image {
        let size = LongScreenshotPreviewLayout.imageSize(
          pixelSize: CGSize(width: image.width, height: image.height))
        ZStack(alignment: .top) {
          Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.medium)
            .frame(width: size.width, height: size.height)
          if model.isTrimming {
            LongScreenshotTrimOverlay(top: $model.trimTop, bottom: $model.trimBottom, height: size.height)
          } else {
            viewportFrame(height: size.height)
          }
        }
        .frame(width: size.width, height: size.height)
        .frame(width: LongScreenshotPreviewLayout.width)
      }
    }
    .padding(8)
    .inlineAreaPanelChrome()
    .padding(12) // room for the panel shadow
    .fixedSize()
  }

  /// The view sits at the bottom of the stitched image: that is where stitching continues.
  private func viewportFrame(height: CGFloat) -> some View {
    let total = max(1, CGFloat(model.stitchedPixelHeight))
    let fraction = min(1, CGFloat(model.viewportPixelHeight) / total)
    return VStack(spacing: 0) {
      Spacer(minLength: 0)
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .strokeBorder(Color.green, lineWidth: 2)
        .frame(height: max(8, height * fraction))
    }
    .allowsHitTesting(false)
  }
}

private struct LongScreenshotTrimOverlay: View {
  @Binding var top: CGFloat
  @Binding var bottom: CGFloat
  let height: CGFloat

  /// At least a tenth of the image is always kept.
  private static let minimumKept: CGFloat = 0.1

  var body: some View {
    ZStack(alignment: .top) {
      Color.black.opacity(0.4).frame(height: height * top)
      Color.black.opacity(0.4).frame(height: height * bottom).offset(y: height * (1 - bottom))
      handle.offset(y: height * top - 6)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim")).onChanged { value in
          top = min(max(0, value.location.y / height), 1 - bottom - Self.minimumKept)
        })
      handle.offset(y: height * (1 - bottom) - 6)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim")).onChanged { value in
          bottom = min(max(0, 1 - value.location.y / height), 1 - top - Self.minimumKept)
        })
    }
    .frame(height: height, alignment: .top)
    .coordinateSpace(name: "trim")
  }

  private var handle: some View {
    ZStack {
      Color.clear.frame(height: 12).contentShape(Rectangle())
      Capsule().fill(Color.accentColor).frame(height: 4)
    }
    .onHover { inside in
      if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
    }
  }
}
