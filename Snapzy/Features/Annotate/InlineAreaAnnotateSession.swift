//
//  InlineAreaAnnotateSession.swift
//  Snapzy
//
//  Coordinates direct area screenshot annotation before post-capture routing.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

struct InlineAreaAnnotateDisplay: Identifiable {
  let displayID: CGDirectDisplayID
  let screenFrame: CGRect
  let localFrame: CGRect
  let controlInsets: InlineAreaControlInsets
  let backdropImage: NSImage
  /// Same content as `backdropImage`, kept as a `CGImage` for the magnifier — which reads raw
  /// pixels on every mouse move and would otherwise pay `NSImage` overhead each time.
  let backdropCGImage: CGImage

  var id: CGDirectDisplayID { displayID }
}

enum InlineCaptureOutcome {
  case saved(URL)
  case copied
  case pinned
  case failure(CaptureError)
}

nonisolated enum InlineAreaAnnotatePhase {
  case selecting
  case annotating
}

nonisolated enum InlineAreaKeyEventSource {
  case local
  case global
}

nonisolated enum InlineAreaKeyAction: Equatable {
  case passThrough
  case cancel
  case finish
  case copyCurrentImage
  case copyMagnifierColor
  case selectDisplay
  case selectWindow
  case changeElementLevel(towardParent: Bool)
  /// Arrow keys after a selection exists; see `InlineAreaSelectionNudge`.
  case adjustSelection(InlineAreaSelectionNudge)
  /// `,` (older) / `.` (newer) through recently captured regions.
  case recallRegion(older: Bool)
  case setMoveModifierActive(Bool)
  case resetMoveModifierAndPassThrough
}

/// Pinny keyboard adjustment of the selection, in desktop-local points (y grows downward).
/// Plain arrows move, ⌘ pushes the edge on that side outward, ⌥ pulls the opposite edge in
/// that direction (shrinks); ⇧ makes any of them 10 points.
nonisolated struct InlineAreaSelectionNudge: Equatable {
  enum Mode: Equatable { case move, expand, shrink }
  enum Direction: Equatable { case up, down, left, right }
  let mode: Mode
  let direction: Direction
  let amount: CGFloat

  static let minimumSide: CGFloat = 6

  init(mode: Mode, direction: Direction, amount: CGFloat) {
    self.mode = mode
    self.direction = direction
    self.amount = amount
  }

  init?(event: NSEvent) {
    let direction: Direction
    switch event.keyCode {
    case 126: direction = .up
    case 125: direction = .down
    case 123: direction = .left
    case 124: direction = .right
    default: return nil
    }
    let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
    guard !flags.contains(.control), !(flags.contains(.command) && flags.contains(.option)) else { return nil }
    self.init(
      mode: flags.contains(.command) ? .expand : (flags.contains(.option) ? .shrink : .move),
      direction: direction,
      amount: flags.contains(.shift) ? 10 : 1
    )
  }

  func applied(to rect: CGRect) -> CGRect {
    var r = rect.standardized
    let a = amount
    switch (mode, direction) {
    case (.move, .up): r.origin.y -= a
    case (.move, .down): r.origin.y += a
    case (.move, .left): r.origin.x -= a
    case (.move, .right): r.origin.x += a
    case (.expand, .up): r.origin.y -= a; r.size.height += a
    case (.expand, .down): r.size.height += a
    case (.expand, .left): r.origin.x -= a; r.size.width += a
    case (.expand, .right): r.size.width += a
    case (.shrink, .up): r.size.height -= min(a, r.height - Self.minimumSide)
    case (.shrink, .down):
      let step = min(a, r.height - Self.minimumSide); r.origin.y += step; r.size.height -= step
    case (.shrink, .left): r.size.width -= min(a, r.width - Self.minimumSide)
    case (.shrink, .right):
      let step = min(a, r.width - Self.minimumSide); r.origin.x += step; r.size.width -= step
    }
    return r
  }
}

/// Pinny: screen rects (AppKit global points) of recently copied, saved or pinned captures,
/// newest first, so the next capture can reuse one.
enum InlineAreaRegionHistory {
  static let limit = 10

  static func regions(userDefaults: UserDefaults = .standard) -> [CGRect] {
    (userDefaults.array(forKey: PreferencesKeys.captureRegionHistory) as? [[Double]] ?? []).compactMap {
      $0.count == 4 && $0[2] > 0 && $0[3] > 0 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil
    }
  }

  static func record(_ rect: CGRect, userDefaults: UserDefaults = .standard) {
    let rounded = rect.integral
    let history = [rounded] + regions(userDefaults: userDefaults).filter { $0 != rounded }
    userDefaults.set(
      history.prefix(limit).map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] },
      forKey: PreferencesKeys.captureRegionHistory
    )
  }
}

/// Weakly holds a per-display magnifier host view so the session can reach it for
/// scroll-wheel zoom and the "C" copy shortcut without retaining the view.
private final class InlineAreaMagnifierHostViewBox {
  weak var view: InlineAreaMagnifierHostView?
  init(_ view: InlineAreaMagnifierHostView) {
    self.view = view
  }
}

@MainActor
final class InlineAreaAnnotateSession: ObservableObject {
  private struct InlineAreaCrop {
    let image: NSImage
    let localRect: CGRect
  }

