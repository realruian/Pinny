//
//  SmartElementQueryService.swift
//  Snapzy
//
//  Resolves the AX element under the cursor and publishes its rect in
//  AppKit bottom-left global coordinates for the AreaSelection overlay
//  to render and capture.
//
//  AX snapshots resolve on one serial worker; selection state is applied on main.
//

import AppKit
import ApplicationServices
import Combine
import Foundation

/// Public entry points and publisher updates are main-thread only.
final class SmartElementQueryService {
  static let shared = SmartElementQueryService()

  // MARK: - Public Publisher

  /// Emits the detected element rect in AppKit bottom-left global coordinates.
  /// Emits nil to clear the highlight (no element, permission denied, cancelled).
  var elementDetectedPublisher: AnyPublisher<CGRect?, Never> {
    detectedSubject.eraseToAnyPublisher()
  }

  // MARK: - Dependencies

  private let snapshotProvider: AXSnapshotProviding
  private let permissionChecker: () -> Bool
  private let debounceMilliseconds: Int

  // MARK: - State

  private struct Request {
    let point: CGPoint
    let pid: Int32?
    let revision: UInt64
    var isRetry = false
  }
  private struct Resolution {
    let rects: [CGRect] // AX top-left coordinates, no live AX references cross the queue.
    let preferredIndex: Int?
    let permissionGranted: Bool
  }
  private let inputSubject = PassthroughSubject<Request, Never>()
  private let queryQueue = DispatchQueue(label: "openshot.element-query", qos: .userInteractive)
  private var revision: UInt64 = 0
  private var latestRequest: Request?
  private var queryInFlight = false
  private var queuedRequest: Request?
  private var candidateRects: [CGRect] = []
  private var selectedIndex: Int?
  private var manuallySelectedRect: CGRect?
  private var currentPID: Int32?
  private var pendingChange: DispatchWorkItem?
  private var pendingRect: CGRect?
  private let stabilizationMilliseconds: Int
  private let coarseRetryMilliseconds: Int
  private let detectedSubject = PassthroughSubject<CGRect?, Never>()
  private var cancellables = Set<AnyCancellable>()
  private var lastEmittedRect: CGRect?
  private var hasEmittedAtLeastOnce = false
  // Permission-denied warning is intentionally logged once per process lifetime
  // (not per selection session) to avoid flooding diagnostics while the user
  // keeps re-entering smart-element mode without granting access.
  private var hasLoggedPermissionDenied = false
  private(set) var permissionDeniedLogCount = 0

  // MARK: - Init

  init(
    snapshotProvider: AXSnapshotProviding = AXAccessibilitySnapshotProvider(),
    permissionChecker: @escaping () -> Bool = { AccessibilityTrust.isGranted },
    debounceMilliseconds: Int = 25,
    stabilizationMilliseconds: Int = 120,
    coarseRetryMilliseconds: Int = 50
  ) {
    self.snapshotProvider = snapshotProvider
    self.permissionChecker = permissionChecker
    self.debounceMilliseconds = debounceMilliseconds
    self.stabilizationMilliseconds = stabilizationMilliseconds
    self.coarseRetryMilliseconds = coarseRetryMilliseconds
    bindPipeline()
  }

  private func bindPipeline() {
    inputSubject
      .throttle(for: .milliseconds(debounceMilliseconds), scheduler: DispatchQueue.main, latest: true)
      .sink { [weak self] request in
        self?.enqueue(request)
      }
      .store(in: &cancellables)
  }

