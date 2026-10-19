//
//  InlineAreaAnnotateWindow.swift
//  Snapzy
//
//  Per-display overlays for selecting and annotating a screenshot region.
//

import AppKit
import SwiftUI

@MainActor
final class InlineAreaAnnotateCoordinator {
  static let shared = InlineAreaAnnotateCoordinator()
  private var activeWindows: [InlineAreaAnnotatePanel] = []
  private var previouslyActiveApplication: NSRunningApplication?

  func start(
    screens: [NSScreen],
    primaryDisplayID: CGDirectDisplayID,
    backdrops: [CGDirectDisplayID: AreaSelectionBackdrop],
    frozenSession: FrozenAreaCaptureSession,
    saveDirectory: URL,
    outputFormat: ImageFormat,
    saveDirectoryProvider: (() -> URL?)? = nil,
    context: CaptureContext = .empty,
    prefetchedContentTask: ShareableContentPrefetchTask? = nil,
    excludeOwnApplication: Bool = false,
    recordingPrepRect: CGRect? = nil,
    onComplete: @escaping (InlineCaptureOutcome) -> Void
  ) {
    CaptureTiming.mark("coordinator start")
    closeActiveWindows()
    let availableScreens = screens.filter { screen in
      guard let displayID = screen.displayID else { return false }
      return backdrops[displayID] != nil
    }
    guard !availableScreens.isEmpty else {
      onComplete(.failure(.noDisplayFound))
      return
    }

    previouslyActiveApplication = NSWorkspace.shared.frontmostApplication
    NSApp.activate(ignoringOtherApps: true)

    let wrappedOnComplete: (InlineCaptureOutcome) -> Void = { [weak self] result in
      guard let self else {
        onComplete(result)
        return
      }
      self.previouslyActiveApplication?.activate(options: [])
      self.previouslyActiveApplication = nil
      onComplete(result)
    }

    let desktopFrame = InlineAreaAnnotateSession.desktopFrame(for: availableScreens.map(\.frame))
    let displays = availableScreens.compactMap { screen -> InlineAreaAnnotateDisplay? in
      guard let displayID = screen.displayID,
            let backdrop = backdrops[displayID] else { return nil }
      return InlineAreaAnnotateDisplay(
        displayID: displayID,
        screenFrame: screen.frame,
        localFrame: InlineAreaAnnotateSession.localFrame(for: screen.frame, in: desktopFrame),
        controlInsets: InlineAreaControlInsets(screen: screen),
        backdropImage: NSImage(cgImage: backdrop.image, size: screen.frame.size),
        backdropCGImage: backdrop.image
      )
    }
    guard !displays.isEmpty else {
      wrappedOnComplete(.failure(.noDisplayFound))
      return
    }

    CaptureTiming.mark("display records built")
    let session = InlineAreaAnnotateSession(
      primaryDisplayID: primaryDisplayID,
      desktopFrame: desktopFrame,
      displays: displays,
      frozenSession: frozenSession,
      saveDirectory: saveDirectory,
      outputFormat: outputFormat,
      saveDirectoryProvider: saveDirectoryProvider,
      context: context,
      prefetchedContentTask: prefetchedContentTask,
      excludeOwnApplication: excludeOwnApplication,
      onComplete: wrappedOnComplete
    )

    CaptureTiming.mark("session created")
    let windows = displays.map { display in
      InlineAreaAnnotatePanel(display: display, session: session)
    }
    CaptureTiming.mark("panels created")
    activeWindows = windows

    for window in windows {
      window.onClose = { [weak self, weak window] in
        guard let self, let window else { return }
        self.activeWindows.removeAll { $0 === window }
      }
      session.attach(window: window)
      window.orderFrontRegardless()
      if window.displayID == primaryDisplayID {
        window.makeKey()
      }
    }
    if !windows.contains(where: { $0.displayID == primaryDisplayID }) {
      windows.first?.makeKey()
    }
    if let recordingPrepRect {
      session.beginRecordingPrep(screenRect: recordingPrepRect)
    }
    CaptureTiming.mark("panels ordered front")
    DispatchQueue.main.async {
      CaptureTiming.end("next main run loop turn (first frame committed)")
    }
  }

  private func closeActiveWindows() {
    let windows = activeWindows
    activeWindows.removeAll()
    for window in windows {
      window.close()
    }
    previouslyActiveApplication?.activate(options: [])
    previouslyActiveApplication = nil
  }
}

final class InlineAreaAnnotatePanel: NSPanel {
  var onClose: (() -> Void)?
  let displayID: CGDirectDisplayID

  private let session: InlineAreaAnnotateSession
  private var didNotifyClose = false

  init(display: InlineAreaAnnotateDisplay, session: InlineAreaAnnotateSession) {
    displayID = display.displayID
    self.session = session
    super.init(
      contentRect: display.screenFrame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    isFloatingPanel = true
    isOpaque = false
    backgroundColor = .clear
    level = .screenSaver
    ignoresMouseEvents = false
    acceptsMouseMovedEvents = true
    isReleasedWhenClosed = false
    hasShadow = false
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    animationBehavior = .none
    becomesKeyOnlyIfNeeded = true

    isMovable = false
    isMovableByWindowBackground = false
    minSize = display.screenFrame.size
    maxSize = display.screenFrame.size
    if let nsAppearance = ThemeManager.shared.nsAppearance {
      appearance = nsAppearance
    } else {
      let isDark = ThemeManager.shared.systemAppearance == .dark
      appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    let rootView = InlineAreaAnnotateRootView(
      session: session,
      display: display
    )
    .preferredColorScheme(ThemeManager.shared.systemAppearance)
    let hostingView = InlineAreaHostingView(rootView: rootView)
    contentView = hostingView
  }

  override var canBecomeKey: Bool {
    true
  }

  override var canBecomeMain: Bool {
    false
  }

  override func setFrame(_ frameRect: NSRect, display displayFlag: Bool) {
    self.minSize = frameRect.size
    self.maxSize = frameRect.size
    super.setFrame(frameRect, display: displayFlag)
  }

  override func sendEvent(_ event: NSEvent) {
    // Only the first display's panel is made key on open; a click on another display's panel
    // must take the keyboard too, or Delete, ⌘Z and arrows would go nowhere.
    if event.type == .leftMouseDown, !isKeyWindow {
      makeKey()
    }
    if event.type == .leftMouseDown, event.clickCount == 2, session.phase == .annotating,
       !session.isRecordingPrep, session.state.selectedTool == .selection,
       session.state.editingTextAnnotationId == nil, session.state.annotations.isEmpty,
       let rect = session.selectionRect {
      let screen = convertPoint(toScreen: event.locationInWindow)
      if session.screenRect(for: rect).contains(screen) {
        session.copyCurrentImage()
        return
      }
    }
    super.sendEvent(event)
    switch event.type {
    case .mouseMoved, .mouseEntered, .flagsChanged, .leftMouseUp, .rightMouseUp:
      applyHoverCursor()
    default:
      break
    }
  }

  /// Pinny: the one place the annotating overlay sets the cursor, from what is under the
  /// pointer (see `hoverCursor`). Setting it again on every move also keeps the WindowServer
  /// from leaving a stale cursor on this non-activating panel.
  func applyHoverCursor() {
    hoverCursor(atScreenPoint: NSEvent.mouseLocation)?.set()
  }

  /// Nil leaves the cursor alone: choosing a region (drawn crosshair), a press in progress
  /// (the gesture owns it), or text editing (I-beam).
  private func hoverCursor(atScreenPoint screenPoint: CGPoint) -> NSCursor? {
    guard session.phase == .annotating, NSEvent.pressedMouseButtons == 0,
          frame.contains(screenPoint), let contentView else { return nil }
    let windowPoint = convertPoint(fromScreen: screenPoint)
    let hit = contentView.hitTest(contentView.superview?.convert(windowPoint, from: nil) ?? windowPoint)
    if hit is NSTextView || hit?.enclosingScrollView?.documentView is NSTextView { return nil }
    guard let selection = session.selectionRect else { return .arrow }
    let point = session.localDesktopPoint(for: screenPoint)
    if let handle = InlineAreaResizeHandle.handle(at: point, in: selection) {
      return handle.cursor
    }
    if session.isMoveModifierActive, selection.contains(point) {
      return .openHand
    }
    if let canvas = hit as? DrawingCanvasNSView {
      return canvas.hoverCursor(
        atDisplayPoint: canvas.convert(windowPoint, from: nil),
        optionHeld: NSEvent.modifierFlags.contains(.option),
        drawCursor: .crosshair
      )
    }
    // Outside the selection, and the toolbars wherever they sit.
    return .arrow
  }

  override func keyDown(with event: NSEvent) {
    if session.handleKeyEvent(event) { return }
    super.keyDown(with: event)
  }

  override func keyUp(with event: NSEvent) {
    if session.handleKeyEvent(event) { return }
    super.keyUp(with: event)
  }

  override func close() {
    super.close()
    guard !didNotifyClose else { return }
    didNotifyClose = true
    session.windowDidClose()
    onClose?()
  }
}

private final class InlineAreaHostingView: NSHostingView<AnyView> {
  convenience init<Content: View>(rootView: Content) {
    self.init(rootView: AnyView(rootView))
  }

  required init(rootView: AnyView) {
    super.init(rootView: rootView)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
    true
  }
}

private struct InlineAreaAnnotateRootView: View {
  @ObservedObject var session: InlineAreaAnnotateSession
  let display: InlineAreaAnnotateDisplay

  @State private var movingStartRect: CGRect?
  @State private var resizingStartRect: CGRect?
  @State private var activeResizeHandle: InlineAreaResizeHandle?
  @State private var cursorIndicatorPoint: CGPoint?
  @State private var hoverTip: InlineAreaHoverTip?
  /// Measured width of the secondary bar's content; it sizes the bar's own capsule.
  @State private var propertiesContentWidth: CGFloat = 0
  /// Viewport point where a gesture began on a hovered window, while it's still ambiguous
  /// whether this will resolve as a click (select the window) or a drag (manual region
  /// selection) — mirrors plain area screenshot's `pendingWindowDetectionStartPoint`.
  @State private var pendingWindowSelectionStart: CGPoint?
  private let windowDetectionDragThreshold: CGFloat = 4.0

  var body: some View {
    GeometryReader { geometry in
      // Detected elements by default, whole windows after Tab; see `hoverTargetsWindows`.
      let hoveredHighlightScreenRect = session.hoverHighlightScreenRect
      let hoveredWindowDesktopRect = hoveredHighlightScreenRect.map {
        InlineAreaAnnotateSession.localFrame(for: $0, in: session.desktopFrame)
      }
      let desktopRect = session.resizePreviewRect ?? session.movingPreviewRect ?? session.selectionRect ?? hoveredWindowDesktopRect
      let viewportRect = desktopRect.map(rectInViewport)
      let isSelectionPreviewing = session.resizePreviewRect != nil || session.movingPreviewRect != nil
      let showsCursorIndicator = session.movingPreviewRect != nil
      // Pointer position for the drawn crosshair / magnifier during `.selecting`. Prefer the
      // session-published desktop point, which the drag local monitor keeps fresh while it
      // consumes `.leftMouseDragged` (starving the SwiftUI gesture that feeds
      // `cursorIndicatorPoint`) — otherwise this chrome freezes at the drag-start point.
      // Gated to this display's bounds: each per-display panel only renders the pointer
      // chrome while the pointer is actually on that display.
      let viewportBounds = CGRect(origin: .zero, size: display.localFrame.size)
      let selectingPointerPoint = (session.selectionPointerLocation.map(viewportPoint(for:)) ?? cursorIndicatorPoint)
        .flatMap { viewportBounds.contains($0) ? $0 : nil }

      ZStack(alignment: .topLeading) {
        // Only backdrops that intersect this panel's display; the others sit entirely
        // off-window and would just add a full-resolution image layer per extra display.
        ForEach(session.displays.filter { $0.localFrame.intersects(display.localFrame) }) { backdropDisplay in
          Image(nsImage: backdropDisplay.backdropImage)
            .resizable()
            .frame(width: backdropDisplay.localFrame.width, height: backdropDisplay.localFrame.height)
            .position(
              x: backdropDisplay.localFrame.midX - display.localFrame.minX,
              y: backdropDisplay.localFrame.midY - display.localFrame.minY
            )
        }

        selectionDimLayer(size: geometry.size, rect: viewportRect)

        if let desktopRect, let viewportRect {
          if session.phase == .annotating {
            annotateSurface(rect: viewportRect, usesBackdropPreview: isSelectionPreviewing)
            // Kept until the drag ends even if Space is released first, or the gesture would
            // be torn down without committing the move.
            if session.isMoveModifierActive || movingStartRect != nil {
              spaceMoveHitArea(rect: viewportRect, desktopRect: desktopRect)
            }
            resizeHandles(rect: viewportRect, desktopRect: desktopRect)
            if session.controlDisplayID(for: desktopRect) == display.displayID {
              controls(rect: viewportRect, desktopRect: desktopRect, containerSize: geometry.size)
            }
          } else {
            selectionBorder(rect: viewportRect)

          }
        }

        if showsCursorIndicator, let cursorIndicatorPoint {
          InlineAreaCursorIndicator(point: cursorIndicatorPoint)
        }

        if session.phase == .selecting {
          VStack {
            // Last region comes last: it only shows once there is a region to reuse, so the
            // others never move. Same gap from the left and the top edge, below the menu bar.
            let chipMargin = max(48, display.controlInsets.top + 12)
            HStack(spacing: 8) {
              InlineAreaKeyChip(title: L10n.Annotate.pinnyFullScreenChip, key: "⌘A") {
                session.selectDisplayUnderPointer()
              }
              InlineAreaKeyChip(title: L10n.Annotate.pinnyWholeWindowChip, key: "Tab")
              if session.hasRegionHistory {
                InlineAreaKeyChip(title: L10n.Annotate.pinnyLastRegionChip, key: "R") {
                  _ = session.recallRegion(older: true)
                }
              }
            }
            .padding(.top, chipMargin)
            .padding(.leading, chipMargin)
            // Out of the way while a region is being dragged across them.
            .opacity(session.selectionRect == nil ? 1 : 0)
            .allowsHitTesting(session.selectionRect == nil)
            Spacer()
          }.zIndex(20)
          InlineAreaMagnifierOverlay(
            backdropImage: display.backdropCGImage,
            point: selectingPointerPoint.map { appKitLocalPoint(fromViewportPoint: $0) },
            hostSize: display.localFrame.size,
            showsByDefault: session.showsMagnifierByDefault,
            showsColorPanel: session.showsMagnifierColorPanel,
            onHostViewReady: { hostView in
              session.registerMagnifierHostView(hostView, for: display.displayID)
            }
          )
          // `display.localFrame.size`, not `geometry.size` — the latter isn't reliably
          // settled on the first frame this view appears (see `appKitLocalPoint`), and this
          // display's true size is already known without needing SwiftUI to measure it.
          .frame(width: display.localFrame.width, height: display.localFrame.height)
          .allowsHitTesting(false)

          // The real system cursor is hidden for the whole `.selecting` phase
          // (`InlineAreaAnnotateSession.cursorHider`) — draw the same crosshair image
          // ourselves instead, mirroring plain area screenshot's `cursorProxyLayer`. Native
          // `NSCursor.set()` is not used here: on this `.nonactivatingPanel` configuration the
          // WindowServer can silently stop rendering it after roughly a second of no new mouse
          // events, even though the app's own cursor bookkeeping stays correct the whole time.
          if let selectingPointerPoint {
            InlineAreaSystemCrosshairProxy(point: selectingPointerPoint)
          }
        }

        if let hoverTip {
          InlineAreaHoverTipLabel(tip: hoverTip, bounds: geometry.size)
            .zIndex(30)
            .allowsHitTesting(false)
        }
      }
      .environment(\.inlineAreaHoverTip) { tip, text in
        if let tip {
          hoverTip = tip
        } else if hoverTip?.text == text {
          hoverTip = nil
        }
      }
      .coordinateSpace(name: InlineAreaCoordinateSpace.root)
      .onContinuousHover(coordinateSpace: .named(InlineAreaCoordinateSpace.root)) { phase in
        switch phase {
        case let .active(location):
          cursorIndicatorPoint = location
          if session.phase == .selecting {
            session.selectionPointerLocation = desktopPoint(for: location)
          }
          updateNativeCursorForIndicator(showsCursorIndicator)
          if session.phase == .selecting {
            session.updateHoveredWindow(atScreenPoint: screenPoint(fromDesktopPoint: desktopPoint(for: location)))
          }
        case .ended:
          cursorIndicatorPoint = nil
          if session.phase == .selecting {
            session.selectionPointerLocation = nil
          }
          InlineAreaNativeCursor.restoreArrow()
          session.hoveredWindowCandidate = nil
          session.hoveredSmartElementRect = nil
        }
      }
      .inlineAreaSelectionGesture(selectionGesture, isEnabled: session.phase == .selecting)
    }
    .ignoresSafeArea()
    .onAppear {
      guard session.phase == .selecting, cursorIndicatorPoint == nil else { return }
      // `onContinuousHover` only reports a position once AppKit delivers an actual hover
      // event, which isn't guaranteed to happen immediately for a window that just appeared
      // under an already-stationary pointer — without this, the magnifier/drawn crosshair can
      // stay invisible until the user moves the mouse. Seed it from the real system location
      // instead, same as a real hover would report.
      let candidate = viewportPoint(for: session.currentDesktopMouseLocation)
      let inBounds = (0 ... display.localFrame.width).contains(candidate.x)
        && (0 ... display.localFrame.height).contains(candidate.y)
      if inBounds {
        cursorIndicatorPoint = candidate
        session.selectionPointerLocation = desktopPoint(for: candidate)
        session.updateHoveredWindow(atScreenPoint: screenPoint(fromDesktopPoint: session.currentDesktopMouseLocation))
      }
    }
  }

  private var selectionGesture: some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .named(InlineAreaCoordinateSpace.root))
      .onChanged { value in
        guard session.phase == .selecting else { return }

        // A highlighted element alone (menu bar, Dock, desktop icons, or before the window
        // list has loaded) is clickable too.
        if pendingWindowSelectionStart == nil, session.selectionRect == nil,
           session.hoverHighlightScreenRect != nil {
          // Don't commit to a manual drag yet — the gesture might resolve as a click on the
          // hovered window instead; crossing the threshold below promotes it to a real drag.
          pendingWindowSelectionStart = value.startLocation
        }

        if let pendingStart = pendingWindowSelectionStart {
          let distance = hypot(value.location.x - pendingStart.x, value.location.y - pendingStart.y)
          guard distance >= windowDetectionDragThreshold else {
            // Still within the click/drag ambiguity window — keep tracking whatever window is
            // under the (still not-yet-a-drag) pointer.
            cursorIndicatorPoint = value.location
            session.updateHoveredWindow(atScreenPoint: screenPoint(fromDesktopPoint: desktopPoint(for: value.location)))
            return
          }
          // Crossed the threshold: this is a drag, not a click. Replay it as a manual selection
          // starting from the original point so the drawn rect matches what was dragged.
          pendingWindowSelectionStart = nil
          session.hoveredWindowCandidate = nil
          session.hoveredSmartElementRect = nil
          cursorIndicatorPoint = value.location
          updateNativeCursorForIndicator(true)
          session.beginSelection(at: desktopPoint(for: pendingStart))
          session.updateSelection(to: desktopPoint(for: value.location))
          return
        }

        let currentLocation = desktopPoint(for: value.location)
        cursorIndicatorPoint = value.location
        updateNativeCursorForIndicator(true)
        session.beginSelection(at: desktopPoint(for: value.startLocation))
        session.updateSelection(to: currentLocation)
      }
      .onEnded { value in
        guard session.phase == .selecting else { return }

        if pendingWindowSelectionStart != nil {
          // Released before crossing the drag threshold: treat it as a click on the hovered
          // window (or, if a finer element was detected, that element) rather than an (empty,
          // sub-threshold) manual region.
          pendingWindowSelectionStart = nil
          // Captures exactly what is highlighted: the element, or the window after Tab.
          if session.hoverTargetsWindows || !session.autoDetectElementUnderCursor {
            if let candidate = session.hoveredWindowCandidate { session.selectWindow(candidate) }
          } else if let smartElementRect = session.hoveredSmartElementRect {
            session.selectElement(atScreenRect: smartElementRect)
          }
          cursorIndicatorPoint = nil
          session.refreshHoverCursor()
          return
        }

        session.endSelection(at: desktopPoint(for: value.location))
        cursorIndicatorPoint = nil
        session.refreshHoverCursor()
      }
  }