  @Published var phase: InlineAreaAnnotatePhase = .selecting
  @Published var selectionRect: CGRect?
  /// Authoritative pointer position in desktop-local coordinates for the `.selecting` phase.
  /// Fed by every input path — SwiftUI hover/drag callbacks *and* the drag local monitor
  /// (`installSelectionMonitorIfNeeded`), which consumes `.leftMouseDragged` before AppKit
  /// dispatches it to the hosting view, starving gesture-driven state for the rest of the
  /// drag. Pointer-positioned chrome (drawn crosshair, magnifier, coordinate bubble) must
  /// read this instead of gesture-only state, or it freezes at the drag-start point.
  @Published var selectionPointerLocation: CGPoint?
  @Published var isMoveModifierActive = false
  @Published private(set) var isFinishing = false
  @Published var actionMessage: String?
  /// The window currently under the cursor while "automatically detect window under cursor"
  /// is on (see `autoDetectWindowUnderCursor`) — mirrors plain area screenshot's
  /// `hoveredWindowCandidate`, but shared at the session level since any of the per-display
  /// views may need to render the highlight for a window on another display.
  @Published var hoveredWindowCandidate: WindowSelectionCandidate?
  /// The AX element under the cursor (`SmartElementQueryService`), in AppKit global screen
  /// coordinates — same space as `hoveredWindowCandidate.target.frame`. When present it takes
  /// priority over the whole-window highlight, mirroring plain area screenshot's
  /// `hoveredSmartElementRect`. Arrives asynchronously — see `subscribeToSmartElementHighlights`.
  @Published var hoveredSmartElementRect: CGRect?

  let state: AnnotateState
  let desktopFrame: CGRect
  let displays: [InlineAreaAnnotateDisplay]

  private let primaryDisplayID: CGDirectDisplayID
  private let screenFramesByDisplayID: [CGDirectDisplayID: CGRect]
  private let frozenSession: FrozenAreaCaptureSession
  private let saveDirectory: URL
  private let outputFormat: ImageFormat
  private let defaults: UserDefaults
  private let context: CaptureContext
  private let saveDirectoryProvider: (() -> URL?)?
  private let pinImage: @MainActor (NSImage, CGRect) -> Void
  private let onComplete: (InlineCaptureOutcome) -> Void
  private let windows = NSHashTable<NSWindow>.weakObjects()
  private var localKeyMonitor: Any?
  private var globalKeyMonitor: Any?
  private var selectionLocalMonitor: Any?
  private var magnifierScrollMonitor: Any?
  private var magnifierHostViewBoxes: [CGDirectDisplayID: InlineAreaMagnifierHostViewBox] = [:]
  private var selectionStartPoint: CGPoint?
  private var stateChangeCancellable: AnyCancellable?
  private var didComplete = false
  /// Index into `InlineAreaRegionHistory` of the region currently shown, while it is untouched.
  private var recalledRegionIndex: Int?
  @Published private(set) var hasRegionHistory = !InlineAreaRegionHistory.regions().isEmpty
  /// Populated asynchronously in `init` (see `startWindowSelectionQuery`) — nil until the
  /// query resolves, so hover hit-testing simply has nothing to match until then.
  private var windowSelectionSnapshot: WindowSelectionSnapshot?
  private var windowSelectionTask: Task<Void, Never>?
  private var smartElementCancellable: AnyCancellable?
  /// The system cursor is hidden for the whole `.selecting` phase — `InlineAreaAnnotateWindow`
  /// draws the crosshair itself (the same image/positioning as plain area screenshot's
  /// `cursorProxyLayer`) instead of relying on a native `NSCursor.set()`, which this
  /// `.nonactivatingPanel` configuration can silently stop rendering after roughly a second of
  /// no new mouse events even though the app's own cursor bookkeeping stays correct throughout
  /// (confirmed by direct instrumentation) — a WindowServer-level quirk, not a state bug, so
  /// no amount of re-asserting the same `NSCursor` fixes it. `CGDisplayHideCursor`/`Show` are a
  /// different, lower-level mechanism unaffected by that quirk. Session activates the app via
  /// `NSApp.activate` at start, so — unlike live-passthrough capture — this doesn't need
  /// `BackgroundCursorControl`'s background-cursor-control workaround.
  private var cursorHider = LivePassthroughCursorHider()

