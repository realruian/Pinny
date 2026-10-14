//
//  InlineAreaAnnotateSessionTests.swift
//  SnapzyTests
//
//  Unit tests for InlineAreaAnnotateSession coordinate conversion helpers.
//

import AppKit
import CoreGraphics
import XCTest
@testable import Snapzy

final class InlineAreaAnnotateSessionTests: XCTestCase {

  func testResizeTargetsCoverEntireBorderWithoutCornerOverlap() {
    for rect in [CGRect(x: 100, y: 80, width: 600, height: 300), CGRect(x: 0, y: 0, width: 8, height: 10)] {
      let targets = InlineAreaResizeHandle.allCases.map { handle -> CGRect in
        let center = handle.position(in: rect)
        let size = handle.hitSize(in: rect)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
      }
      for fraction in stride(from: 0.0, through: 1.0, by: 0.01) {
        for point in [CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY),
                      CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY),
                      CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction),
                      CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction)] {
          XCTAssertTrue(targets.contains { $0.contains(point) }, "Unreachable border point: \(point)")
        }
      }
      for first in targets.indices {
        for second in targets.indices where second > first {
          let overlap = targets[first].intersection(targets[second])
          XCTAssertTrue(overlap.isNull || overlap.width == 0 || overlap.height == 0)
        }
      }
    }
  }

  @MainActor
  func testMoveAndResizeRefreshRetinaCaptureDimensions() throws {
    let session = try makeSelectionSession()
    defer { session.cancel() }
    session.beginSelection(at: CGPoint(x: 100, y: 100))
    session.endSelection(at: CGPoint(x: 300, y: 250))
    XCTAssertEqual(session.state.selectedTool, .selection)
    let moved = CGRect(x: 180, y: 140, width: 200, height: 150)
    session.moveSelection(to: moved, refreshImage: true)
    XCTAssertEqual(session.selectionRect, moved)
    let resized = CGRect(x: 160, y: 120, width: 320, height: 240)
    session.resizeSelection(to: resized, previousRect: moved)
    XCTAssertEqual(session.selectionRect, resized)
    let image = try XCTUnwrap(session.state.sourceImage)
    let pixels = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    XCTAssertEqual(pixels.width, 640)
    XCTAssertEqual(pixels.height, 480)
  }

  @MainActor
  func testCancelCompletesOnceAndCannotSaveAfterwards() async throws {
    var results: [InlineCaptureOutcome] = []
    let session = try makeSelectionSession(onComplete: { results.append($0) })
    session.beginAnnotating(with: CGRect(x: 100, y: 100, width: 200, height: 150))
    session.cancel()
    session.cancel()
    await session.finish()
    XCTAssertEqual(results.count, 1)
    guard case .failure(.cancelled) = results.first else { return XCTFail("Expected cancellation") }
    XCTAssertFalse(session.isFinishing)
  }

  @MainActor
  func testSaveFailureKeepsSelectionForRetryAndShowsError() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    // A regular file cannot be used as an export directory.
    try Data("not a directory".utf8).write(to: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    var didComplete = false
    let session = try makeSelectionSession(saveDirectory: directory, onComplete: { _ in didComplete = true })
    defer { session.cancel() }
    session.beginAnnotating(with: CGRect(x: 100, y: 100, width: 200, height: 150))
    await session.finish()
    XCTAssertFalse(didComplete)
    XCTAssertEqual(session.phase, .annotating)
    XCTAssertNotNil(session.state.sourceImage)
    XCTAssertNotNil(session.actionMessage)
    XCTAssertFalse(session.isFinishing)
  }

  @MainActor
  func testCopyExitsOnceWithoutResolvingSaveDirectory() throws {
    var outcomes: [InlineCaptureOutcome] = []
    var askedForDirectory = false
    let session = try makeSelectionSession(
      saveDirectoryProvider: { askedForDirectory = true; return nil },
      onComplete: { outcomes.append($0) })
    session.beginAnnotating(with: CGRect(x: 100, y: 100, width: 200, height: 150))
    session.copyCurrentImage()
    session.copyCurrentImage()
    session.cancel()
    XCTAssertFalse(askedForDirectory)
    XCTAssertEqual(outcomes.count, 1)
    guard case .copied = outcomes.first else { return XCTFail("Expected copied outcome") }
    XCTAssertEqual(PinClipboardGeometry.sourceRect(from: .general), CGRect(x: 100, y: 350, width: 200, height: 150))
    let image = try XCTUnwrap(NSImage(pasteboard: .general))
    let pixels = try XCTUnwrap(AnnotateExporter.bestCGImage(from: image))
    XCTAssertEqual(pixels.width, 400)
    XCTAssertEqual(pixels.height, 300)
  }

  @MainActor
  func testPinUsesOriginalPixelsAndPositionWithoutResolvingSaveDirectory() async throws {
    var outcomes: [InlineCaptureOutcome] = []
    var askedForDirectory = false
    var images: [NSImage] = []
    var frames: [CGRect] = []
    let session = try makeSelectionSession(
      saveDirectoryProvider: { askedForDirectory = true; return nil },
      pinImage: { image, rect in images.append(image); frames.append(rect) },
      onComplete: { outcomes.append($0) })
    session.beginAnnotating(with: CGRect(x: 100, y: 100, width: 200, height: 150))
    await session.finishAndPin()
    await session.finishAndPin()
    XCTAssertFalse(askedForDirectory)
    XCTAssertEqual(outcomes.count, 1)
    guard case .pinned = outcomes.first else { return XCTFail("Expected pinned outcome") }
    XCTAssertEqual(frames, [CGRect(x: 100, y: 350, width: 200, height: 150)])
    let pixels = try XCTUnwrap(AnnotateExporter.bestCGImage(from: XCTUnwrap(images.first)))
    XCTAssertEqual(pixels.width, 400)
    XCTAssertEqual(pixels.height, 300)
  }

  @MainActor
  func testCancelledDirectoryPickerPreservesSelectionAndAllowsCopy() async throws {
    var asks = 0
    var outcomes: [InlineCaptureOutcome] = []
    let session = try makeSelectionSession(
      saveDirectoryProvider: { asks += 1; return nil }, onComplete: { outcomes.append($0) })
    session.beginAnnotating(with: CGRect(x: 100, y: 100, width: 200, height: 150))
    await session.finish()
    XCTAssertEqual(asks, 1)
    XCTAssertTrue(outcomes.isEmpty)
    XCTAssertEqual(session.phase, .annotating)
    XCTAssertFalse(session.isFinishing)
    session.copyCurrentImage()
    XCTAssertEqual(outcomes.count, 1)
    guard case .copied = outcomes.first else { return XCTFail("Expected copied outcome") }
    XCTAssertEqual(PinClipboardGeometry.sourceRect(from: .general), CGRect(x: 100, y: 350, width: 200, height: 150))
  }

  func testReturnCopiesWhileTextReturnStaysNative() throws {
    let enter = try makeKeyEvent(keyCode: 36, characters: "\r", flags: [])
    XCTAssertEqual(InlineAreaAnnotateSession.keyAction(for: enter, source: .local,
      phase: .annotating, hasTextResponder: false, hasKeyWindow: true), .copyCurrentImage)
    XCTAssertEqual(InlineAreaAnnotateSession.keyAction(for: enter, source: .local,
      phase: .annotating, hasTextResponder: true, hasKeyWindow: true), .passThrough)
  }

  func testSelectDisplayShortcutAppliesOnlyBeforeSelection() throws {
    let selectAll = try makeKeyEvent(keyCode: 0, characters: "a", flags: .command)
    XCTAssertEqual(InlineAreaAnnotateSession.keyAction(for: selectAll, source: .local,
      phase: .selecting, hasTextResponder: false, hasKeyWindow: true), .selectDisplay)
    XCTAssertEqual(InlineAreaAnnotateSession.keyAction(for: selectAll, source: .local,
      phase: .annotating, hasTextResponder: false, hasKeyWindow: true), .passThrough)
    XCTAssertEqual(InlineAreaAnnotateSession.keyAction(for: selectAll, source: .global,
      phase: .selecting, hasTextResponder: false, hasKeyWindow: false), .passThrough)
  }

  func testPlainRRecallsLastRegionOnlyWhileChoosingArea() throws {
    let r = try makeKeyEvent(keyCode: 15, characters: "r", flags: [])
    XCTAssertEqual(InlineAreaAnnotateSession.keyAction(for: r, source: .local,
      phase: .selecting, hasTextResponder: false, hasKeyWindow: true), .recallRegion(older: true))
    // After a selection exists, R falls through to the rectangle tool shortcut.
    XCTAssertEqual(InlineAreaAnnotateSession.keyAction(for: r, source: .local,
      phase: .annotating, hasTextResponder: false, hasKeyWindow: true), .passThrough)
    XCTAssertEqual(InlineAreaAnnotateSession.keyAction(for: r, source: .global,
      phase: .selecting, hasTextResponder: false, hasKeyWindow: false), .passThrough)
    let commandR = try makeKeyEvent(keyCode: 15, characters: "r", flags: .command)
    XCTAssertEqual(InlineAreaAnnotateSession.keyAction(for: commandR, source: .local,
      phase: .selecting, hasTextResponder: false, hasKeyWindow: true), .passThrough)
  }

  func testSelectionNudgeMovesExpandsAndShrinks() {
    let rect = CGRect(x: 100, y: 100, width: 200, height: 150)
    XCTAssertEqual(InlineAreaSelectionNudge(mode: .move, direction: .up, amount: 1).applied(to: rect),
                   CGRect(x: 100, y: 99, width: 200, height: 150))
    XCTAssertEqual(InlineAreaSelectionNudge(mode: .expand, direction: .left, amount: 10).applied(to: rect),
                   CGRect(x: 90, y: 100, width: 210, height: 150))
    XCTAssertEqual(InlineAreaSelectionNudge(mode: .expand, direction: .down, amount: 1).applied(to: rect),
                   CGRect(x: 100, y: 100, width: 200, height: 151))
    // ⌥↑ pulls the bottom edge up; ⌥→ pulls the left edge right.
    XCTAssertEqual(InlineAreaSelectionNudge(mode: .shrink, direction: .up, amount: 10).applied(to: rect),
                   CGRect(x: 100, y: 100, width: 200, height: 140))
    XCTAssertEqual(InlineAreaSelectionNudge(mode: .shrink, direction: .right, amount: 10).applied(to: rect),
                   CGRect(x: 110, y: 100, width: 190, height: 150))
    let tiny = CGRect(x: 0, y: 0, width: 8, height: 8)
    XCTAssertEqual(InlineAreaSelectionNudge(mode: .shrink, direction: .left, amount: 10).applied(to: tiny).width,
                   InlineAreaSelectionNudge.minimumSide)
  }

  func testArrowKeysAdjustSelectionOnlyWithoutSelectedAnnotation() throws {
    let commandShiftUp = try makeKeyEvent(keyCode: 126, characters: "\u{F700}", flags: [.command, .shift, .numericPad, .function])
    XCTAssertEqual(InlineAreaAnnotateSession.keyAction(for: commandShiftUp, source: .local, phase: .annotating,
      hasTextResponder: false, hasKeyWindow: true),
      .adjustSelection(InlineAreaSelectionNudge(mode: .expand, direction: .up, amount: 10)))
    let left = try makeKeyEvent(keyCode: 123, characters: "\u{F702}", flags: [.numericPad, .function])
    XCTAssertEqual(InlineAreaAnnotateSession.keyAction(for: left, source: .local, phase: .annotating,
      hasTextResponder: false, hasKeyWindow: true, hasSelectedAnnotation: true), .passThrough)
    XCTAssertEqual(InlineAreaAnnotateSession.keyAction(for: left, source: .local, phase: .annotating,
      hasTextResponder: true, hasKeyWindow: true), .passThrough)
    XCTAssertEqual(InlineAreaAnnotateSession.keyAction(for: left, source: .local, phase: .selecting,
      hasTextResponder: false, hasKeyWindow: true), .passThrough)
  }

  func testCommaAndPeriodStepThroughRegionsAfterRecall() throws {
    let comma = try makeKeyEvent(keyCode: 43, characters: ",", flags: [])
    let period = try makeKeyEvent(keyCode: 47, characters: ".", flags: [])
    // R recalls before selecting; "," / "." only step through history afterwards.
    XCTAssertEqual(InlineAreaAnnotateSession.keyAction(for: comma, source: .local, phase: .selecting,
      hasTextResponder: false, hasKeyWindow: true), .passThrough)
    XCTAssertEqual(InlineAreaAnnotateSession.keyAction(for: period, source: .local, phase: .annotating,
      hasTextResponder: false, hasKeyWindow: true), .recallRegion(older: false))
    XCTAssertEqual(InlineAreaAnnotateSession.keyAction(for: comma, source: .local, phase: .annotating,
      hasTextResponder: true, hasKeyWindow: true), .passThrough)
  }

  func testRegionHistoryKeepsNewestFirstWithoutDuplicates() {
    let defaults = UserDefaultsFactory.make()
    let a = CGRect(x: 10, y: 20, width: 300, height: 200)
    let b = CGRect(x: 50, y: 60, width: 100, height: 80)
    InlineAreaRegionHistory.record(a, userDefaults: defaults)
    InlineAreaRegionHistory.record(b, userDefaults: defaults)
    InlineAreaRegionHistory.record(a, userDefaults: defaults)
    XCTAssertEqual(InlineAreaRegionHistory.regions(userDefaults: defaults), [a, b])
    for i in 0..<15 {
      InlineAreaRegionHistory.record(CGRect(x: i, y: 0, width: 40, height: 40), userDefaults: defaults)
    }
    XCTAssertEqual(InlineAreaRegionHistory.regions(userDefaults: defaults).count, InlineAreaRegionHistory.limit)
  }

  // MARK: - desktopFrame

  func testDesktopFrame_unionsScreenFrames() {
    let frames = [
      CGRect(x: 0, y: 0, width: 1000, height: 600),
      CGRect(x: 1000, y: 100, width: 800, height: 500)
    ]
    let desktop = InlineAreaAnnotateSession.desktopFrame(for: frames)
    XCTAssertEqual(desktop.minX, 0)
    XCTAssertEqual(desktop.maxX, 1800)
    XCTAssertEqual(desktop.minY, 0)
    XCTAssertEqual(desktop.maxY, 600)
  }

  // MARK: - localFrame / screenRect / localRect

  func testLocalFrame_convertsScreenToLocal() {
    let desktop = CGRect(x: 0, y: 0, width: 2000, height: 1200)
    let screen = CGRect(x: 1000, y: 100, width: 800, height: 500)
    let local = InlineAreaAnnotateSession.localFrame(for: screen, in: desktop)
    XCTAssertEqual(local.minX, 1000)
    XCTAssertEqual(local.minY, 600) // desktop.maxY - screen.maxY = 1200 - 600
    XCTAssertEqual(local.width, 800)
    XCTAssertEqual(local.height, 500)
  }

  func testScreenRect_convertsLocalToScreen() {
    let desktop = CGRect(x: 0, y: 0, width: 2000, height: 1200)
    let local = CGRect(x: 1000, y: 600, width: 800, height: 500)
    let screen = InlineAreaAnnotateSession.screenRect(for: local, in: desktop)
    XCTAssertEqual(screen.minX, 1000)
    XCTAssertEqual(screen.minY, 100) // desktop.maxY - local.maxY = 1200 - 1100
    XCTAssertEqual(screen.width, 800)
    XCTAssertEqual(screen.height, 500)
  }

  func testLocalRect_roundTrips() {
    let desktop = CGRect(x: 0, y: 0, width: 2000, height: 1200)
    let screen = CGRect(x: 500, y: 200, width: 400, height: 300)
    let local = InlineAreaAnnotateSession.localFrame(for: screen, in: desktop)
    let back = InlineAreaAnnotateSession.screenRect(for: local, in: desktop)
    XCTAssertEqual(back.minX, screen.minX, accuracy: 0.001)
    XCTAssertEqual(back.minY, screen.minY, accuracy: 0.001)
    XCTAssertEqual(back.width, screen.width, accuracy: 0.001)
    XCTAssertEqual(back.height, screen.height, accuracy: 0.001)
  }

  // MARK: - displayIDsIntersecting

  func testDisplayIDsIntersecting_findsIntersecting() {
    let frames: [CGDirectDisplayID: CGRect] = [
      1: CGRect(x: 0, y: 0, width: 1000, height: 600),
      2: CGRect(x: 1000, y: 0, width: 800, height: 600)
    ]
    let rect = CGRect(x: 1100, y: 100, width: 200, height: 200)
    let ids = InlineAreaAnnotateSession.displayIDsIntersecting(rect, screenFramesByDisplayID: frames)
    XCTAssertEqual(ids.count, 1)
    XCTAssertTrue(ids.contains(2))
  }

  func testDisplayIDsIntersecting_emptyWhenNoOverlap() {
    let frames: [CGDirectDisplayID: CGRect] = [
      1: CGRect(x: 0, y: 0, width: 100, height: 100)
    ]
    let rect = CGRect(x: 200, y: 200, width: 50, height: 50)
    let ids = InlineAreaAnnotateSession.displayIDsIntersecting(rect, screenFramesByDisplayID: frames)
    XCTAssertTrue(ids.isEmpty)
  }

  // MARK: - primaryDisplayID

  func testPrimaryDisplayID_returnsLargestOverlap() {
    let frames: [CGDirectDisplayID: CGRect] = [
      1: CGRect(x: 0, y: 0, width: 1000, height: 600),
      2: CGRect(x: 1000, y: 0, width: 800, height: 600)
    ]
    let rect = CGRect(x: 1050, y: 100, width: 400, height: 400)
    let id = InlineAreaAnnotateSession.primaryDisplayID(
      for: rect,
      screenFramesByDisplayID: frames,
      fallback: 99
    )
    XCTAssertEqual(id, 2)
  }

  func testPrimaryDisplayID_usesFallbackWhenNoOverlap() {
    let frames: [CGDirectDisplayID: CGRect] = [
      1: CGRect(x: 0, y: 0, width: 100, height: 100)
    ]
    let rect = CGRect(x: 200, y: 200, width: 50, height: 50)
    let id = InlineAreaAnnotateSession.primaryDisplayID(
      for: rect,
      screenFramesByDisplayID: frames,
      fallback: 99
    )
    XCTAssertEqual(id, 99)
  }

  // MARK: - Shortcut matching

  func testInlineShortcutMatchersRecognizeCommandSaveAndCopy() throws {
    let save = try makeKeyEvent(keyCode: 1, characters: "s", flags: .command)
    let copy = try makeKeyEvent(keyCode: 8, characters: "c", flags: .command)

    XCTAssertTrue(InlineAreaAnnotateSession.matchesCommandSaveShortcut(save))
    XCTAssertTrue(InlineAreaAnnotateSession.matchesCommandCopyShortcut(copy))
  }

  func testInlineCopyShortcutRequiresPlainCommandModifier() throws {
    let shiftCopy = try makeKeyEvent(keyCode: 8, characters: "C", flags: [.command, .shift])
    let optionCopy = try makeKeyEvent(keyCode: 8, characters: "c", flags: [.command, .option])
    let capsLockCopy = try makeKeyEvent(keyCode: 8, characters: "c", flags: [.command, .capsLock])

    XCTAssertFalse(InlineAreaAnnotateSession.matchesCommandCopyShortcut(shiftCopy))
    XCTAssertFalse(InlineAreaAnnotateSession.matchesCommandCopyShortcut(optionCopy))
    XCTAssertTrue(InlineAreaAnnotateSession.matchesCommandCopyShortcut(capsLockCopy))
  }

  func testInlineCopyShortcutRequiresLocalEventOrKeyWindow() throws {
    let copy = try makeKeyEvent(keyCode: 8, characters: "c", flags: .command)

    XCTAssertTrue(InlineAreaAnnotateSession.shouldHandleCommandCopyShortcut(
      copy,
      isLocalEvent: true,
      hasTextResponder: false,
      hasKeyWindow: false
    ))
    XCTAssertTrue(InlineAreaAnnotateSession.shouldHandleCommandCopyShortcut(
      copy,
      isLocalEvent: false,
      hasTextResponder: false,
      hasKeyWindow: true
    ))
    XCTAssertFalse(InlineAreaAnnotateSession.shouldHandleCommandCopyShortcut(
      copy,
      isLocalEvent: false,
      hasTextResponder: false,
      hasKeyWindow: false
    ))
    XCTAssertFalse(InlineAreaAnnotateSession.shouldHandleCommandCopyShortcut(
      copy,
      isLocalEvent: true,
      hasTextResponder: true,
      hasKeyWindow: true
    ))
  }

  func testInlineKeyActionKeepsTextCopyNative() throws {
    let copy = try makeKeyEvent(keyCode: 8, characters: "c", flags: .command)

    XCTAssertEqual(
      InlineAreaAnnotateSession.keyAction(
        for: copy,
        source: .local,
        phase: .annotating,
        hasTextResponder: true,
        hasKeyWindow: true
      ),
      .passThrough
    )
  }

  func testAnnotateObjectShortcutsRouteOnlyPlainCommandKeyDown() throws {
    let copy = try makeKeyEvent(keyCode: 8, characters: "c", flags: .command)
    let layoutAwareCopy = try makeKeyEvent(keyCode: 99, characters: "c", flags: .command)
    let keyCodeFallbackCopy = try makeKeyEvent(keyCode: 8, characters: "", flags: .command)
    let mismatchedKeyCode = try makeKeyEvent(keyCode: 8, characters: "x", flags: .command)
    let paste = try makeKeyEvent(keyCode: 9, characters: "v", flags: .command)
    let duplicate = try makeKeyEvent(keyCode: 2, characters: "d", flags: .command)
    let shiftCopy = try makeKeyEvent(keyCode: 8, characters: "C", flags: [.command, .shift])
    let keyUp = try makeKeyEvent(type: .keyUp, keyCode: 8, characters: "c", flags: .command)

    XCTAssertEqual(AnnotateWindow.annotationObjectShortcut(for: copy, isTextInputActive: false), .copy)
    XCTAssertEqual(AnnotateWindow.annotationObjectShortcut(for: layoutAwareCopy, isTextInputActive: false), .copy)
    XCTAssertEqual(AnnotateWindow.annotationObjectShortcut(for: keyCodeFallbackCopy, isTextInputActive: false), .copy)
    XCTAssertNil(AnnotateWindow.annotationObjectShortcut(for: mismatchedKeyCode, isTextInputActive: false))
    XCTAssertEqual(AnnotateWindow.annotationObjectShortcut(for: paste, isTextInputActive: false), .paste)
    XCTAssertEqual(AnnotateWindow.annotationObjectShortcut(for: duplicate, isTextInputActive: false), .duplicate)
    XCTAssertNil(AnnotateWindow.annotationObjectShortcut(for: shiftCopy, isTextInputActive: false))
    XCTAssertNil(AnnotateWindow.annotationObjectShortcut(for: keyUp, isTextInputActive: false))
  }

  func testAnnotateObjectShortcutsKeepTextAndInputFieldCommandsNative() throws {
    let copy = try makeKeyEvent(keyCode: 8, characters: "c", flags: .command)
    let paste = try makeKeyEvent(keyCode: 9, characters: "v", flags: .command)
    let duplicate = try makeKeyEvent(keyCode: 2, characters: "d", flags: .command)

    XCTAssertNil(AnnotateWindow.annotationObjectShortcut(for: copy, isTextInputActive: true))
    XCTAssertNil(AnnotateWindow.annotationObjectShortcut(for: paste, isTextInputActive: true))
    XCTAssertNil(AnnotateWindow.annotationObjectShortcut(for: duplicate, isTextInputActive: true))
  }

  @MainActor
  func testAnnotateWindowConsumesCopyAndDuplicateWhenNothingIsSelected() throws {
    try skipIfRunningInCI(
      "Exercises NSWindow key-equivalent routing, which is unreliable on headless CI runners"
    )
    let state = AnnotateState()
    let window = AnnotateWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600))
    window.interactionState = state
    let copy = try makeKeyEvent(keyCode: 8, characters: "c", flags: .command)
    let duplicate = try makeKeyEvent(keyCode: 2, characters: "d", flags: .command)

    XCTAssertTrue(window.performKeyEquivalent(with: copy))
    XCTAssertTrue(window.performKeyEquivalent(with: duplicate))
    XCTAssertFalse(state.canUndo)
  }

  func testInlineKeyActionGatesGlobalCopyByKeyWindow() throws {
    let copy = try makeKeyEvent(keyCode: 8, characters: "c", flags: .command)

    XCTAssertEqual(
      InlineAreaAnnotateSession.keyAction(
        for: copy,
        source: .global,
        phase: .annotating,
        hasTextResponder: false,
        hasKeyWindow: false
      ),
      .passThrough
    )
    XCTAssertEqual(
      InlineAreaAnnotateSession.keyAction(
        for: copy,
        source: .global,
        phase: .annotating,
        hasTextResponder: false,
        hasKeyWindow: true
      ),
      .copyCurrentImage
    )
  }

  func testInlineKeyAction_plainCDuringSelecting_returnsCopyMagnifierColor() throws {
    let copy = try makeKeyEvent(keyCode: 8, characters: "c", flags: [])

    XCTAssertEqual(
      InlineAreaAnnotateSession.keyAction(
        for: copy,
        source: .local,
        phase: .selecting,
        hasTextResponder: false,
        hasKeyWindow: true
      ),
      .copyMagnifierColor
    )
  }

  func testInlineKeyAction_modifiedCDuringSelecting_passesThrough() throws {
    let commandC = try makeKeyEvent(keyCode: 8, characters: "c", flags: .command)

    XCTAssertEqual(
      InlineAreaAnnotateSession.keyAction(
        for: commandC,
        source: .local,
        phase: .selecting,
        hasTextResponder: false,
        hasKeyWindow: true
      ),
      .passThrough
    )
  }

  func testInlineKeyAction_plainCDuringAnnotating_isUnaffected() throws {
    // The magnifier only exists during `.selecting`; once annotating, plain "C" must not be
    // swallowed (it still falls through to `.passThrough` as before this feature existed).
    let copy = try makeKeyEvent(keyCode: 8, characters: "c", flags: [])

    XCTAssertEqual(
      InlineAreaAnnotateSession.keyAction(
        for: copy,
        source: .local,
        phase: .annotating,
        hasTextResponder: false,
        hasKeyWindow: true
      ),
      .passThrough
    )
  }

  func testInlineKeyActionKeepsSaveWhileTextEditing() throws {
    let save = try makeKeyEvent(keyCode: 1, characters: "s", flags: .command)

    XCTAssertEqual(
      InlineAreaAnnotateSession.keyAction(
        for: save,
        source: .local,
        phase: .annotating,
        hasTextResponder: true,
        hasKeyWindow: true
      ),
      .finish
    )
  }

  func testInlineKeyActionResetsMoveModifierWhileTextEditing() throws {
    let spaceUp = try makeKeyEvent(type: .keyUp, keyCode: 49, characters: " ", flags: [])

    XCTAssertEqual(
      InlineAreaAnnotateSession.keyAction(
        for: spaceUp,
        source: .local,
        phase: .annotating,
        hasTextResponder: true,
        hasKeyWindow: true
      ),
      .resetMoveModifierAndPassThrough
    )
  }

  func testInlineShortcutMatchersIgnoreKeyUpEvents() throws {
    let saveKeyUp = try makeKeyEvent(type: .keyUp, keyCode: 1, characters: "s", flags: .command)
    let copyKeyUp = try makeKeyEvent(type: .keyUp, keyCode: 8, characters: "c", flags: .command)

    XCTAssertFalse(InlineAreaAnnotateSession.matchesCommandSaveShortcut(saveKeyUp))
    XCTAssertFalse(InlineAreaAnnotateSession.matchesCommandCopyShortcut(copyKeyUp))
  }

  func testInlineShortcutMatchersPreserveFinishCancelAndMoveKeys() throws {
    let returnKey = try makeKeyEvent(keyCode: 36, characters: "\r", flags: [])
    let escapeKey = try makeKeyEvent(keyCode: 53, characters: "\u{1b}", flags: [])
    let spaceDown = try makeKeyEvent(keyCode: 49, characters: " ", flags: [])
    let spaceUp = try makeKeyEvent(type: .keyUp, keyCode: 49, characters: " ", flags: [])

    XCTAssertTrue(InlineAreaAnnotateSession.matchesFinishShortcut(returnKey))
    XCTAssertTrue(InlineAreaAnnotateSession.matchesCancelShortcut(escapeKey))
    XCTAssertTrue(InlineAreaAnnotateSession.matchesMoveModifierKey(spaceDown))
    XCTAssertTrue(InlineAreaAnnotateSession.matchesMoveModifierKey(spaceUp))
  }

  private func makeKeyEvent(
    type: NSEvent.EventType = .keyDown,
    keyCode: UInt16,
    characters: String,
    flags: NSEvent.ModifierFlags
  ) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(
      with: type,
      location: .zero,
      modifierFlags: flags,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: characters.lowercased(),
      isARepeat: false,
      keyCode: keyCode
    ))
  }

  // MARK: - Selection pointer location

  /// Regression: during a drag, the session's local monitor consumes `.leftMouseDragged`
  /// before SwiftUI's gesture sees it, so mid-drag pointer updates arrive ONLY through
  /// these session calls. Pointer-positioned chrome (drawn crosshair, magnifier) reads
  /// `selectionPointerLocation` — it must track every `updateSelection` call or the
  /// crosshair freezes at the drag-start point (⌘⇧7 stuck-crosshair bug).
  @MainActor
  func testUpdateSelectionPublishesPointerLocation() throws {
    let session = try makeSelectionSession()
    session.beginSelection(at: CGPoint(x: 100, y: 100))
    XCTAssertEqual(session.selectionPointerLocation, CGPoint(x: 100, y: 100))

    for point in [CGPoint(x: 150, y: 180), CGPoint(x: 400, y: 500), CGPoint(x: 60, y: 40)] {
      session.updateSelection(to: point)
      XCTAssertEqual(session.selectionPointerLocation, point)
    }

    // Tears down the drag local monitor installed by `beginSelection`.
    session.cancel()
  }

  @MainActor
  func testEndSelectionClearsPointerLocation() throws {
    let session = try makeSelectionSession()
    session.beginSelection(at: CGPoint(x: 100, y: 100))
    // Below the 5×5 minimum: the selection is discarded and the session stays `.selecting`.
    session.endSelection(at: CGPoint(x: 102, y: 102))
    XCTAssertNil(session.selectionPointerLocation)
    XCTAssertNil(session.selectionRect)
    XCTAssertEqual(session.phase, .selecting)
  }

  func testTabSelectsWholeWindowOnlyDuringSelection() throws {
    let tab = try makeKeyEvent(keyCode: 48, characters: "\t", flags: [])
    let backTab = try makeKeyEvent(keyCode: 48, characters: "\t", flags: .shift)
    let appSwitch = try makeKeyEvent(keyCode: 48, characters: "\t", flags: .command)
    XCTAssertEqual(InlineAreaAnnotateSession.keyAction(for: tab, source: .local, phase: .selecting,
      hasTextResponder: false, hasKeyWindow: true), .selectWindow)
    // Pinny removed expand / shrink of the detected element.
    XCTAssertEqual(InlineAreaAnnotateSession.keyAction(for: backTab, source: .local, phase: .selecting,
      hasTextResponder: false, hasKeyWindow: true), .passThrough)
    for event in [tab, backTab, appSwitch] {
      XCTAssertEqual(InlineAreaAnnotateSession.keyAction(for: event, source: .global, phase: .selecting,
        hasTextResponder: false, hasKeyWindow: false), .passThrough)
      XCTAssertEqual(InlineAreaAnnotateSession.keyAction(for: event, source: .local, phase: .annotating,
        hasTextResponder: false, hasKeyWindow: true), .passThrough)
    }
    XCTAssertEqual(InlineAreaAnnotateSession.keyAction(for: appSwitch, source: .local, phase: .selecting,
      hasTextResponder: false, hasKeyWindow: true), .passThrough)
  }

  @MainActor
  private func makeSelectionSession(
    saveDirectory: URL = FileManager.default.temporaryDirectory,
    saveDirectoryProvider: (() -> URL?)? = nil,
    pinImage: @escaping @MainActor (NSImage, CGRect) -> Void = { _, _ in },
    onComplete: @escaping (InlineCaptureOutcome) -> Void = { _ in }
  ) throws -> InlineAreaAnnotateSession {
    // Fake display ID: the session hides the cursor per display at init — a nonexistent
    // display keeps that a harmless no-op instead of hiding the test runner's cursor.
    let displayID: CGDirectDisplayID = 999_999_999
    let screenFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
    let image = try XCTUnwrap(TestImageFactory.solidColor(
      width: 1600, height: 1200, red: 100, green: 150, blue: 200
    ))
    let display = InlineAreaAnnotateDisplay(
      displayID: displayID,
      screenFrame: screenFrame,
      localFrame: screenFrame,
      controlInsets: .zero,
      backdropImage: NSImage(cgImage: image, size: screenFrame.size),
      backdropCGImage: image
    )
    return InlineAreaAnnotateSession(
      primaryDisplayID: displayID,
      desktopFrame: screenFrame,
      displays: [display],
      frozenSession: FrozenAreaCaptureSession.fromSnapshot(FrozenDisplaySnapshot(
        displayID: displayID,
        screenFrame: screenFrame,
        scaleFactor: 2.0,
        colorSpaceName: nil,
        image: image
      )),
      saveDirectory: saveDirectory,
      outputFormat: .png,
      saveDirectoryProvider: saveDirectoryProvider,
      defaults: try XCTUnwrap(UserDefaults(suiteName: "InlineAreaAnnotateSessionTests.pointer")),
      pinImage: pinImage,
      onComplete: onComplete
    )
  }
}