  private func rectInViewport(_ desktopRect: CGRect) -> CGRect {
    desktopRect.offsetBy(dx: -display.localFrame.minX, dy: -display.localFrame.minY)
  }

  private func desktopPoint(for viewportPoint: CGPoint) -> CGPoint {
    CGPoint(
      x: viewportPoint.x + display.localFrame.minX,
      y: viewportPoint.y + display.localFrame.minY
    )
  }

  /// Inverse of `desktopPoint(for:)` — converts the session-published desktop point into
  /// this display's viewport space for the selection chrome in `body` (crosshair proxy,
  /// magnifier), and seeds the initial pointer position in `.onAppear`.
  private func viewportPoint(for desktopPoint: CGPoint) -> CGPoint {
    CGPoint(
      x: desktopPoint.x - display.localFrame.minX,
      y: desktopPoint.y - display.localFrame.minY
    )
  }

  /// Inverse of `InlineAreaAnnotateSession.localDesktopPoint(for:)` — converts this session's
  /// desktop coordinate space back to real AppKit global screen coordinates, the space
  /// `WindowCaptureTarget.frame` (and so `WindowSelectionSnapshot.hitTest(at:)`) uses.
  private func screenPoint(fromDesktopPoint point: CGPoint) -> CGPoint {
    CGPoint(x: point.x + session.desktopFrame.minX, y: session.desktopFrame.maxY - point.y)
  }

  /// `AreaSelectionMagnifier` expects AppKit-convention points (bottom-left origin, matching
  /// the `NSView` it was built for); SwiftUI's viewport coordinate space is top-left origin.
  /// Flips against `display.localFrame.height` — the display's actual, already-known size —
  /// rather than a `GeometryReader` measurement, which isn't reliably settled on the very
  /// first frame this view appears and previously produced a wrong (bottom-left-of-screen)
  /// position for the magnifier until the first real pointer move corrected it.
  private func appKitLocalPoint(fromViewportPoint point: CGPoint) -> CGPoint {
    CGPoint(x: point.x, y: display.localFrame.height - point.y)
  }

  private func selectionDimLayer(size: CGSize, rect: CGRect?) -> some View {
    // A value-typed Shape instead of a `Canvas`: SwiftUI skips re-rasterizing it when the
    // hole hasn't moved, so pointer hover no longer repaints a display-sized bitmap.
    InlineAreaSelectionDimShape(hole: rect?.standardized)
      .fill(Color.black.opacity(0.42), style: FillStyle(eoFill: true))
      .frame(width: size.width, height: size.height)
  }

  private func annotateSurface(rect: CGRect, usesBackdropPreview: Bool) -> some View {
    let imageSize = session.state.sourceImage?.size ?? rect.size
    // While an edge is dragged the image is not re-cropped yet. Keep the annotations at 1:1 where
    // they are on screen and only clip them to the preview rect, instead of stretching them into it.
    let canvasRect = session.resizePreviewRect == nil ? rect : (session.selectionRect.map(rectInViewport) ?? rect)
    let canvasOffset = CGSize(width: canvasRect.minX - rect.minX, height: canvasRect.minY - rect.minY)
    let displayScale = max(canvasRect.width / max(imageSize.width, 1), 0.0001)

    return ZStack(alignment: .topLeading) {
      if !usesBackdropPreview, let image = session.state.effectiveSourceImage {
        Image(nsImage: image)
          .resizable()
          .frame(width: rect.width, height: rect.height)
      }

      CanvasDrawingView(
        state: session.state,
        displayScale: displayScale,
        canvasBounds: CGRect(origin: .zero, size: imageSize),
        acceptsFirstMouse: true,
        onCaptureDoubleClick: { session.copyCurrentImage() },
        onSelectionBackgroundDrag: { translation, finished in
          guard let desktopRect = session.selectionRect else { return }
          if movingStartRect == nil {
            movingStartRect = desktopRect
            session.endSelectionSnapping()
          }
          guard let start = movingStartRect else { return }
          let nextRect = session.snappedSelectionPreview(
            for: start.offsetBy(dx: translation.width, dy: translation.height)
          )
          var transaction = Transaction()
          transaction.animation = nil
          withTransaction(transaction) {
            if finished {
              session.moveSelection(to: nextRect, refreshImage: true)
              session.endSelectionSnapping()
              session.movingPreviewRect = nil
              movingStartRect = nil
            } else {
              session.movingPreviewRect = nextRect
            }
          }
        },
        hoverCursorIsExternal: true
      )
      .frame(width: canvasRect.width, height: canvasRect.height)
      .offset(canvasOffset)

      if session.state.editingTextAnnotationId != nil {
        TextEditOverlay(
          state: session.state,
          scale: displayScale,
          canvasBounds: CGRect(origin: .zero, size: imageSize)
        )
        .frame(width: canvasRect.width, height: canvasRect.height)
        .offset(canvasOffset)
      }
    }
    .frame(width: rect.width, height: rect.height, alignment: .topLeading)
    .clipped()
    .overlay(
      selectionBorder(rect: CGRect(origin: .zero, size: rect.size))
        .allowsHitTesting(false)
    )
    .position(x: rect.midX, y: rect.midY)
  }

  private func spaceMoveHitArea(rect: CGRect, desktopRect: CGRect) -> some View {
    Color.clear
      .contentShape(Rectangle())
      .frame(width: rect.width, height: rect.height)
      .position(x: rect.midX, y: rect.midY)
      .gesture(moveGesture(for: desktopRect))
  }

  @ViewBuilder
  private func controls(rect: CGRect, desktopRect: CGRect, containerSize: CGSize) -> some View {
    if session.isRecordingPrep {
      recordingPrepBar(rect: rect, desktopRect: desktopRect, containerSize: containerSize)
    } else {
      captureControls(rect: rect, containerSize: containerSize)
    }
  }

  /// Pinny: the recording prep bar takes the toolbar's place, with the same placement rule.
  private func recordingPrepBar(rect: CGRect, desktopRect: CGRect, containerSize: CGSize) -> some View {
    let placement = InlineAreaControlGeometry.placement(
      for: rect, containerSize: containerSize,
      showsProperties: false, propertiesContentWidth: 0,
      controlInsets: display.controlInsets,
      toolbarWidth: PinnyRecordingPrepBar.width(showsBack: session.recordingPrepReturnsToPlayback)
    )
    let scale = NSScreen.screens.first { $0.frame == display.screenFrame }?.backingScaleFactor ?? 2
    let pixelSize = CGSize(width: (desktopRect.width * scale).rounded(), height: (desktopRect.height * scale).rounded())
    return PinnyRecordingPrepBar(session: session, pixelSize: pixelSize)
      .frame(width: placement.toolbarWidth, height: InlineAreaLayout.toolbarHeight)
      .inlineAreaPanelChrome()
      .position(placement.toolbarCenter)
      .zIndex(10)
      .transaction { $0.animation = nil }
  }

  @ViewBuilder
  private func captureControls(rect: CGRect, containerSize: CGSize) -> some View {
    let showsDetails = session.state.showsQuickPropertiesBar || session.actionMessage != nil
    let insets = display.controlInsets
    let placement = controlPlacement(
      for: rect, containerSize: containerSize,
      showsProperties: showsDetails, propertiesContentWidth: 0,
      controlInsets: insets
    )

    let propertiesAbove = showsDetails && placement.propertiesCenter.y < placement.toolbarCenter.y
    InlineAreaControlDeck(session: session, maxWidth: placement.toolbarWidth, tipsAbove: !propertiesAbove)
      .frame(width: placement.toolbarWidth, height: InlineAreaLayout.toolbarHeight)
      .inlineAreaPanelChrome()
      .position(placement.toolbarCenter)
      .zIndex(10)
      .transaction { $0.animation = nil }

    if showsDetails {
      // Pinny: the secondary bar is its own capsule 8 pt beyond the toolbar, on the side away from
      // the selection. It hugs its content and shares the toolbar's right edge, shifting only
      // when a screen edge would clip it.
      let available = max(0, containerSize.width - insets.controlLeadingPadding - insets.controlTrailingPadding)
      let width = min(available, propertiesContentWidth)
      let toolbarRight = placement.toolbarCenter.x + placement.toolbarWidth / 2
      let left = clamped(toolbarRight - width, min: insets.controlLeadingPadding,
                         max: containerSize.width - insets.controlTrailingPadding - width)
      Group {
        if let message = session.actionMessage {
          Text(message)
            .font(.system(size: 12))
            .lineLimit(2)
            .padding(.horizontal, 14)
            .frame(maxWidth: available, alignment: .leading)
            .fixedSize()
            .accessibilityIdentifier("inline.actionFeedback")
        } else {
          InlineAreaPropertiesBar(
            state: session.state, maxWidth: available,
            popoverEdge: placement.propertiesPopoverEdge
          )
        }
      }
      .frame(height: InlineAreaLayout.propertiesHeight)
      .background(
        GeometryReader { proxy in
          Color.clear.preference(key: InlineAreaPropertiesContentWidthKey.self, value: proxy.size.width)
        }
      )
      .inlineAreaPanelChrome(cornerRadius: InlineAreaChrome.propertiesBarCornerRadius)
      .environment(\.inlineAreaHoverTipAbove, propertiesAbove)
      .position(x: left + width / 2, y: placement.propertiesCenter.y)
      .opacity(propertiesContentWidth > 0 ? 1 : 0)
      .zIndex(10)
      .transaction { $0.animation = nil }
      .onPreferenceChange(InlineAreaPropertiesContentWidthKey.self) { propertiesContentWidth = $0 }
    }
  }