  init(
    primaryDisplayID: CGDirectDisplayID,
    desktopFrame: CGRect,
    displays: [InlineAreaAnnotateDisplay],
    frozenSession: FrozenAreaCaptureSession,
    saveDirectory: URL,
    outputFormat: ImageFormat,
    saveDirectoryProvider: (() -> URL?)? = nil,
    defaults: UserDefaults = .standard,
    context: CaptureContext = .empty,
    prefetchedContentTask: ShareableContentPrefetchTask? = nil,
    excludeOwnApplication: Bool = false,
    pinImage: @escaping @MainActor (NSImage, CGRect) -> Void = { image, rect in
      QuickAccessPinWindowManager.shared.show(image: image, sourceScreenRect: rect)
    },
    onComplete: @escaping (InlineCaptureOutcome) -> Void
  ) {
    self.primaryDisplayID = primaryDisplayID
    self.desktopFrame = desktopFrame
    self.displays = displays
    self.screenFramesByDisplayID = Dictionary(uniqueKeysWithValues: displays.map {
      ($0.displayID, $0.screenFrame)
    })
    self.frozenSession = frozenSession
    self.saveDirectory = saveDirectory
    self.outputFormat = outputFormat
    self.saveDirectoryProvider = saveDirectoryProvider
    self.defaults = defaults
    self.context = context
    self.onComplete = onComplete
    self.pinImage = pinImage
    self.state = AnnotateState(
      defaults: defaults,
      appliesDefaultCanvasPresetOnNewImages: false
    )
    self.state.onToolActivated = { tool in
      AnnotateToolPreference.remember(tool, userDefaults: defaults)
    }
    self.stateChangeCancellable = state.objectWillChange.sink { [weak self] _ in
      Task { @MainActor in
        self?.objectWillChange.send()
      }
    }
    // Session always starts in `.selecting` — hide the real cursor for every display up
    // front; `beginAnnotating(with:)` shows it again once selection ends.
    cursorHider.hide(displayIDs: Set(displays.map(\.displayID)))
    startWindowSelectionQuery(prefetchedContentTask: prefetchedContentTask, excludeOwnApplication: excludeOwnApplication)
    if autoDetectElementUnderCursor {
      SmartElementQueryService.shared.ensureAccessibilityPermission()
    }
    subscribeToSmartElementHighlights()
  }

  deinit {
    windowSelectionTask?.cancel()
    Task { @MainActor in
      SmartElementQueryService.shared.cancelPendingQueries()
    }
  }