  /// At most one AX traversal runs and one latest request waits. Slow target apps
  /// must not accumulate an unbounded queue of obsolete mouse positions.
  private func enqueue(_ request: Request) {
    guard request.revision == revision else { return }
    if queryInFlight {
      queuedRequest = request
      return
    }
    queryInFlight = true
    queryQueue.async { [weak self] in
      guard let self else { return }
      let result = resolve(at: request.point, pid: request.pid)
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        queryInFlight = false
        if request.revision == revision {
          latestRequest = nil
          apply(result, point: request.point, pid: request.pid, isRetry: request.isRetry)
        }
        if let next = queuedRequest {
          queuedRequest = nil
          enqueue(next)
        }
      }
    }
  }

  // MARK: - Public API

  /// Push the current cursor location (read here so callers never have to fetch it).
  ///
  /// Only safe when nothing else is intercepting mouse-moved events system-wide. Plain area
  /// screenshot's live-passthrough capture installs a `CGEvent` tap that consumes every
  /// mouse-moved event for its own hover tracking — with that tap active, `CGEvent(source:
  /// nil)?.location` stops advancing (it reflects the last event actually delivered through
  /// the normal dispatch path, which the tap intercepts first) and stays frozen at wherever the
  /// cursor was when the tap engaged, even though the pointer keeps moving. Callers in that
  /// situation already have a live, correct point from their own tap callback and should use
  /// `updateLocation(_:pid:)` instead.
  func updateMouseLocation(pid: Int32? = nil) {
    guard let location = CGEvent(source: nil)?.location else { return }
    updateLocation(location, pid: pid)
  }

  /// Push an explicit screen point (Quartz global coordinates, top-left origin — the same
  /// space `CGEvent.location` uses) through the debounced input pipeline, for callers that
  /// already have a live, correct cursor position and can't rely on `updateMouseLocation`'s
  /// internal re-read — see its doc comment for why that can go stale.
  func updateLocation(_ point: CGPoint, pid: Int32? = nil) {
    // Repeated stationary-pointer updates must not invalidate their own slow query.
    if let request = latestRequest, request.point == point, request.pid == pid { return }
    revision &+= 1
    let request = Request(point: point, pid: pid, revision: revision)
    latestRequest = request
    inputSubject.send(request)
  }

  /// Push an explicit point through the debounced input pipeline.
  /// Internal so tests can exercise the debounce/dedup without depending on
  /// the real cursor position. Not part of the production call surface.
  internal func pushInputForTesting(point: CGPoint, pid: Int32?) {
    updateLocation(point, pid: pid)
  }

  /// Clear the current highlight and forget the last emission so the next query
  /// will always emit (even if it matches the previous rect).
  func cancelPendingQueries() {
    revision &+= 1 // A queued or in-flight AX response cannot resurrect a closed selection.
    latestRequest = nil
    queuedRequest = nil
    cancelPendingChange()
    candidateRects = []
    selectedIndex = nil
    manuallySelectedRect = nil
    currentPID = nil
    lastEmittedRect = nil
    hasEmittedAtLeastOnce = false
    detectedSubject.send(nil)
  }

  /// Parent/child navigation is explicit and immediate, never delayed by hover stabilization.
  @discardableResult
  func selectAdjacentCandidate(towardParent: Bool) -> Bool {
    guard let selectedIndex else { return false }
    let next = selectedIndex + (towardParent ? 1 : -1)
    guard candidateRects.indices.contains(next) else { return false }
    cancelPendingChange()
    manuallySelectedRect = candidateRects[next]
    commit(next)
    return true
  }

  /// Prompt the user for Accessibility permission if not already granted.
  /// Returns `true` if permission is already granted at call time.
  ///
  /// Deliberately calls `AccessibilityTrust.isGranted` directly (not the injected
  /// `permissionChecker`) — the system prompt must reflect real TCC trust,
  /// not a test fake. Tests that need to assert prompt behavior should
  /// instead exercise the `queryElement` path, which uses the injectable
  /// checker.
  @discardableResult
  func ensureAccessibilityPermission() -> Bool {
    if AccessibilityTrust.isGranted { return true }
    AccessibilityTrustPrompt.request()
    DiagnosticLogger.shared.log(
      .warning,
      .capture,
      "Smart element capture: accessibility prompt shown"
    )
    return false
  }

  // MARK: - Query

  /// Direct query entry point. Public to the test target via `@testable import`;
  /// production callers go through `updateMouseLocation(pid:)` so the input is
  /// debounced. Tests may call this directly to bypass timing.
  internal func queryElement(at point: CGPoint, pid: Int32?) {
    // Synchronous test seam; production always uses the serial pipeline above.
    apply(resolve(at: point, pid: pid), point: point, pid: pid)
  }

  private func resolve(at point: CGPoint, pid: Int32?) -> Resolution {
    guard permissionChecker() else {
      return Resolution(rects: [], preferredIndex: nil, permissionGranted: false)
    }
    guard let raw = snapshotProvider.snapshot(at: point, pid: pid) else {
      return Resolution(rects: [], preferredIndex: nil, permissionGranted: true)
    }
    let options = AXElementInspector.candidates(raw, at: point)
    return Resolution(rects: options.map(\.rect),
                      preferredIndex: AXElementInspector.preferredIndex(in: options), permissionGranted: true)
  }

  private func apply(_ result: Resolution, point: CGPoint, pid: Int32?, isRetry: Bool = false) {
    guard result.permissionGranted else {
      logPermissionDeniedOnce()
      cancelPendingChange()
      candidateRects = []
      selectedIndex = nil
      manuallySelectedRect = nil
      emit(nil)
      return
    }
    let sameOwner = currentPID == pid
    currentPID = pid
    let oldRect = lastEmittedRect
    let valid = result.rects.enumerated().compactMap { index, rect -> (Int, CGRect)? in
      AXElementInspector.screenRect(forTopLeftRect: rect).map { (index, $0) }
    }
    candidateRects = valid.map { $0.1 }
    let defaultIndex = valid.firstIndex { $0.0 == result.preferredIndex }
    var nextIndex = defaultIndex
    if sameOwner, let manual = manuallySelectedRect,
       let index = candidateRects.firstIndex(of: manual) {
      nextIndex = index
    } else {
      manuallySelectedRect = nil
    }
    let nextRect = nextIndex.map { candidateRects[$0] }
    selectedIndex = oldRect.flatMap { candidateRects.firstIndex(of: $0) }
    if nextRect == oldRect {
      cancelPendingChange()
      commit(nextIndex)
      return
    }
    // Stay on the existing component for brief subelement changes inside its bounds.
    // Crossing its boundary or changing apps switches immediately.
    let oldAXRect = oldRect.map { rect in
      let height = CGDisplayBounds(CGMainDisplayID()).height
      return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }
    // Chromium answers the first hit test at a new spot with a coarse ancestor (often the whole
    // window) and the real element a moment later. Leaving a block for something that swallows
    // it — or for nothing — is asked again before it flashes on screen.
    if !isRetry, sameOwner, let oldRect, let oldAXRect, coarseRetryMilliseconds > 0,
       !oldAXRect.insetBy(dx: -2, dy: -2).contains(point),
       nextRect.map({ $0.insetBy(dx: -1, dy: -1).contains(oldRect) }) ?? true {
      cancelPendingChange()
      let retry = Request(point: point, pid: pid, revision: revision, isRetry: true)
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(coarseRetryMilliseconds)) { [weak self] in
        self?.enqueue(retry)
      }
      return
    }
    if sameOwner, let oldAXRect, oldAXRect.insetBy(dx: -2, dy: -2).contains(point),
       stabilizationMilliseconds > 0 {
      if pendingChange != nil, pendingRect == nextRect { return }
      cancelPendingChange()
      pendingRect = nextRect
      let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        commit(nextRect.flatMap { self.candidateRects.firstIndex(of: $0) })
      }
      pendingChange = work
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(stabilizationMilliseconds), execute: work)
    } else {
      commit(nextIndex)
    }
  }

  private func commit(_ index: Int?) {
    cancelPendingChange()
    selectedIndex = index
    emit(index.map { candidateRects[$0] })
  }

  private func cancelPendingChange() {
    pendingChange?.cancel()
    pendingChange = nil
    pendingRect = nil
  }

  private func emit(_ rect: CGRect?) {
    let block = { [weak self] in
      guard let self = self else { return }
      if self.hasEmittedAtLeastOnce && rect == self.lastEmittedRect { return }
      self.hasEmittedAtLeastOnce = true
      self.lastEmittedRect = rect
      self.detectedSubject.send(rect)
    }
    if Thread.isMainThread {
      block()
    } else {
      DispatchQueue.main.async(execute: block)
    }
  }

  private func logPermissionDeniedOnce() {
    guard !hasLoggedPermissionDenied else { return }
    hasLoggedPermissionDenied = true
    permissionDeniedLogCount += 1
    DiagnosticLogger.shared.log(
      .warning,
      .capture,
      "Smart element capture: accessibility not trusted; emitting nil"
    )
  }
}

/// Accessibility trust without side effects in unit-test hosts. On macOS 27 even
/// `AXIsProcessTrusted()` makes an untrusted process show the "would like to control this Mac"
/// alert, and every test run used to stack another one. Test hosts are never trusted, so they
/// answer false without asking; the installed app asks the system as before.
nonisolated enum AccessibilityTrust {
  static let isUnitTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

  static var isGranted: Bool {
    isUnitTestHost ? false : AXIsProcessTrusted()
  }
}

/// Asks macOS for Accessibility trust, showing the system prompt. Unit-test hosts never prompt.
enum AccessibilityTrustPrompt {
  static func request() {
    guard !AccessibilityTrust.isUnitTestHost else { return }
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
  }
}

extension NSEvent {
  /// Key events from other apps need Accessibility trust. Without it the monitor receives
  /// nothing and only makes macOS show its "control this Mac" alert, so it is not installed.
  static func addTrustedGlobalKeyMonitor(
    matching mask: NSEvent.EventTypeMask,
    handler: @escaping (NSEvent) -> Void
  ) -> Any? {
    guard AccessibilityTrust.isGranted else { return nil }
    return addGlobalMonitorForEvents(matching: mask, handler: handler)
  }
}