  private func moveGesture(for desktopRect: CGRect) -> some Gesture {
    DragGesture(minimumDistance: 2, coordinateSpace: .named(InlineAreaCoordinateSpace.root))
      .onChanged { value in
        guard activeResizeHandle == nil else { return }
        if movingStartRect == nil {
          movingStartRect = desktopRect
          session.endSelectionSnapping()
        }
        guard let start = movingStartRect else { return }
        let previewRect = session.snappedSelectionPreview(
          for: start.offsetBy(dx: value.translation.width, dy: value.translation.height)
        )
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
          cursorIndicatorPoint = value.location
          session.movingPreviewRect = previewRect
        }
        updateNativeCursorForIndicator(true)
      }
      .onEnded { value in
        let start = movingStartRect ?? desktopRect
        let finalRect = session.snappedSelectionPreview(
          for: start.offsetBy(dx: value.translation.width, dy: value.translation.height)
        )
        session.endSelectionSnapping()
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
          session.moveSelection(to: finalRect, refreshImage: true)
          session.movingPreviewRect = nil
          movingStartRect = nil
        }
        cursorIndicatorPoint = nil
        session.refreshHoverCursor()
      }
  }

  @ViewBuilder
  private func resizeHandles(rect: CGRect, desktopRect: CGRect) -> some View {
    InlineAreaResizeHandlesOverlay()
      .frame(width: rect.width, height: rect.height)
      .position(x: rect.midX, y: rect.midY)
      .allowsHitTesting(false)

    ForEach(InlineAreaResizeHandle.allCases) { handle in
      InlineAreaResizeHandleHitTarget(handle: handle, size: handle.hitSize(in: rect))
        .position(handle.position(in: rect))
        .gesture(resizeGesture(
          for: handle,
          desktopRect: desktopRect,
          containerSize: session.desktopFrame.size
        ))
    }
  }

  private func resizeGesture(
    for handle: InlineAreaResizeHandle,
    desktopRect: CGRect,
    containerSize: CGSize
  ) -> some Gesture {
    DragGesture(minimumDistance: 1, coordinateSpace: .global)
      .onChanged { value in
        if resizingStartRect == nil {
          resizingStartRect = desktopRect
          session.endSelectionSnapping()
        }
        guard let start = resizingStartRect else { return }
        let previewRect = session.snappedSelectionPreview(
          for: resizedSelectionRect(
            from: start,
            handle: handle,
            translation: value.translation,
            containerSize: containerSize
          ),
          resizing: handle.snapEdges
        )
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
          activeResizeHandle = handle
          session.movingPreviewRect = nil
          session.resizePreviewRect = previewRect
        }
      }
      .onEnded { value in
        let start = resizingStartRect ?? desktopRect
        let finalRect = session.snappedSelectionPreview(
          for: resizedSelectionRect(
            from: start,
            handle: handle,
            translation: value.translation,
            containerSize: containerSize
          ),
          resizing: handle.snapEdges
        )
        session.endSelectionSnapping()
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
          session.resizeSelection(to: finalRect, previousRect: start)
          session.resizePreviewRect = nil
          resizingStartRect = nil
          activeResizeHandle = nil
        }
      }
  }

  private func resizedSelectionRect(
    from start: CGRect,
    handle: InlineAreaResizeHandle,
    translation: CGSize,
    containerSize: CGSize
  ) -> CGRect {
    let rect = start.standardized
    // A selection already smaller than the minimum (a small icon picked by click) keeps its
    // size as the floor, so touching an edge does not make it jump.
    let minSize = min(InlineAreaLayout.minimumSelectionSize, rect.width, rect.height)
    var minX = rect.minX
    var maxX = rect.maxX
    var minY = rect.minY
    var maxY = rect.maxY

    if handle.adjustsLeft {
      minX = clamped(rect.minX + translation.width, min: 0, max: maxX - minSize)
    }
    if handle.adjustsRight {
      maxX = clamped(rect.maxX + translation.width, min: minX + minSize, max: containerSize.width)
    }
    if handle.adjustsTop {
      minY = clamped(rect.minY + translation.height, min: 0, max: maxY - minSize)
    }
    if handle.adjustsBottom {
      maxY = clamped(rect.maxY + translation.height, min: minY + minSize, max: containerSize.height)
    }

    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).standardized
  }

  private func selectionBorder(rect: CGRect) -> some View {
    Rectangle()
      .strokeBorder(Color.white, lineWidth: InlineAreaResizeHandleChrome.borderWidth)
      .frame(width: rect.width, height: rect.height)
      .position(x: rect.midX, y: rect.midY)
  }

  private func controlPlacement(
    for rect: CGRect,
    containerSize: CGSize,
    showsProperties: Bool,
    propertiesContentWidth: CGFloat,
    controlInsets: InlineAreaControlInsets
  ) -> InlineAreaControlPlacement {
    InlineAreaControlGeometry.placement(
      for: rect,
      containerSize: containerSize,
      showsProperties: showsProperties,
      propertiesContentWidth: propertiesContentWidth,
      controlInsets: controlInsets
    )
  }

  private func clamped(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
    guard minValue <= maxValue else { return value }
    return min(max(value, minValue), maxValue)
  }

  /// Only relevant to `.annotating`-phase moving (`InlineAreaCursorIndicator`) — during
  /// `.selecting` the real cursor is already hidden for the whole phase
  /// (`InlineAreaAnnotateSession.cursorHider`) and `InlineAreaSystemCrosshairProxy` draws the
  /// crosshair instead, so there's nothing for this to do there.
  private func updateNativeCursorForIndicator(_ isIndicatorVisible: Bool) {
    guard session.phase != .selecting else { return }
    if isIndicatorVisible {
      InlineAreaNativeCursor.hide()
    } else {
      session.refreshHoverCursor()
    }
  }
}

enum InlineAreaCoordinateSpace {
  static let root = "inline-area-annotate-root"
}

/// Bridges the shared `AreaSelectionMagnifier` (an AppKit/CALayer component) into this
/// SwiftUI-based selection view so screenshot-and-annotate shows the identical magnifier used
/// by plain area screenshot capture, instead of a second reimplementation. `point` is already
/// converted to AppKit-local coordinates by the caller; nil hides the magnifier without
/// tearing down the host view (which would drop the session's registration of it).
private struct InlineAreaMagnifierOverlay: NSViewRepresentable {
  let backdropImage: CGImage?
  let point: CGPoint?
  let hostSize: CGSize
  let showsByDefault: Bool
  let showsColorPanel: Bool
  let onHostViewReady: (InlineAreaMagnifierHostView) -> Void

  func makeNSView(context: Context) -> InlineAreaMagnifierHostView {
    let view = InlineAreaMagnifierHostView(frame: CGRect(origin: .zero, size: hostSize))
    view.displayBounds = CGRect(origin: .zero, size: hostSize)
    view.magnifier.showsColorPanel = showsColorPanel
    // Mirrors plain area screenshot capture: coordinates live in the magnifier panel while
    // it's active, and in `InlineAreaMagnifierHostView`'s own bubble (its equivalent of
    // `updateCoordinateIndicator`) while it's inactive — never both at once.
    view.magnifier.showsCoordinatesInPanel = true
    view.magnifier.resetZoom(showByDefault: showsByDefault)
    onHostViewReady(view)
    return view
  }

  func updateNSView(_ nsView: InlineAreaMagnifierHostView, context: Context) {
    // Set explicitly rather than read off `nsView.bounds`: AppKit only applies the frame from
    // this view's `.frame(width:height:)` SwiftUI modifier once its own layout pass runs, which
    // isn't guaranteed to have happened by the time `update(at:)` first fires — see
    // `InlineAreaMagnifierHostView.displayBounds`.
    nsView.displayBounds = CGRect(origin: .zero, size: hostSize)
    nsView.backdropImage = backdropImage
    if let point {
      nsView.update(at: point)
    } else {
      nsView.hide()
    }
  }
}

private struct InlineAreaCursorIndicator: View {
  let point: CGPoint

  private let frameSize: CGFloat = 28
  private let lineLength: CGFloat = 10

  var body: some View {
    Canvas { context, size in
      let center = CGPoint(x: size.width / 2, y: size.height / 2)
      var path = Path()
      path.move(to: CGPoint(x: center.x, y: center.y - lineLength))
      path.addLine(to: CGPoint(x: center.x, y: center.y + lineLength))
      path.move(to: CGPoint(x: center.x - lineLength, y: center.y))
      path.addLine(to: CGPoint(x: center.x + lineLength, y: center.y))

      context.stroke(path, with: .color(.black.opacity(0.5)), lineWidth: 4)
      context.stroke(path, with: .color(.white), lineWidth: 1.5)
    }
    .frame(width: frameSize, height: frameSize)
    .position(point)
    .allowsHitTesting(false)
  }
}

/// Drawn replacement for the real system cursor during `.selecting`, mirroring plain area
/// screenshot's `cursorProxyLayer`: draws the exact same crosshair image
/// (`NSCursor.vectorScreenshotCrosshairLight`) the real cursor would otherwise use, so the two
/// entry points look pixel-identical, while sidestepping the WindowServer's tendency to stop
/// rendering a native `NSCursor.set()` cursor on this `.nonactivatingPanel` configuration after
/// a period of no new mouse events (see `InlineAreaAnnotateSession.cursorHider`).
private struct InlineAreaSystemCrosshairProxy: View {
  let point: CGPoint

  var body: some View {
    Image(nsImage: NSCursor.vectorScreenshotCrosshairLight.image)
      .position(point)
      .allowsHitTesting(false)
  }
}

private enum InlineAreaNativeCursor {
  private static let hiddenCursor: NSCursor = {
    let image = NSImage(size: NSSize(width: 1, height: 1))
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: 1,
      pixelsHigh: 1,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 4,
      bitsPerPixel: 32
    )
    if let rep {
      if let bitmapData = rep.bitmapData {
        for offset in 0 ..< (rep.bytesPerRow * rep.pixelsHigh) {
          bitmapData[offset] = 0
        }
      }
      image.addRepresentation(rep)
    }
    return NSCursor(image: image, hotSpot: .zero)
  }()

  static func hide() {
    hiddenCursor.set()
  }

  static func restoreArrow() {
    NSCursor.arrow.set()
  }
}

private struct InlineAreaSelectionGestureModifier<SelectionGesture: Gesture>: ViewModifier {
  let selectionGesture: SelectionGesture
  let isEnabled: Bool

  func body(content: Content) -> some View {
    if isEnabled {
      content
        .contentShape(Rectangle())
        .gesture(selectionGesture)
    } else {
      content
    }
  }
}

private extension View {
  func inlineAreaSelectionGesture<SelectionGesture: Gesture>(
    _ selectionGesture: SelectionGesture,
    isEnabled: Bool
  ) -> some View {
    modifier(InlineAreaSelectionGestureModifier(
      selectionGesture: selectionGesture,
      isEnabled: isEnabled
    ))
  }
}

struct InlineAreaControlInsets: Equatable {
  var top: CGFloat
  var leading: CGFloat
  var bottom: CGFloat
  var trailing: CGFloat

  static let zero = InlineAreaControlInsets()

  init(
    top: CGFloat = 0,
    leading: CGFloat = 0,
    bottom: CGFloat = 0,
    trailing: CGFloat = 0
  ) {
    self.top = max(0, top)
    self.leading = max(0, leading)
    self.bottom = max(0, bottom)
    self.trailing = max(0, trailing)
  }

  init(screen: NSScreen) {
    self.init(
      screenFrame: screen.frame,
      visibleFrame: screen.visibleFrame,
      safeAreaInsets: screen.safeAreaInsets
    )
  }

  init(
    screenFrame: CGRect,
    visibleFrame: CGRect,
    safeAreaInsets: NSEdgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
  ) {
    let visibleTop = max(0, screenFrame.maxY - visibleFrame.maxY)
    let visibleLeading = max(0, visibleFrame.minX - screenFrame.minX)
    let visibleBottom = max(0, visibleFrame.minY - screenFrame.minY)
    let visibleTrailing = max(0, screenFrame.maxX - visibleFrame.maxX)

    self.init(
      top: max(visibleTop, safeAreaInsets.top),
      leading: max(visibleLeading, safeAreaInsets.left),
      bottom: max(visibleBottom, safeAreaInsets.bottom),
      trailing: max(visibleTrailing, safeAreaInsets.right)
    )
  }

  var controlTopPadding: CGFloat {
    top + InlineAreaLayout.screenPadding
  }

  var controlLeadingPadding: CGFloat {
    leading + InlineAreaLayout.screenPadding
  }

  var controlBottomPadding: CGFloat {
    bottom + InlineAreaLayout.screenPadding
  }

  var controlTrailingPadding: CGFloat {
    trailing + InlineAreaLayout.screenPadding
  }
}

enum InlineAreaVerticalSide {
  case above
  case below
}

enum InlineAreaResizeHandle: CaseIterable, Identifiable {
  case topLeft
  case top
  case topRight
  case right
  case bottomRight
  case bottom
  case bottomLeft
  case left

  var id: Self {
    self
  }

  var snapEdges: InlineAreaSnapEdges {
    InlineAreaSnapEdges(left: adjustsLeft, right: adjustsRight, top: adjustsTop, bottom: adjustsBottom)
  }

  var adjustsLeft: Bool {
    switch self {
    case .topLeft, .bottomLeft, .left:
      return true
    default:
      return false
    }
  }

  var adjustsRight: Bool {
    switch self {
    case .topRight, .right, .bottomRight:
      return true
    default:
      return false
    }
  }

  var adjustsTop: Bool {
    switch self {
    case .topLeft, .top, .topRight:
      return true
    default:
      return false
    }
  }

  var adjustsBottom: Bool {
    switch self {
    case .bottomLeft, .bottom, .bottomRight:
      return true
    default:
      return false
    }
  }

  var cursor: NSCursor {
    switch self {
    case .top, .bottom:
      return .resizeUpDown
    case .left, .right:
      return .resizeLeftRight
    case .topLeft, .bottomRight:
      return InlineAreaResizeCursor.diagonal(nwse: true)
    case .topRight, .bottomLeft:
      return InlineAreaResizeCursor.diagonal(nwse: false)
    }
  }

  /// The handle whose hit target contains `point` (same rects as the overlay's targets;
  /// corners win where they meet an edge).
  static func handle(at point: CGPoint, in rect: CGRect) -> InlineAreaResizeHandle? {
    let corners: [InlineAreaResizeHandle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
    let edges: [InlineAreaResizeHandle] = [.top, .right, .bottom, .left]
    for handle in corners + edges {
      let size = handle.hitSize(in: rect)
      let center = handle.position(in: rect)
      let target = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                          width: size.width, height: size.height)
      if target.contains(point) { return handle }
    }
    return nil
  }

  /// Continuous edge targets, with disjoint corners taking both resize axes.
  func hitSize(in rect: CGRect) -> CGSize {
    let corner = min(InlineAreaResizeHandleChrome.hitSize, min(rect.width, rect.height) / 2)
    switch self {
    case .top, .bottom:
      return CGSize(width: max(0, rect.width - corner), height: corner)
    case .left, .right:
      return CGSize(width: corner, height: max(0, rect.height - corner))
    default:
      return CGSize(width: corner, height: corner)
    }
  }