  private func subscribeToSmartElementHighlights() {
    smartElementCancellable = SmartElementQueryService.shared.elementDetectedPublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] rect in
        guard let self, autoDetectElementUnderCursor, phase == .selecting else { return }
        hoveredSmartElementRect = rect
      }
  }

  /// The "automatically detect window under cursor" preference (see
  /// `PreferencesCaptureSettingsView`) — shares its key with plain area screenshot capture so
  /// both entry points behave identically.
  var autoDetectWindowUnderCursor: Bool {
    defaults.object(forKey: PreferencesKeys.screenshotAutoDetectWindowUnderCursor) as? Bool ?? false
  }

  /// The "also detect specific elements" preference, layered on top of the window-level one —
  /// only meaningful (and only exposed as enabled in Preferences) once that one is also on.
  var autoDetectElementUnderCursor: Bool {
    autoDetectWindowUnderCursor
      && (defaults.object(forKey: PreferencesKeys.screenshotAutoDetectElementUnderCursor) as? Bool ?? false)
  }

  /// Kicks off the same window enumeration plain area screenshot uses for its "A" toggle mode
  /// (`WindowSelectionQueryService`), reusing the shareable-content prefetch already started
  /// for the frozen backdrop capture rather than issuing a second query. Only worth doing when
  /// the preference is on — window enumeration briefly activates the Screen Recording prompt
  /// path on first use, which shouldn't happen for users who never enabled this.
  private func startWindowSelectionQuery(
    prefetchedContentTask: ShareableContentPrefetchTask?,
    excludeOwnApplication: Bool
  ) {
    guard autoDetectWindowUnderCursor else { return }
    windowSelectionTask = Task { [weak self] in
      let snapshot = await WindowSelectionQueryService.prepareSnapshot(
        prefetchedContentTask: prefetchedContentTask,
        excludeOwnApplication: excludeOwnApplication
      )
      guard !Task.isCancelled else { return }
      self?.windowSelectionSnapshot = snapshot
    }
  }

  /// Hit-tests the hovered window at a real screen point, mirroring plain area screenshot's
  /// `updateWindowHover`. `point` is in the same coordinate space as `WindowCaptureTarget.frame`
  /// (AppKit global screen coordinates, bottom-left origin).
  func updateHoveredWindow(atScreenPoint point: CGPoint) {
    guard phase == .selecting else { return }
    if let rect = hoveredSmartElementRect, !rect.insetBy(dx: -2, dy: -2).contains(point) {
      hoveredSmartElementRect = nil
    }
    guard autoDetectWindowUnderCursor else {
      hoveredWindowCandidate = nil
      return
    }
    hoveredWindowCandidate = windowSelectionSnapshot?.hitTest(at: point)
    // Also layers in element-level detection (a button, a popup, an element inside a browser
    // page) on top of the whole-window highlight, when that's separately turned on — the
    // result arrives later via `subscribeToSmartElementHighlights` and updates
    // `hoveredSmartElementRect` once it does.
    guard autoDetectElementUnderCursor else { return }
    // `updateLocation(_:pid:)`, not `updateMouseLocation(pid:)`: the latter internally
    // re-reads `CGEvent(source: nil)?.location`, which can go stale if anything else is
    // consuming mouse-moved events system-wide — `point` above is already a live, correct
    // position, just in AppKit's bottom-left origin instead of the top-left origin
    // `CGEvent.location` uses.
    let mainScreenHeight = NSScreen.screens.first(where: { $0.displayID == CGMainDisplayID() })?.frame.height
      ?? CGDisplayBounds(CGMainDisplayID()).height
    let quartzPoint = CGPoint(x: point.x, y: mainScreenHeight - point.y)
    SmartElementQueryService.shared.updateLocation(quartzPoint, pid: hoveredWindowCandidate?.target.ownerPID)
  }

  /// Crops the backdrop to the selected window and jumps straight to `.annotating`, the same
  /// end state a manual drag reaches via `endSelection(at:)`.
  func selectWindow(_ candidate: WindowSelectionCandidate) {
    guard phase == .selecting else { return }
    hoveredWindowCandidate = nil
    hoveredSmartElementRect = nil
    beginAnnotating(with: Self.localFrame(for: candidate.target.frame, in: desktopFrame))
  }

  /// Crops the backdrop to the detected AX element rect and jumps straight to `.annotating` —
  /// same idea as `selectWindow(_:)`, but for the finer-grained element-level highlight.
  /// `screenRect` is in the same coordinate space as `WindowCaptureTarget.frame`.
  func selectElement(atScreenRect screenRect: CGRect) {
    guard phase == .selecting else { return }
    hoveredWindowCandidate = nil
    hoveredSmartElementRect = nil
    beginAnnotating(with: Self.localFrame(for: screenRect, in: desktopFrame))
  }

  func attach(window: NSWindow) {
    windows.add(window)
    if localKeyMonitor == nil, globalKeyMonitor == nil {
      installKeyMonitors()
    }
    installMagnifierScrollMonitorIfNeeded()
  }

  /// The "show magnifier by default" preference (see `PreferencesCaptureSettingsView`) —
  /// shared with plain area screenshot capture so both entry points behave identically.
  var showsMagnifierByDefault: Bool {
    defaults.object(forKey: PreferencesKeys.screenshotShowMagnifierByDefault) as? Bool ?? false
  }

  /// The "show color picker panel" preference — same sharing rationale as above.
  var showsMagnifierColorPanel: Bool {
    defaults.object(forKey: PreferencesKeys.screenshotShowMagnifierColorPanel) as? Bool ?? true
  }

  /// Registers the per-display magnifier host view created by `InlineAreaMagnifierOverlay` so
  /// scroll-wheel zoom and the "C" copy shortcut (handled at the session level, since key
  /// events arrive via `handleKeyEvent`, not through the host view itself) can reach it.
  func registerMagnifierHostView(_ view: InlineAreaMagnifierHostView, for displayID: CGDirectDisplayID) {
    magnifierHostViewBoxes[displayID] = InlineAreaMagnifierHostViewBox(view)
  }

  func beginSelection(at localPoint: CGPoint) {
    guard phase == .selecting else { return }
    guard selectionStartPoint == nil else { return }
    selectionStartPoint = localPoint
    installSelectionMonitorIfNeeded()
    updateSelection(to: localPoint)
  }

  func updateSelection(to localPoint: CGPoint) {
    guard phase == .selecting, let start = selectionStartPoint else { return }
    selectionPointerLocation = localPoint
    selectionRect = clampedSelectionRect(CGRect(
      x: min(start.x, localPoint.x),
      y: min(start.y, localPoint.y),
      width: abs(localPoint.x - start.x),
      height: abs(localPoint.y - start.y)
    ).standardized)
  }

  func endSelection(at localPoint: CGPoint) {
    guard phase == .selecting, selectionStartPoint != nil else { return }
    updateSelection(to: localPoint)
    removeSelectionMonitor()
    selectionStartPoint = nil
    selectionPointerLocation = nil

    guard let rect = selectionRect, rect.width > 5, rect.height > 5 else {
      selectionRect = nil
      return
    }
    beginAnnotating(with: rect)
  }

  func beginAnnotating(with localRect: CGRect) {
    let clampedRect = clampedSelectionRect(localRect.standardized)
    guard clampedRect.width > 5, clampedRect.height > 5,
          let crop = cropImage(for: clampedRect) else { return }

    removeSelectionMonitor()
    selectionStartPoint = nil
    selectionPointerLocation = nil
    selectionRect = crop.localRect
    state.loadImage(crop.image, url: nil)
    // Start with direct region movement; drawing tools remain an explicit choice.
    state.selectedTool = .selection
    phase = .annotating
    SmartElementQueryService.shared.cancelPendingQueries()
    cursorHider.showAll()
  }

  func moveSelection(to localRect: CGRect, refreshImage: Bool) {
    let clampedRect = clampedSelectionRect(localRect.standardized)
    guard refreshImage else {
      selectionRect = clampedRect
      return
    }
    guard let crop = cropImage(for: clampedRect) else { return }
    selectionRect = crop.localRect
    state.replaceSourceImagePreservingAnnotations(crop.image)
  }

  func resizeSelection(to localRect: CGRect, previousRect: CGRect) {
    let clampedRect = clampedSelectionRect(localRect.standardized)
    guard clampedRect.width > 5,
          clampedRect.height > 5,
          let crop = cropImage(for: clampedRect) else { return }

    let standardizedPreviousRect = previousRect.standardized
    let annotationOffset = CGPoint(
      x: standardizedPreviousRect.minX - crop.localRect.minX,
      y: standardizedPreviousRect.minY - crop.localRect.minY
    )

    selectionRect = crop.localRect
    state.replaceSourceImagePreservingAnnotations(crop.image, annotationOffset: annotationOffset)
  }

  func clampedSelectionPreview(for localRect: CGRect) -> CGRect {
    clampedSelectionRect(localRect.standardized)
  }

  func handleKeyEvent(_ event: NSEvent, source: InlineAreaKeyEventSource = .local) -> Bool {
    let action = Self.keyAction(
      for: event,
      source: source,
      phase: phase,
      hasTextResponder: windows.allObjects.contains { $0.firstResponder is NSTextView },
      hasKeyWindow: windows.allObjects.contains { $0.isKeyWindow },
      hasSelectedAnnotation: state.hasSelectedAnnotations
    )

    if phase != .annotating {
      isMoveModifierActive = false
    }

    switch action {
    case .passThrough:
      return false
    case .cancel:
      cancel()
      return true
    case .finish:
      Task { await finish() }
      return true
    case .copyCurrentImage:
      copyCurrentImage()
      return true
    case .copyMagnifierColor:
      // Only claim the key when the magnifier was actually active — otherwise this falls
      // through as `.passThrough` would have, so plain "C" typing elsewhere is unaffected.
      return copyMagnifierColorForKeyWindow(event)
    case .selectDisplay:
      selectDisplayUnderPointer()
      return true
    case .selectWindow:
      selectWindowUnderPointer()
      return true
    case .adjustSelection(let nudge):
      return adjustSelection(nudge)
    case .recallRegion(let older):
      return recallRegion(older: older)
    case .changeElementLevel(let towardParent):
      guard autoDetectElementUnderCursor else { return false }
      return SmartElementQueryService.shared.selectAdjacentCandidate(towardParent: towardParent)
    case .setMoveModifierActive(let active):
      isMoveModifierActive = active
      return true
    case .resetMoveModifierAndPassThrough:
      isMoveModifierActive = false
      return false
    }
  }

  /// Arrow-key move / resize of an existing selection. Moving carries annotations with the
  /// image, resizing keeps them where they are on screen, matching mouse drags.
  private func adjustSelection(_ nudge: InlineAreaSelectionNudge) -> Bool {
    guard phase == .annotating, let rect = selectionRect else { return false }
    recalledRegionIndex = nil
    let target = nudge.applied(to: rect)
    if nudge.mode == .move {
      moveSelection(to: target, refreshImage: true)
    } else {
      resizeSelection(to: target, previousRect: rect)
    }
    return true
  }

  /// `,` before selecting reuses the last captured region; while that region is untouched and
  /// unannotated, `,` / `.` step to older / newer ones.
  func recallRegion(older: Bool) -> Bool {
    let regions = InlineAreaRegionHistory.regions()
    switch phase {
    case .selecting:
      guard older, let region = regions.first else { return false }
      beginAnnotating(with: Self.localRect(for: region, in: desktopFrame))
      guard phase == .annotating else { return false }
      recalledRegionIndex = 0
      return true
    case .annotating:
      guard let index = recalledRegionIndex, state.annotations.isEmpty,
            let current = selectionRect else { return false }
      let next = older ? index + 1 : index - 1
      guard regions.indices.contains(next) else { return true }
      resizeSelection(to: Self.localRect(for: regions[next], in: desktopFrame), previousRect: current)
      recalledRegionIndex = next
      return true
    }
  }

  func cancel() {
    guard !isFinishing else { return }
    complete(.failure(.cancelled))
  }

  func windowDidClose() {
    complete(.failure(.cancelled), closeWindow: false)
  }

  func controlDisplayID(for localRect: CGRect) -> CGDirectDisplayID {
    let bestMatch = displays
      .compactMap { display -> (displayID: CGDirectDisplayID, area: CGFloat)? in
        let intersection = display.localFrame.intersection(localRect)
        guard !intersection.isEmpty else { return nil }
        return (display.displayID, intersection.width * intersection.height)
      }
      .max { $0.area < $1.area }

    return bestMatch?.displayID ?? primaryDisplayID
  }

  /// The whole window under the pointer; the display when no window is detected there.
  func selectWindowUnderPointer() {
    guard phase == .selecting else { return }
    let local = selectionPointerLocation ?? currentDesktopMouseLocation
    let screenPoint = CGPoint(x: desktopFrame.minX + local.x, y: desktopFrame.maxY - local.y)
    if let candidate = hoveredWindowCandidate ?? windowSelectionSnapshot?.hitTest(at: screenPoint) {
      selectWindow(candidate)
    } else {
      selectDisplayUnderPointer()
    }
  }

  func selectDisplayUnderPointer() {
    guard phase == .selecting else { return }
    let point = selectionPointerLocation ?? currentDesktopMouseLocation
    if let display = displays.first(where: { $0.localFrame.contains(point) }) {
      beginAnnotating(with: display.localFrame)
    }
  }

  private func renderedSelection() -> NSImage? {
    state.commitTextEditing()
    guard let image = AnnotateExporter.renderFinalImage(state: state) else {
      actionMessage = L10n.ScreenCapture.failedToCropCapturedImage
      return nil
    }
    return image
  }

  /// Saving is the only action that needs a directory or writes an image file.
  func finish() async {
    guard phase == .annotating, !didComplete, !isFinishing else { return }
    isFinishing = true
    actionMessage = nil
    defer { isFinishing = false }
    guard let image = renderedSelection(),
          let cgImage = AnnotateExporter.bestCGImage(from: image) else { return }
    guard let directory = saveDirectoryProvider.map({ $0() }) ?? saveDirectory else { return }
    let result = await ScreenCaptureManager.shared.saveProcessedImage(
      cgImage, to: directory, format: outputFormat,
      scaleFactor: Self.imageScale(image), emitCompletion: false, context: context
    )
    switch result {
    case .success(let url):
      persistCommittedSession(for: url)
      SoundManager.playScreenshotCapture()
      complete(.saved(url))
    case .failure(let error):
      actionMessage = error.localizedDescription
    }
  }

  func finishAndPin() async {
    guard phase == .annotating, !didComplete, !isFinishing,
          let sourceRect = selectionRect.map({ screenRect(for: $0) }),
          let image = renderedSelection() else { return }
    // The window owns this full-resolution image. No saved URL or thumbnail work is needed.
    isFinishing = true
    let shouldCopy = defaults.object(forKey: "inlinePinCopiesImage") as? Bool ?? true
    if shouldCopy { ClipboardHelper.copyImage(image, sourceScreenRect: sourceRect) }
    complete(.pinned)
    pinImage(image, sourceRect)
    isFinishing = false
  }

  func copyCurrentImage() {
    guard phase == .annotating, !didComplete, !isFinishing,
          let image = renderedSelection() else { return }
    ClipboardHelper.copyImage(image, sourceScreenRect: selectionRect.map { screenRect(for: $0) })
    SoundManager.play("Pop")
    complete(.copied)
  }

  private func cropImage(for localRect: CGRect) -> InlineAreaCrop? {
    do {
      let screenRect = screenRect(for: localRect)
      let displayIDs = Self.displayIDsIntersecting(
        screenRect,
        screenFramesByDisplayID: screenFramesByDisplayID
      )
      guard let displayID = Self.primaryDisplayID(
        for: screenRect,
        screenFramesByDisplayID: screenFramesByDisplayID,
        fallback: primaryDisplayID
      ) else {
        throw CaptureError.captureFailed(L10n.ScreenCapture.selectionOutsideDisplayBounds)
      }

      let selection = AreaSelectionResult(
        target: .rect(screenRect),
        displayID: displayID,
        mode: .screenshot,
        displayIDs: displayIDs.isEmpty ? [displayID] : displayIDs
      )
      let outputScaleFactor = Self.preferredOutputScaleFactor
      let result = selection.spansMultipleDisplays
        ? try frozenSession.cropCompositeImage(
          for: selection,
          minimumOutputScaleFactor: outputScaleFactor
        )
        : try frozenSession.cropImage(
          for: selection,
          minimumOutputScaleFactor: outputScaleFactor
        )
      let image = NSImage(cgImage: result.image, size: result.screenRect.size)
      let localRect = Self.localRect(for: result.screenRect, in: desktopFrame)
      return InlineAreaCrop(image: image, localRect: clampedSelectionRect(localRect))
    } catch {
      DiagnosticLogger.shared.logError(.capture, error, "Inline area annotate crop failed")
      return nil
    }
  }

  func screenRect(for localRect: CGRect) -> CGRect {
    Self.screenRect(for: localRect, in: desktopFrame)
  }

  private func clampedSelectionRect(_ rect: CGRect) -> CGRect {
    var result = rect
    result.size.width = min(max(result.width, 1), desktopFrame.width)
    result.size.height = min(max(result.height, 1), desktopFrame.height)
    result.origin.x = min(max(result.minX, 0), max(0, desktopFrame.width - result.width))
    result.origin.y = min(max(result.minY, 0), max(0, desktopFrame.height - result.height))
    return result
  }

  private func installKeyMonitors() {
    localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
      guard self?.handleKeyEvent(event) == true else { return event }
      return nil
    }
    globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
      Task { @MainActor in
        _ = self?.handleKeyEvent(event, source: .global)
      }
    }
  }

  private func removeKeyMonitors() {
    if let localKeyMonitor {
      NSEvent.removeMonitor(localKeyMonitor)
      self.localKeyMonitor = nil
    }
    if let globalKeyMonitor {
      NSEvent.removeMonitor(globalKeyMonitor)
      self.globalKeyMonitor = nil
    }
    removeMagnifierScrollMonitor()
  }

  /// ⌘+scroll zoom for the magnifier. The host view itself never receives scroll events (it's
  /// excluded from hit-testing so the selection drag gesture underneath works), so this mirrors
  /// `AreaSelectionOverlayView.scrollWheel` at the session level instead, routed to whichever
  /// display's host view the event's window belongs to.
  private func installMagnifierScrollMonitorIfNeeded() {
    guard magnifierScrollMonitor == nil else { return }
    magnifierScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
      guard let self, self.phase == .selecting,
            let window = event.window, self.windows.contains(window) else { return event }
      guard event.modifierFlags.contains(.command),
            let displayID = (event.window as? InlineAreaAnnotatePanel)?.displayID,
            let hostView = self.magnifierHostViewBoxes[displayID]?.view else {
        return event
      }
      let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
      guard delta != 0 else { return event }
      hostView.applyScroll(delta: delta, hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas)
      return nil
    }
  }

  private func removeMagnifierScrollMonitor() {
    if let magnifierScrollMonitor {
      NSEvent.removeMonitor(magnifierScrollMonitor)
      self.magnifierScrollMonitor = nil
    }
  }

  /// Copies the sampled color from whichever display's magnifier is under the key window.
  /// Falls back to the first key window when the triggering event carries no window (e.g. a
  /// global-monitor event from another app).
  @discardableResult
  private func copyMagnifierColorForKeyWindow(_ event: NSEvent) -> Bool {
    let displayID = (event.window as? InlineAreaAnnotatePanel)?.displayID
      ?? windows.allObjects.compactMap { $0 as? InlineAreaAnnotatePanel }.first(where: \.isKeyWindow)?.displayID
    guard let displayID, let hostView = magnifierHostViewBoxes[displayID]?.view else { return false }
    return hostView.magnifier.copyColorToClipboard()
  }

  private func installSelectionMonitorIfNeeded() {
    guard selectionLocalMonitor == nil else { return }
    selectionLocalMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDragged, .leftMouseUp]
    ) { [weak self] event in
      guard let self, self.phase == .selecting, self.selectionStartPoint != nil,
            let window = event.window, self.windows.contains(window) else { return event }
      // Use the event's window coordinates. The global pointer can already have moved
      // (or belong to another display) by the time a queued event is processed.
      let point = self.localDesktopPoint(for: window.convertPoint(toScreen: event.locationInWindow))
      switch event.type {
      case .leftMouseDragged: self.updateSelection(to: point)
      case .leftMouseUp: self.endSelection(at: point)
      default: return event
      }
      return nil
    }
  }

  private func removeSelectionMonitor() {
    if let selectionLocalMonitor {
      NSEvent.removeMonitor(selectionLocalMonitor)
      self.selectionLocalMonitor = nil
    }
  }

  private func localDesktopPoint(for screenPoint: CGPoint) -> CGPoint {
    CGPoint(
      x: screenPoint.x - desktopFrame.minX,
      y: desktopFrame.maxY - screenPoint.y
    )
  }

  /// The real system mouse location, in this session's desktop coordinate space. Used to seed
  /// `InlineAreaAnnotateRootView`'s pointer position (`cursorIndicatorPoint` and
  /// `selectionPointerLocation`) on first appearance: SwiftUI's `onContinuousHover` only
  /// reports a position once it observes an actual hover event, which is not guaranteed to
  /// fire immediately for a window that just appeared under an already-stationary pointer —
  /// without seeding, the magnifier/crosshair can stay invisible until the user moves the
  /// mouse.
  var currentDesktopMouseLocation: CGPoint {
    localDesktopPoint(for: NSEvent.mouseLocation)
  }

  private func complete(_ result: InlineCaptureOutcome, closeWindow: Bool = true) {
    guard !didComplete else { return }
    didComplete = true
    switch result {
    case .saved, .copied, .pinned:
      if let selectionRect { InlineAreaRegionHistory.record(screenRect(for: selectionRect)) }
    case .failure:
      break
    }
    SmartElementQueryService.shared.cancelPendingQueries()
    isMoveModifierActive = false
    selectionPointerLocation = nil
    removeKeyMonitors()
    removeSelectionMonitor()
    frozenSession.invalidate()

    // Restore cursor before closing windows — the inline overlay uses a
    // transparent 1×1 cursor that could persist if window closure does not
    // trigger cursor rect re-evaluation. `showAll()` is a no-op if
    // `beginAnnotating(with:)` already restored it.
    cursorHider.showAll()
    NSCursor.arrow.set()

    if closeWindow {
      for window in windows.allObjects {
        window.close()
      }
    }
    onComplete(result)
  }

  private func persistCommittedSession(for url: URL) {
    guard AnnotationSessionStore.shared.shouldPersist(for: url),
          let sourceImage = state.sourceImage,
          let originalImageData = AnnotateExporter.imageData(from: sourceImage, for: "png") else {
      return
    }
    let sessionData = AnnotationSessionData.snapshot(
      from: state,
      originalImageData: originalImageData
    )
    AnnotationSessionStore.shared.persist(sessionData, for: url)
  }

  private static func imageScale(_ image: NSImage) -> CGFloat {
    guard let rep = image.representations.first as? NSBitmapImageRep,
          image.size.width > 0,
          image.size.height > 0 else { return 1 }
    return max(CGFloat(rep.pixelsWide) / image.size.width, CGFloat(rep.pixelsHigh) / image.size.height, 1)
  }

  private static var preferredOutputScaleFactor: CGFloat {
    // Native density per display; mixed composites promote to the highest native scale.
    1.0
  }

  nonisolated static func matchesCommandSaveShortcut(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown else { return false }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.command),
          !flags.contains(.control),
          !flags.contains(.option) else { return false }
    return event.keyCode == 1 || event.charactersIgnoringModifiers?.lowercased() == "s"
  }

  nonisolated static func matchesCommandCopyShortcut(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown else { return false }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.command),
          !flags.contains(.control),
          !flags.contains(.option),
          !flags.contains(.shift) else { return false }
    return event.keyCode == 8 || event.charactersIgnoringModifiers?.lowercased() == "c"
  }

  nonisolated static func shouldHandleCommandCopyShortcut(
    _ event: NSEvent,
    isLocalEvent: Bool,
    hasTextResponder: Bool,
    hasKeyWindow: Bool
  ) -> Bool {
    matchesCommandCopyShortcut(event) && !hasTextResponder && (isLocalEvent || hasKeyWindow)
  }

  nonisolated static func keyAction(
    for event: NSEvent,
    source: InlineAreaKeyEventSource,
    phase: InlineAreaAnnotatePhase,
    hasTextResponder: Bool,
    hasKeyWindow: Bool,
    hasSelectedAnnotation: Bool = false
  ) -> InlineAreaKeyAction {
    let ownsKeyboard = source == .local || hasKeyWindow
    let plainKey = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    guard phase == .annotating else {
      // Pinny: "," reuses the last captured region.
      if event.type == .keyDown, ownsKeyboard, !hasTextResponder, plainKey, event.keyCode == 43 {
        return .recallRegion(older: true)
      }
      if event.type == .keyDown, event.keyCode == 0,
         event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
         source == .local || hasKeyWindow { return .selectDisplay }
      // Pinny: plain R captures the whole window under the pointer while choosing an area.
      // After a selection exists, R is the rectangle tool again.
      if event.type == .keyDown, !hasTextResponder, source == .local || hasKeyWindow,
         event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
         event.keyCode == 15 || event.charactersIgnoringModifiers?.lowercased() == "r" {
        return .selectWindow
      }
      if event.type == .keyDown, event.keyCode == 48, !hasTextResponder,
         source == .local || hasKeyWindow,
         event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
        return .changeElementLevel(towardParent: !event.modifierFlags.contains(.shift))
      }
      if matchesCancelShortcut(event) {
        return .cancel
      }
      return matchesMagnifierCopyColorShortcut(event) ? .copyMagnifierColor : .passThrough
    }

    if matchesCommandSaveShortcut(event) {
      return .finish
    }

    if hasTextResponder {
      return matchesMoveModifierKey(event) ? .resetMoveModifierAndPassThrough : .passThrough
    }

    if event.type == .keyDown, ownsKeyboard {
      // Arrows move a selected annotation (canvas) or, with none selected, the selection itself.
      if !hasSelectedAnnotation, let nudge = InlineAreaSelectionNudge(event: event) {
        return .adjustSelection(nudge)
      }
      if plainKey, event.keyCode == 43 || event.keyCode == 47 {
        return .recallRegion(older: event.keyCode == 43)
      }
    }

    if shouldHandleCommandCopyShortcut(
      event,
      isLocalEvent: source == .local,
      hasTextResponder: hasTextResponder,
      hasKeyWindow: hasKeyWindow
    ) {
      return .copyCurrentImage
    }

    if matchesMoveModifierKey(event) {
      return .setMoveModifierActive(event.type == .keyDown)
    }

    if matchesFinishShortcut(event) {
      return .copyCurrentImage
    }

    if matchesCancelShortcut(event) {
      return .cancel
    }

    return .passThrough
  }

  nonisolated static func matchesFinishShortcut(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown else { return false }
    return event.keyCode == 36 || event.keyCode == 76
  }

  nonisolated static func matchesCancelShortcut(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown else { return false }
    return event.keyCode == 53
  }

  /// Plain "C" (no modifiers), matching `AreaSelectionOverlayView.copyMagnifierColorIfActive`.
  nonisolated static func matchesMagnifierCopyColorShortcut(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown, event.keyCode == 8 else { return false } // kVK_ANSI_C
    return event.modifierFlags.intersection([.command, .option, .control]).isEmpty
  }

  nonisolated static func matchesMoveModifierKey(_ event: NSEvent) -> Bool {
    event.keyCode == 49 && (event.type == .keyDown || event.type == .keyUp)
  }

  nonisolated static func desktopFrame(for screenFrames: [CGRect]) -> CGRect {
    screenFrames.reduce(CGRect.null) { partialResult, frame in
      partialResult.union(frame)
    }
  }

  nonisolated static func localFrame(for screenFrame: CGRect, in desktopFrame: CGRect) -> CGRect {
    CGRect(
      x: screenFrame.minX - desktopFrame.minX,
      y: desktopFrame.maxY - screenFrame.maxY,
      width: screenFrame.width,
      height: screenFrame.height
    )
  }

  nonisolated static func screenRect(for localRect: CGRect, in desktopFrame: CGRect) -> CGRect {
    CGRect(
      x: desktopFrame.minX + localRect.minX,
      y: desktopFrame.maxY - localRect.maxY,
      width: localRect.width,
      height: localRect.height
    )
  }

  nonisolated static func localRect(for screenRect: CGRect, in desktopFrame: CGRect) -> CGRect {
    CGRect(
      x: screenRect.minX - desktopFrame.minX,
      y: desktopFrame.maxY - screenRect.maxY,
      width: screenRect.width,
      height: screenRect.height
    )
  }

  nonisolated static func displayIDsIntersecting(
    _ screenRect: CGRect,
    screenFramesByDisplayID: [CGDirectDisplayID: CGRect]
  ) -> Set<CGDirectDisplayID> {
    Set(screenFramesByDisplayID.compactMap { displayID, frame in
      frame.intersects(screenRect) ? displayID : nil
    })
  }

  nonisolated static func primaryDisplayID(
    for screenRect: CGRect,
    screenFramesByDisplayID: [CGDirectDisplayID: CGRect],
    fallback: CGDirectDisplayID?
  ) -> CGDirectDisplayID? {
    let bestMatch = screenFramesByDisplayID
      .compactMap { displayID, frame -> (displayID: CGDirectDisplayID, area: CGFloat)? in
        let intersection = frame.intersection(screenRect)
        guard !intersection.isEmpty else { return nil }
        return (displayID, intersection.width * intersection.height)
      }
      .max { $0.area < $1.area }

    return bestMatch?.displayID ?? fallback
  }
}