  func position(in rect: CGRect) -> CGPoint {
    switch self {
    case .topLeft:
      return CGPoint(x: rect.minX, y: rect.minY)
    case .top:
      return CGPoint(x: rect.midX, y: rect.minY)
    case .topRight:
      return CGPoint(x: rect.maxX, y: rect.minY)
    case .right:
      return CGPoint(x: rect.maxX, y: rect.midY)
    case .bottomRight:
      return CGPoint(x: rect.maxX, y: rect.maxY)
    case .bottom:
      return CGPoint(x: rect.midX, y: rect.maxY)
    case .bottomLeft:
      return CGPoint(x: rect.minX, y: rect.maxY)
    case .left:
      return CGPoint(x: rect.minX, y: rect.midY)
    }
  }
}

private enum InlineAreaResizeHandleChrome {
  static let borderWidth: CGFloat = 1.5
  static let hitSize: CGFloat = 24
  static let cornerLength: CGFloat = 20
  static let edgeLength: CGFloat = 24
  static let thickness: CGFloat = 3
}

private struct InlineAreaResizeHandlesOverlay: View {
  var body: some View {
    Canvas { context, size in
      let rect = CGRect(origin: .zero, size: size)
      let shortestSide = min(rect.width, rect.height)
      let cornerLength = min(
        InlineAreaResizeHandleChrome.cornerLength,
        max(10, shortestSide * 0.38)
      )

      drawCornerHandles(in: rect, length: cornerLength, context: &context)
      drawEdgeHandles(in: rect, cornerLength: cornerLength, context: &context)
    }
  }

  private func drawCornerHandles(
    in rect: CGRect,
    length: CGFloat,
    context: inout GraphicsContext
  ) {
    drawCorner(
      at: CGPoint(x: rect.minX, y: rect.minY),
      corner: .topLeft,
      length: length,
      context: &context
    )
    drawCorner(
      at: CGPoint(x: rect.maxX, y: rect.minY),
      corner: .topRight,
      length: length,
      context: &context
    )
    drawCorner(
      at: CGPoint(x: rect.minX, y: rect.maxY),
      corner: .bottomLeft,
      length: length,
      context: &context
    )
    drawCorner(
      at: CGPoint(x: rect.maxX, y: rect.maxY),
      corner: .bottomRight,
      length: length,
      context: &context
    )
  }

  private func drawCorner(
    at point: CGPoint,
    corner: InlineAreaResizeHandle,
    length: CGFloat,
    context: inout GraphicsContext
  ) {
    let thickness = InlineAreaResizeHandleChrome.thickness

    let horizontalRect: CGRect
    let verticalRect: CGRect

    switch corner {
    case .topLeft:
      horizontalRect = CGRect(x: point.x, y: point.y, width: length, height: thickness)
      verticalRect = CGRect(x: point.x, y: point.y, width: thickness, height: length)
    case .topRight:
      horizontalRect = CGRect(x: point.x - length, y: point.y, width: length, height: thickness)
      verticalRect = CGRect(x: point.x - thickness, y: point.y, width: thickness, height: length)
    case .bottomLeft:
      horizontalRect = CGRect(x: point.x, y: point.y - thickness, width: length, height: thickness)
      verticalRect = CGRect(x: point.x, y: point.y - length, width: thickness, height: length)
    case .bottomRight:
      horizontalRect = CGRect(x: point.x - length, y: point.y - thickness, width: length, height: thickness)
      verticalRect = CGRect(x: point.x - thickness, y: point.y - length, width: thickness, height: length)
    default:
      return
    }

    drawHandleBar(horizontalRect, context: &context)
    drawHandleBar(verticalRect, context: &context)
  }

  private func drawEdgeHandles(
    in rect: CGRect,
    cornerLength: CGFloat,
    context: inout GraphicsContext
  ) {
    let thickness = InlineAreaResizeHandleChrome.thickness
    let minimumGap: CGFloat = 12

    if rect.width >= cornerLength * 2 + minimumGap {
      let length = min(
        InlineAreaResizeHandleChrome.edgeLength,
        max(10, rect.width - cornerLength * 2 - 8)
      )
      let halfLength = length / 2
      drawHandleBar(
        CGRect(x: rect.midX - halfLength, y: rect.minY, width: length, height: thickness),
        context: &context
      )
      drawHandleBar(
        CGRect(x: rect.midX - halfLength, y: rect.maxY - thickness, width: length, height: thickness),
        context: &context
      )
    }

    if rect.height >= cornerLength * 2 + minimumGap {
      let length = min(
        InlineAreaResizeHandleChrome.edgeLength,
        max(10, rect.height - cornerLength * 2 - 8)
      )
      let halfLength = length / 2
      drawHandleBar(
        CGRect(x: rect.minX, y: rect.midY - halfLength, width: thickness, height: length),
        context: &context
      )
      drawHandleBar(
        CGRect(x: rect.maxX - thickness, y: rect.midY - halfLength, width: thickness, height: length),
        context: &context
      )
    }
  }

  private func drawHandleBar(_ rect: CGRect, context: inout GraphicsContext) {
    context.fill(
      Path(rect.offsetBy(dx: 0, dy: 1)),
      with: .color(.black.opacity(0.5))
    )
    context.fill(Path(rect), with: .color(.white))
  }
}

private struct InlineAreaResizeHandleHitTarget: View {
  let handle: InlineAreaResizeHandle
  let size: CGSize

  var body: some View {
    Color.clear
      .frame(width: size.width, height: size.height)
      .contentShape(Rectangle())
  }
}

struct InlineAreaControlPlacement {
  let toolbarWidth: CGFloat
  let propertiesWidth: CGFloat
  let toolbarCenter: CGPoint
  let propertiesCenter: CGPoint
  let propertiesPopoverEdge: Edge
}

/// Pinny toolbar geometry, option C in validation/toolbar-c-all-bars-mockup.html: round 36 pt
/// buttons in a 48 pt capsule (24 = 18 + 6, concentric), groups split by a hairline.
enum InlineAreaToolbarMetrics {
  static let iconButtonSize: CGFloat = 36
  static let iconSize: CGFloat = 20
  static let buttonCornerRadius: CGFloat = iconButtonSize / 2
  static let verticalPadding: CGFloat = 6
  static let toolbarCornerRadius: CGFloat = buttonCornerRadius + verticalPadding
  static let dividerHeight: CGFloat = 22
  static let itemSpacing: CGFloat = 2
  static let groupSpacing: CGFloat = 9
  static let horizontalPadding: CGFloat = 6
  static let hoverAnimation: Animation = ToolbarConstants.hoverAnimation
  static let dividerWidth: CGFloat = 1 + groupSpacing * 2
  static func groupWidth(_ count: Int) -> CGFloat {
    CGFloat(count) * iconButtonSize + CGFloat(max(0, count - 1)) * itemSpacing
  }
  static var toolsWidth: CGFloat {
    let groups = AnnotateToolVisibility.visibleInlineToolGroups()
    return groups.reduce(0) { $0 + groupWidth($1.count) } + CGFloat(groups.count - 1) * dividerWidth
  }
  static var idealWidth: CGFloat {
    horizontalPadding * 2 + toolsWidth + groupWidth(2) + groupWidth(2) + groupWidth(4) + dividerWidth * 3
  }
}

enum InlineAreaLayout {
  static let toolbarHeight: CGFloat = InlineAreaToolbarMetrics.iconButtonSize + InlineAreaToolbarMetrics.verticalPadding * 2
  /// The secondary bar is its own capsule under the toolbar: 28 pt controls + 6 pt padding.
  static let propertiesHeight: CGFloat = InlineAreaChrome.propertyControlHeight + 12
  static let controlStackSpacing: CGFloat = 8
  static let selectionGap: CGFloat = 12
  static let screenPadding: CGFloat = 16
  static let controlPanelOuterHorizontalInset: CGFloat = 12
  static let minimumSelectionSize: CGFloat = 24
  static func reservedControlHeight(showsProperties: Bool) -> CGFloat {
    if showsProperties {
      return toolbarHeight + controlStackSpacing + propertiesHeight
    }
    return toolbarHeight
  }
}

enum InlineAreaControlGeometry {
  static func placement(
    for rect: CGRect,
    containerSize: CGSize,
    showsProperties: Bool,
    propertiesContentWidth: CGFloat,
    controlInsets: InlineAreaControlInsets,
    toolbarWidth preferredToolbarWidth: CGFloat? = nil
  ) -> InlineAreaControlPlacement {
    let toolbarWidth = preferredToolbarWidth.map {
      min($0, availableControlWidth(for: containerSize, controlInsets: controlInsets))
    } ?? controlDeckWidth(
      for: containerSize,
      controlInsets: controlInsets
    )
    let propertiesWidth = propertiesBarWidth(
      for: containerSize,
      toolbarWidth: toolbarWidth,
      showsProperties: showsProperties,
      contentWidth: propertiesContentWidth,
      controlInsets: controlInsets
    )
    // Right-aligned to the selection: a drag ends at its bottom-right corner, where the pointer
    // already is. The secondary bar shares the main bar's right edge.
    let toolbarX = clampedControlCenterX(
      rect.maxX - toolbarWidth / 2,
      width: toolbarWidth,
      containerSize: containerSize,
      controlInsets: controlInsets
    )
    let propertiesX = clampedControlCenterX(
      toolbarX + toolbarWidth / 2 - propertiesWidth / 2,
      width: propertiesWidth,
      containerSize: containerSize,
      controlInsets: controlInsets
    )
    // Above or below is decided by the main bar alone, so opening the secondary bar never moves
    // the main bar; the secondary bar opens on the side facing away from the selection.
    let verticalSide = preferredVerticalSide(
      for: rect,
      containerSize: containerSize,
      showsProperties: false,
      controlInsets: controlInsets
    )
    let centers = controlCenters(
      for: rect,
      side: verticalSide,
      containerSize: containerSize,
      showsProperties: showsProperties,
      controlInsets: controlInsets
    )
    return InlineAreaControlPlacement(
      toolbarWidth: toolbarWidth,
      propertiesWidth: propertiesWidth,
      toolbarCenter: CGPoint(x: toolbarX, y: centers.toolbar),
      propertiesCenter: CGPoint(x: propertiesX, y: centers.properties),
      // Popovers open away from the main bar so they never cover it.
      propertiesPopoverEdge: centers.properties < centers.toolbar ? .top : .bottom
    )
  }

  private static func controlDeckWidth(
    for containerSize: CGSize,
    controlInsets: InlineAreaControlInsets
  ) -> CGFloat {
    min(InlineAreaToolbarMetrics.idealWidth, availableControlWidth(for: containerSize, controlInsets: controlInsets))
  }

  private static func propertiesBarWidth(
    for containerSize: CGSize,
    toolbarWidth: CGFloat,
    showsProperties: Bool,
    contentWidth: CGFloat,
    controlInsets: InlineAreaControlInsets
  ) -> CGFloat {
    let availableWidth = availableControlWidth(for: containerSize, controlInsets: controlInsets)
    guard showsProperties else {
      return min(toolbarWidth, availableWidth)
    }

    let measuredContentWidth = contentWidth + InlineAreaLayout.controlPanelOuterHorizontalInset
    let measuredWidth = contentWidth > 0 ? measuredContentWidth : toolbarWidth
    return min(availableWidth, max(toolbarWidth, measuredWidth))
  }

  private static func availableControlWidth(
    for containerSize: CGSize,
    controlInsets: InlineAreaControlInsets
  ) -> CGFloat {
    max(
      0,
      containerSize.width - controlInsets.controlLeadingPadding - controlInsets.controlTrailingPadding
    )
  }

  private static func clampedControlCenterX(
    _ preferredX: CGFloat,
    width: CGFloat,
    containerSize: CGSize,
    controlInsets: InlineAreaControlInsets
  ) -> CGFloat {
    let minX = width / 2 + controlInsets.controlLeadingPadding
    let maxX = containerSize.width - width / 2 - controlInsets.controlTrailingPadding
    guard minX <= maxX else {
      return containerSize.width / 2
    }
    return clamped(preferredX, min: minX, max: maxX)
  }

  private static func preferredVerticalSide(
    for rect: CGRect,
    containerSize: CGSize,
    showsProperties: Bool,
    controlInsets: InlineAreaControlInsets
  ) -> InlineAreaVerticalSide {
    let reservedHeight = InlineAreaLayout.reservedControlHeight(showsProperties: showsProperties)
    let aboveSpace = spaceAbove(rect, controlInsets: controlInsets)
    let belowSpace = spaceBelow(rect, containerSize: containerSize, controlInsets: controlInsets)

    // Below the selection by default; move above only when the bottom edge would clip it.
    if belowSpace >= reservedHeight {
      return .below
    }
    if aboveSpace >= reservedHeight {
      return .above
    }
    if rect.minY <= controlInsets.controlTopPadding + InlineAreaLayout.selectionGap {
      return .below
    }
    return belowSpace >= aboveSpace ? .below : .above
  }

  private static func controlCenters(
    for rect: CGRect,
    side: InlineAreaVerticalSide,
    containerSize: CGSize,
    showsProperties: Bool,
    controlInsets: InlineAreaControlInsets
  ) -> (toolbar: CGFloat, properties: CGFloat) {
    let toolbarHeight = InlineAreaLayout.toolbarHeight
    let propertiesHeight = InlineAreaLayout.propertiesHeight
    let spacing = InlineAreaLayout.controlStackSpacing
    let top = controlInsets.controlTopPadding
    let bottom = containerSize.height - controlInsets.controlBottomPadding

    let rawToolbarCenter: CGFloat
    switch side {
    case .above:
      rawToolbarCenter = rect.minY - InlineAreaLayout.selectionGap - toolbarHeight / 2
    case .below:
      rawToolbarCenter = rect.maxY + InlineAreaLayout.selectionGap + toolbarHeight / 2
    }
    let toolbarCenter = clamped(rawToolbarCenter, min: top + toolbarHeight / 2, max: bottom - toolbarHeight / 2)
    guard showsProperties else { return (toolbarCenter, toolbarCenter) }

    let belowCenter = toolbarCenter + toolbarHeight / 2 + spacing + propertiesHeight / 2
    let aboveCenter = toolbarCenter - toolbarHeight / 2 - spacing - propertiesHeight / 2
    let fitsBelow = belowCenter + propertiesHeight / 2 <= bottom
    let fitsAbove = aboveCenter - propertiesHeight / 2 >= top
    let propertiesCenter: CGFloat
    switch side {
    case .below: propertiesCenter = fitsBelow || !fitsAbove ? belowCenter : aboveCenter
    case .above: propertiesCenter = fitsAbove || !fitsBelow ? aboveCenter : belowCenter
    }
    return (toolbarCenter, propertiesCenter)
  }

  private static func spaceAbove(
    _ rect: CGRect,
    controlInsets: InlineAreaControlInsets
  ) -> CGFloat {
    rect.minY - controlInsets.controlTopPadding - InlineAreaLayout.selectionGap
  }

  private static func spaceBelow(
    _ rect: CGRect,
    containerSize: CGSize,
    controlInsets: InlineAreaControlInsets
  ) -> CGFloat {
    containerSize.height - rect.maxY - controlInsets.controlBottomPadding - InlineAreaLayout.selectionGap
  }

  private static func clamped(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
    guard minValue <= maxValue else { return value }
    return min(max(value, minValue), maxValue)
  }
}

enum InlineAreaChrome {
  static let cornerRadius: CGFloat = InlineAreaToolbarMetrics.toolbarCornerRadius
  static let controlCornerRadius: CGFloat = InlineAreaToolbarMetrics.buttonCornerRadius
  static let controlSize: CGFloat = InlineAreaToolbarMetrics.iconButtonSize
  static let moveControlWidth: CGFloat = 72
  static let propertyControlHeight: CGFloat = 28
  static let propertyCornerRadius: CGFloat = propertyControlHeight / 2
  /// Secondary bar capsule, concentric with its controls (20 = 14 + 6).
  static let propertiesBarCornerRadius: CGFloat = propertyCornerRadius + 6
  static let itemBackground = Color.primary.opacity(0.06)
  static let itemSelectedBackground = Color.primary.opacity(0.12)
  static let itemSelectedForeground = Color.primary
  static let itemSelectedBorder = Color.clear
  static let itemBorder = Color.clear
  static let divider = Color.primary.opacity(0.15)
  static let primaryText = Color.primary.opacity(0.86)
  static let secondaryText = Color.secondary.opacity(0.88)
  static let toolbarIconForeground = Color.primary.opacity(0.85)
  static let toolbarIconSelectedForeground = Color.primary
  static let toolbarIconInactiveToggleForeground = Color.primary.opacity(0.5)
  static let toolbarHoverBackground = Color.primary.opacity(0.10)
}

struct InlineAreaPanelBorder: View {
  var cornerRadius: CGFloat = InlineAreaChrome.cornerRadius
  @Environment(\.colorScheme) var colorScheme

  var body: some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      .strokeBorder(
        colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.12),
        lineWidth: 1.0
      )
  }
}

struct InlineAreaPanelBackgroundTint: View {
  @Environment(\.colorScheme) var colorScheme

  var body: some View {
    if colorScheme == .dark {
      Color.black.opacity(0.25)
    } else {
      Color.white.opacity(0.15)
    }
  }
}

extension View {
  /// Pinny: native Liquid Glass (Regular) on macOS 26+; the hudWindow material stays as the
  /// fallback. Chosen against the hudWindow look in validation/liquid-glass-compare-*.png.
  @ViewBuilder
  func inlineAreaPanelChrome(cornerRadius: CGFloat = InlineAreaChrome.cornerRadius) -> some View {
    if #available(macOS 26.0, *) {
      glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    } else {
      inlineAreaLegacyPanelChrome(cornerRadius: cornerRadius)
    }
  }

  private func inlineAreaLegacyPanelChrome(cornerRadius: CGFloat) -> some View {
    background(InlineAreaPanelBackgroundTint().allowsHitTesting(false))
      .background(InlineAreaHudMaterialBackground(cornerRadius: cornerRadius).allowsHitTesting(false))
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .overlay(InlineAreaPanelBorder(cornerRadius: cornerRadius).allowsHitTesting(false))
      .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 4)
      .shadow(color: Color.black.opacity(0.08), radius: 2, x: 0, y: 1)
  }
}

struct InlineAreaHudMaterialBackground: NSViewRepresentable {
  let cornerRadius: CGFloat

  func makeNSView(context _: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    configure(view)
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context _: Context) {
    configure(nsView)
  }

  private func configure(_ view: NSVisualEffectView) {
    view.material = .hudWindow
    view.state = .active
    view.blendingMode = .withinWindow
    view.wantsLayer = true
    view.layer?.cornerRadius = cornerRadius
    view.layer?.cornerCurve = .continuous
    view.layer?.masksToBounds = true

    // Explicitly set vibrancy appearance to match color scheme
    let isDark = ThemeManager.shared.systemAppearance == .dark
    view.appearance = NSAppearance(named: isDark ? .vibrantDark : .vibrantLight)
  }
}

/// Diagonal resize cursor for corners. macOS 15+ has the system one (black arrows with a white
/// outline, like `resizeUpDown` / `resizeLeftRight`); older systems get a drawn one in the
/// same black-on-white style.
enum InlineAreaResizeCursor {
  static func diagonal(nwse: Bool) -> NSCursor {
    if #available(macOS 15.0, *) {
      return NSCursor.frameResize(position: nwse ? .topLeft : .topRight, directions: .all)
    }
    return nwse ? legacyNWSE : legacyNESW
  }

  private static let legacyNWSE = drawn(nwse: true)
  private static let legacyNESW = drawn(nwse: false)

  private static func drawn(nwse: Bool) -> NSCursor {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size, flipped: false) { _ in
      let path = NSBezierPath()
      path.lineCapStyle = .round
      path.lineJoinStyle = .round
      let (a, b): (NSPoint, NSPoint) = nwse
        ? (NSPoint(x: 4, y: 14), NSPoint(x: 14, y: 4))
        : (NSPoint(x: 14, y: 14), NSPoint(x: 4, y: 4))
      path.move(to: a); path.line(to: b)
      for (tip, other) in [(a, b), (b, a)] {
        let dx: CGFloat = other.x > tip.x ? 4.5 : -4.5
        let dy: CGFloat = other.y > tip.y ? 4.5 : -4.5
        path.move(to: NSPoint(x: tip.x + dx, y: tip.y)); path.line(to: tip)
        path.line(to: NSPoint(x: tip.x, y: tip.y + dy))
      }
      NSColor.white.setStroke()
      path.lineWidth = 4
      path.stroke()
      NSColor.black.setStroke()
      path.lineWidth = 1.8
      path.stroke()
      return true
    }
    return NSCursor(image: image, hotSpot: NSPoint(x: 9, y: 9))
  }
}

struct InlineAreaControlDeck: View {
  @ObservedObject var session: InlineAreaAnnotateSession
  let maxWidth: CGFloat
  /// Tips open away from the secondary bar: above unless that bar sits above the toolbar.
  var tipsAbove = true

  var body: some View {
    HStack(spacing: 0) {
      // Tools can scroll, while history and output actions stay in stable, visible groups.
      ScrollView(.horizontal, showsIndicators: true) {
        HStack(spacing: 0) {
          ForEach(Array(AnnotateToolVisibility.visibleInlineToolGroups().enumerated()), id: \.offset) { index, tools in
            if index > 0 { InlineAreaDivider() }
            InlineAreaToolGroup(tools: tools, selectedTool: session.state.selectedTool,
                                familyChoice: session.state.inlineFamilyChoice(for:)) { tool in
              session.actionMessage = nil
              session.state.activateTool(tool)
            }
          }
        }
        .fixedSize(horizontal: true, vertical: false)
      }
      .frame(maxWidth: InlineAreaToolbarMetrics.toolsWidth)
      .overlay(alignment: .trailing) {
        if maxWidth < InlineAreaToolbarMetrics.idealWidth {
          Image("CaptureTool-overflow").renderingMode(.template).resizable()
            .frame(width: 12, height: 12)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
      }
      InlineAreaDivider()
      HStack(spacing: InlineAreaToolbarMetrics.itemSpacing) {
        InlineAreaIconButton(icon: "undo", tooltip: L10n.Common.undo,
                             isEnabled: session.state.canUndo) {
          session.actionMessage = nil
          session.state.undo()
        }
        InlineAreaIconButton(icon: "redo", tooltip: L10n.Common.redo,
                             isEnabled: session.state.canRedo) {
          session.actionMessage = nil
          session.state.redo()
        }
      }.fixedSize()
      InlineAreaDivider()
      InlineAreaCaptureActions(session: session).fixedSize()
    }
    .padding(.horizontal, InlineAreaToolbarMetrics.horizontalPadding)
    .frame(width: maxWidth, height: InlineAreaLayout.toolbarHeight)
    .environment(\.inlineAreaHoverTipAbove, tipsAbove)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("inline.captureToolbar")
  }
}

/// Pinny: hover labels for the capture overlay. Native `.help` tooltips never appear on this
/// full-screen non-activating panel, and the toolbar clips its content, so each control
/// reports its frame and the root view draws the label above everything.
struct InlineAreaHoverTip: Equatable {
  let text: String
  let frame: CGRect
  /// Main toolbar labels go above it and properties bar labels below, so neither covers the
  /// other row; either flips when the screen edge is too close.
  var prefersAbove = false
}

private struct InlineAreaHoverTipKey: EnvironmentKey {
  static let defaultValue: ((InlineAreaHoverTip?, String) -> Void)? = nil
}

private struct InlineAreaHoverTipAboveKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// Shows a hover label, or hides the one with this text (nil); nil outside the overlay.
  var inlineAreaHoverTip: ((InlineAreaHoverTip?, String) -> Void)? {
    get { self[InlineAreaHoverTipKey.self] }
    set { self[InlineAreaHoverTipKey.self] = newValue }
  }

  var inlineAreaHoverTipAbove: Bool {
    get { self[InlineAreaHoverTipAboveKey.self] }
    set { self[InlineAreaHoverTipAboveKey.self] = newValue }
  }
}

private struct InlineAreaHelpModifier: ViewModifier {
  let text: String
  @Environment(\.inlineAreaHoverTip) private var report
  @Environment(\.inlineAreaHoverTipAbove) private var prefersAbove
  @State private var frame: CGRect = .zero
  @State private var pending: Task<Void, Never>?
  @State private var isShowing = false

  func body(content: Content) -> some View {
    if let report {
      content
        .background(GeometryReader { proxy in
          let current = proxy.frame(in: .named(InlineAreaCoordinateSpace.root))
          Color.clear
            .onAppear { frame = current }
            .onChange(of: current) { newValue in
              frame = newValue
              // The toolbar moved under a showing tip (arrow keys move the selection).
              if isShowing {
                report(InlineAreaHoverTip(text: text, frame: newValue, prefersAbove: prefersAbove), text)
              }
            }
        })
        .onHover { hovering in
          pending?.cancel()
          guard hovering else {
            isShowing = false
            report(nil, text)
            return
          }
          pending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            isShowing = true
            report(InlineAreaHoverTip(text: text, frame: frame, prefersAbove: prefersAbove), text)
          }
        }
        .onDisappear {
          pending?.cancel()
          isShowing = false
          report(nil, text)
        }
    } else {
      content.help(text)
    }
  }
}

private struct InlineAreaPopoverRegistration: ViewModifier {
  @Binding var isPresented: Bool
  @State private var id = UUID()

  func body(content: Content) -> some View {
    content
      .onChange(of: isPresented) { presented in
        if presented {
          InlineAreaPopoverStack.push(id) { isPresented = false }
        } else {
          InlineAreaPopoverStack.remove(id)
        }
      }
      .onDisappear { InlineAreaPopoverStack.remove(id) }
  }
}

extension View {
  /// Lets the capture session see this popover is open (see `InlineAreaPopoverStack`).
  func inlineAreaPopoverRegistration(isPresented: Binding<Bool>) -> some View {
    modifier(InlineAreaPopoverRegistration(isPresented: isPresented))
  }

  /// Hover label for a capture overlay control; a native tooltip anywhere else.
  func inlineAreaHelp(_ text: String) -> some View {
    modifier(InlineAreaHelpModifier(text: text))
  }
}

/// Next to the control on its preferred side, or the other side when the screen edge is too
/// close.
private struct InlineAreaHoverTipLabel: View {
  let tip: InlineAreaHoverTip
  let bounds: CGSize

  var body: some View {
    Text(tip.text)
      .font(.system(size: 12, weight: .medium))
      .foregroundColor(.white)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.82))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(Color.white.opacity(0.12), lineWidth: 1)
      )
      .alignmentGuide(.leading) { $0[HorizontalAlignment.center] - clampedCenterX($0.width) }
      .alignmentGuide(.top) { dimension in
        let above = tip.frame.minY - 6 - dimension.height
        let below = tip.frame.maxY + 6
        let fitsAbove = above >= 4
        let fitsBelow = below + dimension.height <= bounds.height - 4
        let y = tip.prefersAbove ? (fitsAbove ? above : below) : (fitsBelow ? below : above)
        return -y
      }
  }

  private func clampedCenterX(_ width: CGFloat) -> CGFloat {
    min(max(tip.frame.midX, width / 2 + 4), bounds.width - width / 2 - 4)
  }
}

/// Pinny: a selection shortcut on the capture overlay: a label and its key, all in one style.
/// The key cap sits the same distance from the top, bottom and right edges, with a concentric
/// corner radius.
private struct InlineAreaKeyChip: View {
  let title: String
  let key: String
  var action: (() -> Void)?

  /// A dark capsule that stays readable over the dimmed screen whatever is under it; the
  /// key capsule is concentric with the chip (16 = 10 + 6).
  private static let height: CGFloat = 32
  private static let inset: CGFloat = 6
  private static let keyHeight: CGFloat = height - inset * 2
  @State private var isHovering = false

  var body: some View {
    let chip = HStack(spacing: 8) {
      Text(title)
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(.white)
      Text(key)
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(Color.white.opacity(0.88))
        .padding(.horizontal, 7)
        .frame(minWidth: Self.keyHeight, minHeight: Self.keyHeight)
        .background(Capsule().fill(Color.white.opacity(0.16)))
    }
    .padding(.leading, 12)
    .padding(.trailing, Self.inset)
    .frame(height: Self.height)
    .background(
      Capsule().fill(Color(white: 0.11).opacity(isHovering && action != nil ? 0.92 : 0.82))
    )
    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
    .shadow(color: Color.black.opacity(0.28), radius: 7, x: 0, y: 4)
    .contentShape(Capsule())
    .fixedSize()

    if let action {
      Button(action: action) { chip }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    } else {
      chip
    }
  }
}

struct InlineAreaToolbarButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.96 : 1)
      .opacity(configuration.isPressed && isEnabled ? 0.8 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
  }
}

/// Hugeicons Pro asset `CaptureTool-<name>`; selected items use the solid `-fill` variant when one exists.
struct InlineAreaGlyph: View {
  let name: String
  var isSelected = false
  let size: CGFloat

  var body: some View {
    Image(Self.assetName(name, isSelected: isSelected))
      .renderingMode(.template).resizable().scaledToFit()
      .frame(width: size, height: size)
  }

  static func assetName(_ name: String, isSelected: Bool) -> String {
    let filled = "CaptureTool-\(name)-fill"
    if isSelected && NSImage(named: filled) != nil { return filled }
    let stroke = "CaptureTool-\(name)"
    return NSImage(named: stroke) != nil ? stroke : "CaptureTool-properties"
  }
}

private struct InlineAreaToolGroup: View {
  let tools: [AnnotationToolType]
  let selectedTool: AnnotationToolType
  let familyChoice: (AnnotationToolType) -> AnnotationToolType
  let action: (AnnotationToolType) -> Void

  var body: some View {
    HStack(spacing: InlineAreaToolbarMetrics.itemSpacing) {
      ForEach(tools, id: \.self) { tool in
        if AnnotationToolType.inlineFamily(of: tool) != nil {
          // One button per family: it shows and draws the family's current tool.
          let family = AnnotateToolVisibility.visibleInlineFamily(of: tool)
          let choice = familyChoice(tool)
          let shown = family.contains(selectedTool) ? selectedTool : (family.contains(choice) ? choice : tool)
          InlineAreaToolButton(tool: shown, selectedTool: selectedTool,
                               isSelectedOverride: family.contains(selectedTool)) {
            action(shown)
          }
        } else {
          InlineAreaToolButton(tool: tool, selectedTool: selectedTool) {
            action(tool)
          }
        }
      }
    }
  }
}

private struct InlineAreaToolButton: View {
  let tool: AnnotationToolType
  let selectedTool: AnnotationToolType
  var isSelectedOverride: Bool?
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      InlineAreaGlyph(name: tool.rawValue, isSelected: isSelected, size: InlineAreaToolbarMetrics.iconSize)
        .foregroundColor(.primary.opacity(isSelected || isHovering ? 1.0 : 0.85))
        .frame(width: InlineAreaChrome.controlSize, height: InlineAreaChrome.controlSize)
        .background(buttonBackground)
        .contentShape(RoundedRectangle(cornerRadius: InlineAreaChrome.controlCornerRadius, style: .continuous))
    }
    .buttonStyle(InlineAreaToolbarButtonStyle())
    .inlineAreaHelp(tool.displayName)
    .accessibilityLabel(tool.displayName)
    .onHover { isHovering = $0 }
    .animation(InlineAreaToolbarMetrics.hoverAnimation, value: isHovering)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var isSelected: Bool {
    isSelectedOverride ?? (selectedTool == tool)
  }

  private var buttonBackground: some View {
    RoundedRectangle(cornerRadius: InlineAreaChrome.controlCornerRadius, style: .continuous)
      .fill(isSelected ? Color.primary.opacity(0.12) : (isHovering ? Color.primary.opacity(0.10) : Color.clear))
  }
}

private struct InlineAreaMoveHandle: View {
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
        .font(.system(size: 12, weight: .medium))

      Text(L10n.AnnotateUI.dragSelection)
        .font(.system(size: 11, weight: .semibold))
        .lineLimit(1)
    }
    .foregroundColor(.primary.opacity(isHovering ? 1.0 : 0.85))
    .frame(width: InlineAreaChrome.moveControlWidth, height: InlineAreaChrome.controlSize)
    .background(
      RoundedRectangle(cornerRadius: InlineAreaChrome.controlCornerRadius, style: .continuous)
        .fill(isHovering ? Color.primary.opacity(0.10) : Color.clear)
    )
    .contentShape(RoundedRectangle(cornerRadius: InlineAreaChrome.controlCornerRadius, style: .continuous))
    .inlineAreaHelp(L10n.AnnotateUI.moveSelection)
    .onHover { isHovering = $0 }
    .animation(InlineAreaToolbarMetrics.hoverAnimation, value: isHovering)
  }
}

struct InlineAreaIconButton: View {
  let icon: String
  let tooltip: String
  var isEnabled: Bool = true
  var isProminent: Bool = false
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Image("CaptureTool-" + icon)
        .renderingMode(.template).resizable().scaledToFit()
        .frame(width: InlineAreaToolbarMetrics.iconSize, height: InlineAreaToolbarMetrics.iconSize)
        .foregroundColor(foregroundColor)
        .frame(width: InlineAreaChrome.controlSize, height: InlineAreaChrome.controlSize)
        .background(background)
        .contentShape(RoundedRectangle(cornerRadius: InlineAreaChrome.controlCornerRadius, style: .continuous))
    }
    .buttonStyle(InlineAreaToolbarButtonStyle())
    .disabled(!isEnabled)
    .opacity(isEnabled ? 1 : 0.42)
    .inlineAreaHelp(tooltip)
    .accessibilityLabel(tooltip)
    .onHover { isHovering = $0 }
    .animation(InlineAreaToolbarMetrics.hoverAnimation, value: isHovering)
  }

  private var foregroundColor: Color {
    isProminent ? Color.accentColor : .primary.opacity(isHovering ? 1.0 : 0.85)
  }

  private var background: some View {
    RoundedRectangle(cornerRadius: InlineAreaChrome.controlCornerRadius, style: .continuous)
      .fill(isProminent ? Color.accentColor.opacity(isHovering ? 0.20 : 0.12) : (isHovering ? Color.primary.opacity(0.10) : Color.clear))
  }
}

struct InlineAreaDivider: View {
  var height: CGFloat = InlineAreaToolbarMetrics.dividerHeight

  var body: some View {
    Rectangle()
      .fill(InlineAreaChrome.divider)
      .frame(width: 1, height: height)
      .padding(.horizontal, InlineAreaToolbarMetrics.groupSpacing)
  }
}

private struct InlineAreaPropertiesBar: View {
  @ObservedObject var state: AnnotateState
  let maxWidth: CGFloat
  let popoverEdge: Edge

  /// Natural width of the controls row; the bar hugs it and scrolls past `maxWidth`.
  @State private var contentWidth: CGFloat = 0

  private let strokeColors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .white, .black]
  private let fillColors: [Color] = [.clear, .red, .orange, .yellow, .green, .blue, .purple, .white, .black]
  private let textBackgroundColors: [Color] = [.clear, .white, .black, .yellow, .blue]

  /// The active family's tools while drawing with a family button; hidden when editing a
  /// selected item.
  private var familyOptions: [AnnotationToolType] {
    guard state.quickPropertiesTool == state.selectedTool else { return [] }
    return AnnotateToolVisibility.visibleInlineFamily(of: state.selectedTool)
  }

  private var strokeColorsForActiveTool: [Color] {
    state.quickPropertiesTool == .spotlight ? [.clear] + strokeColors : strokeColors
  }

  var body: some View {
    HStack(spacing: 0) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 0) {
          if familyOptions.count > 1 {
            InlineAreaSegmentedPicker(
              title: familyOptions.contains(.arrow) ? L10n.AnnotateUI.pinnyLineTool : L10n.AnnotateUI.pinnyShapeTool,
              items: familyOptions,
              selection: Binding(
                get: { state.selectedTool },
                set: { state.activateTool($0) }
              ),
              icon: { $0.rawValue },
              tooltip: \.displayName
            )
          }

          if state.quickPropertiesSupportsStrokeColor {
            InlineAreaColorControl(
              title: colorTitle,
              selectedColor: state.quickStrokeColorBinding,
              colors: strokeColorsForActiveTool,
              role: .annotationStroke,
              popoverEdge: popoverEdge
            )
          }

          if state.quickPropertiesSupportsFill {
            InlineAreaColorControl(
              title: L10n.Common.fill,
              selectedColor: state.quickFillColorBinding,
              colors: fillColors,
              role: .annotationFill,
              popoverEdge: popoverEdge
            )
          }

          if state.quickPropertiesSupportsBlurType {
            InlineAreaSegmentedPicker(
              title: L10n.AnnotateUI.blurType,
              items: BlurType.pinnyChoices,
              selection: state.quickBlurTypeBinding,
              icon: { "blur-\($0.rawValue)" },
              tooltip: \.displayName
            )
          }

          if state.quickPropertiesSupportsWatermark {
            InlineAreaTextFieldControl(title: L10n.Common.text, text: state.quickWatermarkTextBinding)

            InlineAreaSegmentedPicker(
              title: L10n.Common.style,
              items: WatermarkStyle.allCases,
              selection: state.quickWatermarkStyleBinding,
              icon: { "watermark-\($0.rawValue)" },
              tooltip: \.displayName
            )
          }

          if state.quickPropertiesSupportsStrokeWidth {
            InlineAreaSliderControl(
              title: state.quickStrokeWidthLabel,
              icon: state.quickStrokeWidthUsesSizeLabel ? "slider-size" : "slider-stroke",
              value: state.quickStrokeWidthBinding,
              range: AnnotationProperties.controlValueRange,
              step: 1,
              displayText: state.quickStrokeWidthDisplayText,
              onEditingChanged: state.setQuickPropertiesControlEditing
            )
          }

          if state.quickPropertiesSupportsTextFontSize {
            InlineAreaSliderControl(
              title: L10n.Common.size,
              icon: "slider-font",
              value: state.quickTextFontSizeBinding,
              range: 12 ... 72,
              step: 1,
              displayText: "\(Int(state.quickTextFontSizeBinding.wrappedValue.rounded()))",
              onEditingChanged: state.setQuickPropertiesControlEditing
            )
          }

          if state.quickPropertiesSupportsSpotlightOpacity {
            InlineAreaSliderControl(
              title: L10n.AnnotateUI.spotlightOpacity,
              icon: "slider-opacity",
              value: state.quickSpotlightOpacityBinding,
              range: 0.1 ... 0.9,
              step: 0.05,
              displayText: "\(Int((state.quickSpotlightOpacityBinding.wrappedValue * 100).rounded()))%",
              onEditingChanged: state.setQuickPropertiesControlEditing
            )
          }

          if state.quickPropertiesSupportsLineStyle && !collapsesLineOptions {
            InlineAreaLineStylePicker(selection: state.quickLineStyleBinding)
          }

          if state.quickPropertiesSupportsWatermark {
            InlineAreaSliderControl(
              title: L10n.AnnotateUI.watermarkOpacity,
              icon: "slider-opacity",
              value: state.quickWatermarkOpacityBinding,
              range: 0.05 ... 0.65,
              step: 0.01,
              displayText: "\(Int((state.quickWatermarkOpacityBinding.wrappedValue * 100).rounded()))%",
              onEditingChanged: state.setQuickPropertiesControlEditing
            )

            InlineAreaSliderControl(
              title: L10n.Common.rotation,
              icon: "slider-rotation",
              value: state.quickWatermarkRotationBinding,
              range: -45 ... 45,
              step: 1,
              displayText: "\(Int(state.quickWatermarkRotationBinding.wrappedValue.rounded()))deg",
              onEditingChanged: state.setQuickPropertiesControlEditing
            )
          }

        }
        .fixedSize(horizontal: true, vertical: false)
        // Every group leads with a hairline; hide the first one so the bar starts with a control.
        .padding(.leading, -InlineAreaToolbarMetrics.dividerWidth)
        .clipped()
        .padding(.leading, 6)
        .padding(.trailing, hasMoreOptions ? 0 : 6)
        .background(
          GeometryReader { proxy in
            Color.clear.preference(
              key: InlineAreaPropertiesContentWidthKey.self,
              value: proxy.size.width + moreWidth
            )
          }
        )
      }
      .frame(width: min(contentWidth, maxWidth) - moreWidth)

      // Outside the scroll view so it stays in reach when the controls have to scroll.
      if hasMoreOptions {
        InlineAreaMoreControl(popoverEdge: popoverEdge) {
          InlineAreaMoreOptions(
            state: state,
            collapsesLineOptions: collapsesLineOptions,
            textBackgroundColors: textBackgroundColors,
            popoverEdge: popoverEdge
          )
        }
        .padding(.trailing, 6)
      }
    }
    .frame(height: InlineAreaLayout.propertiesHeight)
    .onPreferenceChange(InlineAreaPropertiesContentWidthKey.self) { contentWidth = $0 }
  }

  /// Arrow and line keep their family, color and width in the bar; the rest goes under More.
  private var collapsesLineOptions: Bool {
    state.quickPropertiesSupportsArrowStyle || familyOptions.contains(.arrow)
      || state.quickPropertiesTool == .arrow || state.quickPropertiesTool == .line
  }

  /// Hairline, button and trailing inset of the More control.
  private var moreWidth: CGFloat {
    hasMoreOptions ? InlineAreaToolbarMetrics.dividerWidth + InlineAreaChrome.propertyControlHeight + 6 : 0
  }

  private var hasMoreOptions: Bool {
    state.quickPropertiesSupportsArrowStyle
      || (collapsesLineOptions && state.quickPropertiesSupportsLineStyle)
      || state.quickPropertiesSupportsTextBackground
      || state.quickPropertiesSupportsCornerRadius
  }

  private var colorTitle: String {
    state.quickPropertiesTool == .text ? L10n.Common.text : L10n.Common.color
  }

}

/// The "More" button at the end of the secondary bar: a popover with one titled row per option.
private struct InlineAreaMoreControl<Content: View>: View {
  let popoverEdge: Edge
  @ViewBuilder let content: Content
  @State private var showsPopover = false

  var body: some View {
    InlineAreaPropertyGroup(title: L10n.AnnotateUI.pinnyMoreOptions) {
      Button {
        showsPopover.toggle()
      } label: {
        InlineAreaGlyph(name: "more", size: 16)
          .foregroundColor(showsPopover ? InlineAreaChrome.itemSelectedForeground : InlineAreaChrome.secondaryText)
          .frame(width: InlineAreaChrome.propertyControlHeight, height: InlineAreaChrome.propertyControlHeight)
          .background(
            Circle().fill(showsPopover ? InlineAreaChrome.itemSelectedBackground : Color.clear)
          )
      }
      .buttonStyle(.plain)
      .inlineAreaHelp(L10n.AnnotateUI.pinnyMoreOptions)
      .accessibilityLabel(L10n.AnnotateUI.pinnyMoreOptions)
      .inlineAreaPopoverRegistration(isPresented: $showsPopover)
      .popover(isPresented: $showsPopover, arrowEdge: popoverEdge) {
        VStack(alignment: .leading, spacing: 6) {
          content
        }
        .padding(12)
        .environment(\.inlineAreaPropertyRows, true)
        .environment(\.inlineAreaHoverTip, nil)
      }
    }
  }
}

private struct InlineAreaMoreOptions: View {
  @ObservedObject var state: AnnotateState
  let collapsesLineOptions: Bool
  let textBackgroundColors: [Color]
  let popoverEdge: Edge

  var body: some View {
    if state.quickPropertiesSupportsArrowStyle {
      InlineAreaSegmentedPicker(
        title: L10n.Common.style,
        items: ArrowStyle.allCases,
        selection: state.quickArrowStyleBinding,
        icon: { "arrowstyle-\($0.rawValue)" },
        tooltip: \.displayName
      )

      InlineAreaSegmentedPicker(
        title: L10n.Common.display,
        items: ArrowType.allCases,
        selection: state.quickArrowTypeBinding,
        icon: { "arrowtype-\($0.rawValue)" },
        tooltip: \.displayName
      )

      if state.quickPropertiesSupportsArrowBendDirection {
        InlineAreaArrowBendControl(
          bendDirection: state.quickArrowBendDirectionBinding
        )
      }

      if state.quickPropertiesSupportsArrowEndpoints {
        InlineAreaSegmentedPicker(
          title: L10n.AnnotateUI.arrowStartHead,
          items: ArrowEndpointStyle.allCases,
          selection: state.quickArrowStartHeadBinding,
          icon: { "endpoint-\($0.rawValue)" },
          tooltip: \.displayName
        )

        InlineAreaSegmentedPicker(
          title: L10n.AnnotateUI.arrowEndHead,
          items: ArrowEndpointStyle.allCases,
          selection: state.quickArrowEndHeadBinding,
          icon: { "endpoint-\($0.rawValue)" },
          tooltip: \.displayName
        )
      }
    }

    if collapsesLineOptions && state.quickPropertiesSupportsLineStyle {
      InlineAreaLineStylePicker(selection: state.quickLineStyleBinding)
    }

    if state.quickPropertiesSupportsTextBackground {
      InlineAreaSegmentedPicker(
        title: L10n.AnnotateUI.textStyle,
        items: TextPresentation.allCases,
        selection: Binding(
          get: { state.quickTextPresentation },
          set: { state.setTextPresentation($0) }
        ),
        icon: { "text-\($0.rawValue)" },
        tooltip: \.helpText
      )

      InlineAreaColorControl(
        title: L10n.Common.background,
        selectedColor: state.quickTextBackgroundBinding,
        colors: textBackgroundColors,
        role: .textBackground,
        popoverEdge: popoverEdge
      )
    }

    // Corners are rarely changed, so every tool keeps them here; text shows them only as a
    // label or callout (see `quickPropertiesSupportsCornerRadius`).
    if state.quickPropertiesSupportsCornerRadius {
      InlineAreaSliderControl(
        title: L10n.Common.corners,
        icon: "slider-corners",
        value: state.quickCornerRadiusBinding,
        range: 0 ... 60,
        step: 1,
        displayText: "\(Int(state.quickCornerRadiusBinding.wrappedValue.rounded()))",
        onEditingChanged: state.setQuickPropertiesControlEditing
      )
    }
  }
}

private struct InlineAreaPropertiesContentWidthKey: PreferenceKey {
  static var defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private struct InlineAreaColorControl: View {
  let title: String
  @Binding var selectedColor: Color
  let colors: [Color]
  let role: AnnotateColorPaletteRole
  let popoverEdge: Edge

  @ObservedObject private var paletteStore = AnnotateColorPaletteStore.shared
  @State private var showsPopover = false

  var body: some View {
    InlineAreaPropertyGroup(title: title) {
      HStack(spacing: 2) {
        Button {
          showsPopover.toggle()
        } label: {
          HStack(spacing: 5) {
            InlineAreaColorSwatch(color: selectedColor, isSelected: false, size: 18)
            InlineAreaGlyph(name: "color-dropdown", size: 10)
              .foregroundColor(InlineAreaChrome.secondaryText)
          }
          .frame(width: 48, height: InlineAreaChrome.propertyControlHeight)
          .background(
            RoundedRectangle(cornerRadius: InlineAreaChrome.propertyCornerRadius, style: .continuous)
              .fill(InlineAreaChrome.itemBackground)
          )
        }
        .buttonStyle(.plain)
        .inlineAreaHelp(title)
        .accessibilityLabel(title)
        .inlineAreaPopoverRegistration(isPresented: $showsPopover)
        .popover(isPresented: $showsPopover, arrowEdge: popoverEdge) {
          InlineAreaColorPopover(
            title: title,
            selectedColor: $selectedColor,
            colors: colors,
            role: role
          ) {
            showsPopover = false
          }
          // A popover is its own window; the overlay's self-drawn tips would land in the
          // wrong place, so its buttons fall back to plain help.
          .environment(\.inlineAreaHoverTip, nil)
        }
      }
    }
  }
}

private struct InlineAreaColorPopover: View {
  let title: String
  @Binding var selectedColor: Color
  let colors: [Color]
  let role: AnnotateColorPaletteRole
  let dismiss: () -> Void

  @ObservedObject private var paletteStore = AnnotateColorPaletteStore.shared
  @State private var draftCustomColor = Color.red
  @State private var activeDraftTarget: ColorDraftTarget?
  @State private var originalSelectedColor: Color?
  @State private var showsFavoriteSelectionPopover = false

  private enum ColorDraftTarget {
    case customPalette
    case favorite
  }

  private let columns = Array(repeating: GridItem(.fixed(24), spacing: 8), count: 5)

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(Typography.labelMedium)
        .foregroundColor(.secondary)
        .lineLimit(1)

      let favorites = favoriteColors
      if !favorites.isEmpty {
        Text(L10n.Common.favorite)
          .font(Typography.labelSmall)
          .foregroundColor(.secondary)

        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
          ForEach(favorites, id: \.self) { color in
            favoriteColorButton(color)
          }

          if canAddFavorite {
            favoriteDropSlot
          }
        }
      } else {
        Text(L10n.Common.favorite)
          .font(Typography.labelSmall)
          .foregroundColor(.secondary)

        favoriteEmptyDropTarget
      }

      Divider()

      Text(L10n.Common.colors)
        .font(Typography.labelSmall)
        .foregroundColor(.secondary)

      LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
        ForEach(colors, id: \.self) { color in
          paletteColorButton(color, overlayAction: nil, overlayHelp: "")
        }

        ForEach(paletteStore.customColors, id: \.self) { color in
          paletteColorButton(
            color,
            overlayAction: {
              paletteStore.removeColor(color)
            },
            overlayHelp: L10n.Common.deleteAction
          )
        }

        if activeDraftTarget == .customPalette {
          draftCustomColorButton
        }

        if activeDraftTarget != .customPalette {
          Button {
            beginCustomColorDraft()
          } label: {
            AnnotateAddColorSwatch(size: 22)
          }
          .buttonStyle(.plain)
          .inlineAreaHelp(L10n.Common.custom)
          .accessibilityLabel(L10n.Common.custom)
        }
      }

      if activeDraftTarget == .customPalette {
        colorPickerPanel
          .padding(.top, 2)
      }
    }
    .padding(12)
    .frame(width: 196, alignment: .leading)
    .onAppear {
      syncDraftColor(with: selectedColor)
    }
    .onChange(of: selectedColor) { color in
      syncDraftColor(with: color)
    }
    .onChange(of: favoriteColors.count) { count in
      if count >= AnnotateColorPaletteStore.maximumFavoriteColorCount {
        closeFavoriteSelectionPopover()
      }
    }
    .onDisappear {
      showsFavoriteSelectionPopover = false
      cancelCustomColorDraftIfNeeded(keepFavoriteSelectionPopoverOpen: false)
    }
  }

  private var favoriteColors: [Color] {
    paletteStore.favoriteColors(for: role)
  }

  private var canAddFavorite: Bool {
    favoriteColors.count < AnnotateColorPaletteStore.maximumFavoriteColorCount
  }

  private var favoriteVaultColors: [Color] {
    guard canAddFavorite else { return [] }

    return (colors + paletteStore.customColors).reduce(into: [Color]()) { result, color in
      guard !AnnotateColorPaletteStore.isClear(color),
            !paletteStore.isFavorite(color, for: role),
            !result.contains(where: { AnnotateColorPaletteStore.colorsMatch($0, color) })
      else {
        return
      }

      result.append(color)
    }
  }

  private var favoriteDropSlot: some View {
    InlineAreaFavoriteDropSlot(
      onTap: showFavoriteSelectionPopover
    ) { payload in
      handleFavoriteDrop(payload)
    }
    .popover(isPresented: $showsFavoriteSelectionPopover, arrowEdge: .trailing) {
      favoriteSelectionPopover
    }
  }

  private var favoriteEmptyDropTarget: some View {
    InlineAreaFavoriteEmptyDropTarget(
      onTap: showFavoriteSelectionPopover
    ) { payload in
      handleFavoriteDrop(payload)
    }
    .popover(isPresented: $showsFavoriteSelectionPopover, arrowEdge: .trailing) {
      favoriteSelectionPopover
    }
  }

  private var favoriteSelectionPopover: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(L10n.Common.colors)
        .font(Typography.labelSmall)
        .foregroundColor(.secondary)

      LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
        ForEach(favoriteVaultColors, id: \.self) { color in
          favoriteVaultColorButton(color)
        }

        if activeDraftTarget == .favorite {
          draftFavoriteColorButton
        }

        if activeDraftTarget != .favorite && canAddFavorite {
          Button {
            beginFavoriteColorDraft()
          } label: {
            AnnotateAddColorSwatch(size: 22)
          }
          .buttonStyle(.plain)
          .inlineAreaHelp(L10n.Common.custom)
          .accessibilityLabel(L10n.Common.custom)
        }
      }

      if activeDraftTarget == .favorite {
        colorPickerPanel
          .padding(.top, 2)
      }
    }
    .padding(12)
    .frame(width: 196, alignment: .leading)
    .onDisappear {
      if activeDraftTarget == .favorite {
        cancelColorDraft(keepFavoriteSelectionPopoverOpen: false)
      }
    }
  }

  private var draftFavoriteColorButton: some View {
    InlineAreaColorSwatch(
      color: draftCustomColor,
      isSelected: true,
      size: 22
    )
    .contentShape(Circle())
    .onTapGesture {
      selectedColor = draftCustomColor
    }
    .frame(width: 24, height: 24)
    .inlineAreaHelp(L10n.Common.custom)
  }

  private var draftCustomColorButton: some View {
    InlineAreaColorSwatch(
      color: draftCustomColor,
      isSelected: AnnotateColorPaletteStore.colorsMatch(selectedColor, draftCustomColor),
      size: 22
    )
    .contentShape(Circle())
    .onTapGesture {
      selectedColor = draftCustomColor
    }
    .frame(width: 24, height: 24)
    .inlineAreaHelp(L10n.Common.custom)
  }

  private var colorPickerPanel: some View {
    AnnotateCustomColorPickerPanel(
      selectedColor: $selectedColor,
      draftColor: $draftCustomColor,
      onCancel: {
        cancelColorDraft()
      },
      onApply: applyColorDraft
    )
  }

  private func favoriteVaultColorButton(_ color: Color) -> some View {
    InlineAreaPaletteColorButton(
      color: color,
      title: AnnotateColorPaletteStore.isClear(color) ? L10n.Common.none : title,
      isSelected: AnnotateColorPaletteStore.colorsMatch(selectedColor, color),
      sourceFavoriteRole: nil,
      overlayAction: nil,
      overlayHelp: "",
      onSelect: {
        addVaultColorToFavorites(color)
      }
    )
  }

  private func syncDraftColor(with color: Color) {
    guard !AnnotateColorPaletteStore.isClear(color) else { return }
    draftCustomColor = color
  }

  private func selectColorAndDismiss(_ color: Color) {
    originalSelectedColor = nil
    activeDraftTarget = nil
    showsFavoriteSelectionPopover = false
    selectedColor = color
    dismiss()
  }

  private func beginCustomColorDraft() {
    showsFavoriteSelectionPopover = false
    beginColorDraft(target: .customPalette)
  }

  private func showFavoriteSelectionPopover() {
    guard canAddFavorite else {
      closeFavoriteSelectionPopover()
      return
    }

    if activeDraftTarget == .customPalette {
      cancelColorDraft()
    }

    showsFavoriteSelectionPopover = true
  }

  private func beginFavoriteColorDraft() {
    guard canAddFavorite else {
      closeFavoriteSelectionPopover()
      return
    }

    beginColorDraft(target: .favorite)
  }

  private func beginColorDraft(target: ColorDraftTarget) {
    if activeDraftTarget != nil {
      cancelColorDraft()
    }

    originalSelectedColor = selectedColor
    syncDraftColor(with: selectedColor)
    selectedColor = draftCustomColor
    activeDraftTarget = target
  }

  private func applyColorDraft() {
    guard !AnnotateColorPaletteStore.isClear(draftCustomColor) else { return }

    let target = activeDraftTarget

    switch target {
    case .customPalette:
      paletteStore.addColor(draftCustomColor)
    case .favorite:
      guard canAddFavorite else {
        cancelColorDraft(keepFavoriteSelectionPopoverOpen: false)
        return
      }

      paletteStore.addColor(draftCustomColor)
      paletteStore.addFavorite(draftCustomColor, for: role)
    case nil:
      return
    }

    selectedColor = draftCustomColor
    originalSelectedColor = nil
    activeDraftTarget = nil
    if target == .favorite {
      showsFavoriteSelectionPopover = false
    }
  }

  private func cancelColorDraft(keepFavoriteSelectionPopoverOpen: Bool = true) {
    let target = activeDraftTarget
    let shouldKeepFavoriteSelectionPopover = target == .favorite && keepFavoriteSelectionPopoverOpen

    guard let originalSelectedColor else {
      activeDraftTarget = nil
      if target == .favorite {
        showsFavoriteSelectionPopover = shouldKeepFavoriteSelectionPopover
      }
      return
    }

    selectedColor = originalSelectedColor
    draftCustomColor = originalSelectedColor
    self.originalSelectedColor = nil
    activeDraftTarget = nil
    if target == .favorite {
      showsFavoriteSelectionPopover = shouldKeepFavoriteSelectionPopover
    }
  }

  private func cancelCustomColorDraftIfNeeded(keepFavoriteSelectionPopoverOpen: Bool = true) {
    guard activeDraftTarget != nil else { return }
    cancelColorDraft(keepFavoriteSelectionPopoverOpen: keepFavoriteSelectionPopoverOpen)
  }

  private func closeFavoriteSelectionPopover() {
    showsFavoriteSelectionPopover = false
    if activeDraftTarget == .favorite {
      cancelColorDraft(keepFavoriteSelectionPopoverOpen: false)
    }
  }

  private func addVaultColorToFavorites(_ color: Color) {
    guard canAddFavorite else {
      closeFavoriteSelectionPopover()
      return
    }

    originalSelectedColor = nil
    activeDraftTarget = nil
    paletteStore.addFavorite(color, for: role)
    selectedColor = color
    showsFavoriteSelectionPopover = false
  }

  private func favoriteColorButton(_ color: Color) -> some View {
    InlineAreaPaletteColorButton(
      color: color,
      title: AnnotateColorPaletteStore.isClear(color) ? L10n.Common.none : title,
      isSelected: AnnotateColorPaletteStore.colorsMatch(selectedColor, color),
      sourceFavoriteRole: role,
      overlayAction: {
        paletteStore.removeFavorite(color, for: role)
      },
      overlayHelp: L10n.Common.deleteAction,
      onDropPayload: { payload in
        handleFavoriteDrop(payload, targetColor: color)
      },
      onSelect: {
        selectColorAndDismiss(color)
      }
    )
  }

  private func paletteColorButton(
    _ color: Color,
    overlayAction: (() -> Void)?,
    overlayHelp: String
  ) -> some View {
    InlineAreaPaletteColorButton(
      color: color,
      title: AnnotateColorPaletteStore.isClear(color) ? L10n.Common.none : title,
      isSelected: AnnotateColorPaletteStore.colorsMatch(selectedColor, color),
      sourceFavoriteRole: nil,
      overlayAction: overlayAction,
      overlayHelp: overlayHelp,
      onSelect: {
        selectColorAndDismiss(color)
      }
    )
  }

  private func handleFavoriteDrop(_ payload: AnnotateColorDragPayload) {
    guard canAcceptFavoriteDrop(payload) else { return }

    paletteStore.acceptFavoriteDrop(
      payload,
      for: role
    )
    if !canAddFavorite {
      closeFavoriteSelectionPopover()
    }
  }

  private func handleFavoriteDrop(
    _ payload: AnnotateColorDragPayload,
    targetColor: Color
  ) {
    guard canAcceptFavoriteDrop(payload) else { return }

    paletteStore.acceptFavoriteDrop(
      payload,
      for: role,
      targetColor: targetColor
    )
    if !canAddFavorite {
      closeFavoriteSelectionPopover()
    }
  }

  private func canAcceptFavoriteDrop(_ payload: AnnotateColorDragPayload) -> Bool {
    paletteStore.isFavorite(payload.color, for: role) || canAddFavorite
  }
}

private struct InlineAreaPaletteColorButton: View {
  let color: Color
  let title: String
  let isSelected: Bool
  let sourceFavoriteRole: AnnotateColorPaletteRole?
  let overlayAction: (() -> Void)?
  let overlayHelp: String
  var onDropPayload: ((AnnotateColorDragPayload) -> Void)? = nil
  let onSelect: () -> Void

  var body: some View {
    if let onDropPayload {
      content
        .onDrop(of: AnnotateColorDragPayload.supportedContentTypes, isTargeted: $isDropTargeted) { providers in
          AnnotateColorDragPayload.load(from: providers) { payload in
            guard let payload else { return }
            onDropPayload(payload)
          }
        }
    } else {
      content
    }
  }

  @State private var isDropTargeted = false

  private var content: some View {
    ZStack(alignment: .topTrailing) {
      InlineAreaColorSwatch(
        color: color,
        isSelected: isSelected,
        size: 22
      )
      .contentShape(Circle())
      .onTapGesture(perform: onSelect)
      .inlineAreaHelp(title)
      .annotateColorDraggable(color, sourceFavoriteRole: sourceFavoriteRole)

      if let overlayAction {
        Button(action: overlayAction) {
          InlineAreaGlyph(name: "color-remove", size: 13)
            .foregroundStyle(Color.secondary.opacity(0.9))
            .background(
              Circle()
                .fill(InlineAreaChrome.itemBackground)
                .frame(width: 8, height: 8)
            )
        }
        .buttonStyle(.plain)
        .offset(x: 5, y: -5)
        .inlineAreaHelp(overlayHelp)
      }

      if isDropTargeted {
        Circle()
          .stroke(Color.accentColor.opacity(0.75), lineWidth: 2)
          .frame(width: 28, height: 28)
      }
    }
    .frame(width: 24, height: 24)
  }
}

private struct InlineAreaFavoriteEmptyDropTarget: View {
  let onTap: () -> Void
  let onDropPayload: (AnnotateColorDragPayload) -> Void

  @State private var isTargeted = false

  var body: some View {
    HStack(spacing: 6) {
      InlineAreaGlyph(name: isTargeted ? "color-drop" : "color-add", size: 12)
        .foregroundColor(isTargeted ? .accentColor : .secondary)
        .frame(width: 24, height: 24)
        .background(Circle().fill(isTargeted ? Color.accentColor.opacity(0.1) : InlineAreaChrome.itemBackground.opacity(0.75)))
        .overlay(
          Circle()
            .stroke(
              isTargeted ? Color.accentColor.opacity(0.65) : Color.secondary.opacity(0.35),
              style: StrokeStyle(lineWidth: 1, dash: [3, 2])
            )
        )

      Text(L10n.Common.dragColorsHere)
        .font(Typography.labelSmall)
        .lineLimit(1)
    }
    .foregroundColor(isTargeted ? .accentColor : .secondary)
    .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
    .contentShape(Rectangle())
    .inlineAreaHelp(L10n.Common.custom)
    .accessibilityLabel(L10n.Common.custom)
    .onTapGesture(perform: onTap)
    .accessibilityAddTraits(.isButton)
    .onDrop(of: AnnotateColorDragPayload.supportedContentTypes, isTargeted: $isTargeted) { providers in
      AnnotateColorDragPayload.load(from: providers) { payload in
        guard let payload else { return }
        onDropPayload(payload)
      }
    }
  }
}

private struct InlineAreaFavoriteDropSlot: View {
  let onTap: () -> Void
  let onDropPayload: (AnnotateColorDragPayload) -> Void

  @State private var isTargeted = false

  var body: some View {
    InlineAreaGlyph(name: isTargeted ? "color-drop" : "color-add", size: 11)
      .foregroundColor(isTargeted ? .accentColor : .secondary)
      .frame(width: 22, height: 22)
      .background(Circle().fill(InlineAreaChrome.itemBackground.opacity(0.75)))
      .overlay(
        Circle()
          .stroke(
            isTargeted ? Color.accentColor.opacity(0.65) : Color.secondary.opacity(0.35),
            style: StrokeStyle(lineWidth: 1, dash: [3, 2])
          )
      )
      .frame(width: 24, height: 24)
      .inlineAreaHelp(L10n.Common.custom)
      .contentShape(Circle())
      .onTapGesture(perform: onTap)
      .accessibilityLabel(L10n.Common.custom)
      .accessibilityAddTraits(.isButton)
      .onDrop(of: AnnotateColorDragPayload.supportedContentTypes, isTargeted: $isTargeted) { providers in
        AnnotateColorDragPayload.load(from: providers) { payload in
          guard let payload else { return }
          onDropPayload(payload)
        }
      }
  }
}

private struct InlineAreaColorSwatch: View {
  let color: Color
  let isSelected: Bool
  let size: CGFloat

  var body: some View {
    ZStack {
      Circle()
        .fill(AnnotateColorPaletteStore.isClear(color) ? Color.clear : color)
        .frame(width: size, height: size)
        .overlay(
          Circle()
            .strokeBorder(
              isSelected ? Color.accentColor : Color.primary.opacity(0.32),
              lineWidth: isSelected ? 2 : 1
            )
        )

      if AnnotateColorPaletteStore.isClear(color) {
        InlineAreaGlyph(name: "color-none", size: max(10, size * 0.6))
          .foregroundColor(InlineAreaChrome.secondaryText)
      }
    }
  }
}
private struct InlineAreaSegmentedPicker<Item: Identifiable & Equatable>: View {
  let title: String
  let items: [Item]
  @Binding var selection: Item
  /// Glyph asset key, see `InlineAreaGlyph`.
  let icon: (Item) -> String
  let tooltip: KeyPath<Item, String>

  var body: some View {
    InlineAreaPropertyGroup(title: title) {
      HStack(spacing: 2) {
        ForEach(items) { item in
          Button {
            selection = item
          } label: {
            InlineAreaGlyph(name: icon(item), isSelected: selection == item, size: 16)
              .foregroundColor(selection == item ? InlineAreaChrome.itemSelectedForeground : InlineAreaChrome.secondaryText)
              .frame(width: InlineAreaChrome.propertyControlHeight, height: InlineAreaChrome.propertyControlHeight)
              .background(
                RoundedRectangle(cornerRadius: InlineAreaChrome.propertyCornerRadius, style: .continuous)
                  .fill(selection == item ? InlineAreaChrome.itemSelectedBackground : Color.clear)
              )
              .overlay(
                RoundedRectangle(cornerRadius: InlineAreaChrome.propertyCornerRadius, style: .continuous)
                  .stroke(selection == item ? InlineAreaChrome.itemSelectedBorder : InlineAreaChrome.itemBorder, lineWidth: 1)
              )
          }
          .buttonStyle(.plain)
          .inlineAreaHelp(item[keyPath: tooltip])
          .accessibilityLabel("\(title): \(item[keyPath: tooltip])")
        }
      }
    }
  }
}


private struct InlineAreaArrowBendControl: View {
  @Binding var bendDirection: ArrowBendDirection

  var body: some View {
    InlineAreaPropertyGroup(title: L10n.AnnotateUI.arrowBend) {
      Button {
        bendDirection = bendDirection.toggled
      } label: {
        InlineAreaGlyph(name: "bend-\(bendDirection.rawValue)", isSelected: bendDirection == .alternate, size: 16)
          .foregroundColor(bendDirection == .alternate ? InlineAreaChrome.itemSelectedForeground : InlineAreaChrome.secondaryText)
          .frame(width: InlineAreaChrome.propertyControlHeight, height: InlineAreaChrome.propertyControlHeight)
          .background(
            RoundedRectangle(cornerRadius: InlineAreaChrome.propertyCornerRadius, style: .continuous)
              .fill(bendDirection == .alternate ? InlineAreaChrome.itemSelectedBackground : Color.clear)
          )
          .overlay(
            RoundedRectangle(cornerRadius: InlineAreaChrome.propertyCornerRadius, style: .continuous)
              .stroke(bendDirection == .alternate ? InlineAreaChrome.itemSelectedBorder : InlineAreaChrome.itemBorder, lineWidth: 1)
          )
      }
      .buttonStyle(.plain)
      .inlineAreaHelp("\(L10n.AnnotateUI.flipArrowBend): \(bendDirection.displayName)")
      .accessibilityLabel(L10n.AnnotateUI.flipArrowBend)
    }
  }
}

private struct InlineAreaLineStylePicker: View {
  @Binding var selection: LineDashStyle

  var body: some View {
    InlineAreaPropertyGroup(title: L10n.AnnotateUI.lineStyle) {
      HStack(spacing: 2) {
        ForEach(LineDashStyle.allCases) { style in
          Button {
            selection = style
          } label: {
            LineStyleIcon(style: style)
              .foregroundColor(selection == style ? InlineAreaChrome.itemSelectedForeground : InlineAreaChrome.secondaryText)
              .frame(width: InlineAreaChrome.propertyControlHeight, height: InlineAreaChrome.propertyControlHeight)
              .background(
                RoundedRectangle(cornerRadius: InlineAreaChrome.propertyCornerRadius, style: .continuous)
                  .fill(selection == style ? InlineAreaChrome.itemSelectedBackground : Color.clear)
              )
              .overlay(
                RoundedRectangle(cornerRadius: InlineAreaChrome.propertyCornerRadius, style: .continuous)
                  .stroke(selection == style ? InlineAreaChrome.itemSelectedBorder : InlineAreaChrome.itemBorder, lineWidth: 1)
              )
          }
          .buttonStyle(.plain)
          .inlineAreaHelp(style.displayName)
          .accessibilityLabel("\(L10n.AnnotateUI.lineStyle): \(style.displayName)")
        }
      }
    }
  }
}

private struct InlineAreaSliderControl: View {
  let title: String
  let icon: String
  @Binding var value: CGFloat
  let range: ClosedRange<CGFloat>
  let step: CGFloat
  let displayText: String
  let onEditingChanged: (Bool) -> Void

  var body: some View {
    InlineAreaPropertyGroup(title: title) {
      HStack(spacing: 6) {
        InlineAreaGlyph(name: icon, size: 14)
          .foregroundColor(InlineAreaChrome.secondaryText)

        Slider(
          value: $value.stepped(by: step, in: range),
          in: range,
          onEditingChanged: onEditingChanged
        )
        .frame(width: 64)
        .controlSize(.small)
        .accessibilityLabel(title)
        .accessibilityValue(displayText)

        Text(displayText)
          .font(.system(size: 11, weight: .medium))
          .foregroundColor(InlineAreaChrome.secondaryText)
          .lineLimit(1)
          .monospacedDigit()
          .frame(width: 34, alignment: .trailing)
          .accessibilityHidden(true)
      }
      // The bar has no group titles, so the name shows on hover.
      .inlineAreaHelp(title)
    }
  }
}

private struct InlineAreaTextFieldControl: View {
  let title: String
  @Binding var text: String

  var body: some View {
    InlineAreaPropertyGroup(title: title) {
      TextField("", text: $text)
        .textFieldStyle(.plain)
        .accessibilityLabel(title)
        .inlineAreaHelp(title)
        // Return or Esc hands the keyboard back to the capture (copy, cancel, arrows).
        .onSubmit { NSApp.keyWindow?.makeFirstResponder(nil) }
        .onExitCommand { NSApp.keyWindow?.makeFirstResponder(nil) }
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(InlineAreaChrome.primaryText)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(width: 112, height: InlineAreaChrome.propertyControlHeight)
        .background(
          RoundedRectangle(cornerRadius: InlineAreaChrome.propertyCornerRadius, style: .continuous)
            .fill(InlineAreaChrome.itemBackground)
        )
    }
  }
}

private struct InlineAreaPropertyGroup<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content
  @Environment(\.inlineAreaPropertyRows) private var showsAsRow

  var body: some View {
    if showsAsRow {
      HStack(spacing: 10) {
        Text(title)
          .font(.system(size: 11, weight: .semibold))
          .foregroundColor(InlineAreaChrome.secondaryText)
          .lineLimit(1)
          .frame(width: 52, alignment: .leading)

        content
      }
      .frame(height: InlineAreaChrome.propertyControlHeight + 4)
    } else {
      // Titles live in each control's hover tip; groups are separated by the hairline only.
      HStack(spacing: 0) {
        InlineAreaDivider(height: 16)
        content
      }
    }
  }
}

private struct InlineAreaPropertyRowsKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// Inside the More popover each property is a row with its title in front.
  var inlineAreaPropertyRows: Bool {
    get { self[InlineAreaPropertyRowsKey.self] }
    set { self[InlineAreaPropertyRowsKey.self] = newValue }
  }
}

private struct InlineAreaCaptureActions: View {
  @ObservedObject var session: InlineAreaAnnotateSession

  var body: some View {
    HStack(spacing: 0) {
      HStack(spacing: InlineAreaToolbarMetrics.itemSpacing) {
        InlineAreaIconButton(icon: "scrolling", tooltip: L10n.PinnyLongScreenshot.title,
                            isEnabled: !session.isFinishing) {
          session.startScrollingCapture()
        }
        InlineAreaIconButton(icon: "record", tooltip: L10n.PinnyRecording.title,
                            isEnabled: !session.isFinishing) {
          session.beginRecordingPrep()
        }
      }
      InlineAreaDivider()
      HStack(spacing: InlineAreaToolbarMetrics.itemSpacing) {
        InlineAreaIconButton(icon: "copy",
          tooltip: L10n.Common.withShortcut(L10n.AnnotateUI.copyToClipboard, "\(L10n.AnnotateUI.pinnyReturnKey) / ⌘C"),
          isEnabled: !session.isFinishing) {
          session.copyCurrentImage()
        }
        InlineAreaIconButton(icon: "pin", tooltip: L10n.PreferencesQuickAccess.pinToScreenAction,
                            isEnabled: !session.isFinishing) {
          Task { await session.finishAndPin() }
        }
        InlineAreaIconButton(icon: "save",
          tooltip: L10n.Common.withShortcut(L10n.Common.save, "⌘S"),
          isEnabled: !session.isFinishing) {
          Task { await session.finish() }
        }
        InlineAreaIconButton(icon: "cancel", tooltip: L10n.Common.cancel,
                            isEnabled: !session.isFinishing) {
          session.cancel()
        }
      }
    }
    .overlay {
      if session.isFinishing { ProgressView().controlSize(.small).allowsHitTesting(false) }
    }
  }
}

private struct InlineAreaSelectionDimShape: Shape {
  var hole: CGRect?

  /// Lets the cutout slide with the border between hover highlights.
  var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
    get {
      let rect = hole ?? .zero
      return AnimatablePair(AnimatablePair(rect.minX, rect.minY), AnimatablePair(rect.width, rect.height))
    }
    set {
      guard hole != nil else { return }
      hole = CGRect(x: newValue.first.first, y: newValue.first.second,
                    width: newValue.second.first, height: newValue.second.second)
    }
  }

  func path(in rect: CGRect) -> Path {
    var path = Path(rect)
    if let hole {
      path.addRect(hole)
    }
    return path
  }
}
