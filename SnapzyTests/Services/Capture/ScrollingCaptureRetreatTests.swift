//
//  ScrollingCaptureRetreatTests.swift
//  SnapzyTests
//
//  Pinny: scrolling back during a long screenshot trims the stitched tail.
//

import CoreGraphics
import XCTest
@testable import Snapzy

final class ScrollingCaptureRetreatTests: XCTestCase {
  private let width = 240
  private let height = 400

  /// A page whose rows never repeat (unlike `TestImageFactory.scrollingFrame`, which repeats
  /// every 256 rows), so a frame has exactly one place in the stitched image.
  private func page(_ offset: Int, rows: Int? = nil) -> CGImage {
    let rows = rows ?? height
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 255, count: rows * bytesPerRow)
    for y in 0..<rows {
      var seed = UInt64(truncatingIfNeeded: (offset + y) &* 2_654_435_761 &+ 97)
      for x in 0..<width {
        if x % 40 == 0 { seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
        let i = y * bytesPerRow + x * 4
        pixels[i] = UInt8(truncatingIfNeeded: seed >> 24)
        pixels[i + 1] = UInt8(truncatingIfNeeded: seed >> 32)
        pixels[i + 2] = UInt8(truncatingIfNeeded: seed >> 40)
      }
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(
      width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
  }

  private func pixelsOf(_ image: CGImage) -> [UInt8] {
    let bytesPerRow = image.width * 4
    var pixels = [UInt8](repeating: 0, count: image.height * bytesPerRow)
    let context = CGContext(
      data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
      bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return pixels
  }

  private func assertMerged(_ stitcher: ScrollingCaptureStitcher, startsAt offset: Int, rows: Int,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(stitcher.outputHeight, rows, file: file, line: line)
    guard let merged = stitcher.mergedImage() else {
      return XCTFail("No merged image", file: file, line: line)
    }
    XCTAssertTrue(pixelsOf(merged) == pixelsOf(page(offset, rows: rows)),
                  "Stitched image differs from the page", file: file, line: line)
  }

  /// Start at `offset`, then scroll forward by each delta with a known direction.
  private func stitched(from offset: Int, forward deltas: [Int]) -> ScrollingCaptureStitcher {
    let stitcher = ScrollingCaptureStitcher()
    _ = stitcher.start(with: page(offset))
    var position = offset
    for delta in deltas {
      position += delta
      let update = stitcher.append(page(position), maxOutputHeight: 10_000, expectedSignedDeltaPixels: delta)
      guard case .appended(delta)? = update?.outcome else {
        XCTFail("Forward step \(delta) not appended: \(String(describing: update?.outcome))")
        return stitcher
      }
    }
    return stitcher
  }

  func testScrollBackTrimsTailToCurrentViewport() {
    let stitcher = stitched(from: 0, forward: [60, 80])
    let update = stitcher.append(page(90), maxOutputHeight: 10_000,
                                 expectedSignedDeltaPixels: -50, retreat: .preferred)
    guard case .trimmed(50)? = update?.outcome else {
      return XCTFail("Expected a 50-row trim, got \(String(describing: update?.outcome))")
    }
    assertMerged(stitcher, startsAt: 0, rows: height + 90)
  }

  func testScrollingForwardAgainAfterTrimContinuesSeamlessly() {
    let stitcher = stitched(from: 0, forward: [60, 80])
    _ = stitcher.append(page(90), maxOutputHeight: 10_000, expectedSignedDeltaPixels: -50, retreat: .preferred)
    let update = stitcher.append(page(150), maxOutputHeight: 10_000, expectedSignedDeltaPixels: 60)
    guard case .appended(60)? = update?.outcome else {
      return XCTFail("Expected a 60-row append, got \(String(describing: update?.outcome))")
    }
    assertMerged(stitcher, startsAt: 0, rows: height + 150)
  }

  func testFrameThatOutranTrackingIsRejectedThenRelocated() {
    let stitcher = stitched(from: 0, forward: [60, 80, 80])
    // Moved more than a frame since the last match: nothing overlaps, nothing is stitched.
    let lost = stitcher.append(page(900), maxOutputHeight: 10_000, retreat: .allowed)
    guard case .ignoredAlignmentFailed? = lost?.outcome else {
      return XCTFail("A frame with no overlap must not be stitched, got \(String(describing: lost?.outcome))")
    }
    assertMerged(stitcher, startsAt: 0, rows: height + 220)

    // Back on stitched content, but above the last matched frame: located in the tail.
    let found = stitcher.append(page(150), maxOutputHeight: 10_000, retreat: .allowed)
    guard case .trimmed(70)? = found?.outcome else {
      return XCTFail("Expected to relocate 70 rows up, got \(String(describing: found?.outcome))")
    }
    assertMerged(stitcher, startsAt: 0, rows: height + 150)

    let next = stitcher.append(page(230), maxOutputHeight: 10_000, retreat: .allowed)
    guard case .appended(80)? = next?.outcome else {
      return XCTFail("Expected to continue by 80 rows, got \(String(describing: next?.outcome))")
    }
    assertMerged(stitcher, startsAt: 0, rows: height + 230)
  }

  func testScrollingAboveTheStartDoesNotTrim() {
    let stitcher = stitched(from: 600, forward: [40])
    let update = stitcher.append(page(100), maxOutputHeight: 10_000,
                                 expectedSignedDeltaPixels: -540, retreat: .preferred)
    if case .trimmed? = update?.outcome {
      XCTFail("Content above the first frame was never stitched and must not be trimmed to")
    }
    assertMerged(stitcher, startsAt: 600, rows: height + 40)
  }

  func testUnknownDirectionFallsBackToRelocationWhenForwardDoesNotMatch() {
    let stitcher = stitched(from: 0, forward: [60, 80])
    let update = stitcher.append(page(100), maxOutputHeight: 10_000, retreat: .allowed)
    guard case .trimmed(40)? = update?.outcome else {
      return XCTFail("Expected a 40-row trim, got \(String(describing: update?.outcome))")
    }
    assertMerged(stitcher, startsAt: 0, rows: height + 100)
  }

  func testForwardOnlyBatchNeverTrims() {
    let stitcher = stitched(from: 0, forward: [60])
    let update = stitcher.append(page(30), maxOutputHeight: 10_000, expectedSignedDeltaPixels: 30)
    if case .trimmed? = update?.outcome {
      XCTFail("A forward batch must not trim")
    }
    XCTAssertEqual(stitcher.outputHeight, height + 60)
  }

  func testTrackpadBounceBelowMinimumIsIgnoredWithoutFailure() {
    let stitcher = stitched(from: 0, forward: [60])
    let update = stitcher.append(page(52), maxOutputHeight: 10_000,
                                 expectedSignedDeltaPixels: -8, retreat: .preferred)
    guard case .ignoredNoMovement? = update?.outcome else {
      return XCTFail("A few-pixel bounce should be ignored, got \(String(describing: update?.outcome))")
    }
    XCTAssertEqual(update?.matchFailureCount, 0)
    XCTAssertEqual(stitcher.outputHeight, height + 60)
  }

  func testNoMovementIsNotTreatedAsScrollBack() {
    let stitcher = stitched(from: 0, forward: [60])
    let update = stitcher.append(page(60), maxOutputHeight: 10_000, retreat: .preferred)
    if case .trimmed? = update?.outcome {
      XCTFail("An unchanged frame must not trim")
    }
    XCTAssertEqual(stitcher.outputHeight, height + 60)
  }

  func testRepeatingPageIsNotRelocatedToTheWrongCopy() {
    // `scrollingFrame` repeats every 256 rows: a scroll-back has several equally good places.
    func frame(_ offset: Int) -> CGImage {
      TestImageFactory.scrollingFrame(width: width, height: height, logicalYOffset: offset)!
    }
    let stitcher = ScrollingCaptureStitcher()
    _ = stitcher.start(with: frame(0))
    var position = 0
    for delta in [60, 80, 80, 80, 80] {
      position += delta
      _ = stitcher.append(frame(position), maxOutputHeight: 10_000, expectedSignedDeltaPixels: delta)
    }
    let before = stitcher.outputHeight
    let update = stitcher.append(frame(position - 300), maxOutputHeight: 10_000, retreat: .allowed)
    if case .trimmed(let rows)? = update?.outcome {
      XCTAssertEqual(rows, 300, "Trimmed to the wrong repeat of the page")
    } else {
      XCTAssertEqual(stitcher.outputHeight, before)
    }
  }
}

final class LongScreenshotGeometryTests: XCTestCase {
  private let visible = CGRect(x: 0, y: 0, width: 1728, height: 1080)

  func testPinKeepsSelectionTopLeftWhenItFits() {
    let selection = CGRect(x: 330, y: 400, width: 570, height: 500)
    let rect = LongScreenshotPinGeometry.pinRect(
      imageSize: CGSize(width: 570, height: 800), selectedRect: selection, visibleFrame: visible)
    XCTAssertEqual(rect, CGRect(x: 330, y: 100, width: 570, height: 800))
  }

  func testPinShrinksTallImagesToTheScreenAndMovesUpOnlyAsNeeded() {
    let selection = CGRect(x: 330, y: 400, width: 570, height: 500)
    let rect = LongScreenshotPinGeometry.pinRect(
      imageSize: CGSize(width: 570, height: 2160), selectedRect: selection, visibleFrame: visible)
    XCTAssertEqual(rect.height, 1080, accuracy: 0.001)
    XCTAssertEqual(rect.width, 285, accuracy: 0.001)
    XCTAssertEqual(rect.minX, 330)
    XCTAssertEqual(rect.minY, 0)
  }

  func testToolbarSitsCenteredBelowTheSelection() {
    let selection = CGRect(x: 330, y: 400, width: 570, height: 500)
    let frame = LongScreenshotToolbarGeometry.frame(
      size: CGSize(width: 300, height: 68), selection: selection, visibleFrame: visible)
    XCTAssertEqual(frame.midX, selection.midX, accuracy: 0.5)
    XCTAssertEqual(frame.maxY, selection.minY - InlineAreaLayout.selectionGap, accuracy: 0.5)
  }

  func testToolbarMovesAboveWhenThereIsNoRoomBelow() {
    let selection = CGRect(x: 330, y: 20, width: 570, height: 500)
    let frame = LongScreenshotToolbarGeometry.frame(
      size: CGSize(width: 300, height: 68), selection: selection, visibleFrame: visible)
    XCTAssertEqual(frame.minY, selection.maxY + InlineAreaLayout.selectionGap, accuracy: 0.5)
  }

  func testToolbarStaysOnScreenNearTheEdge() {
    let selection = CGRect(x: 0, y: 400, width: 100, height: 300)
    let frame = LongScreenshotToolbarGeometry.frame(
      size: CGSize(width: 300, height: 68), selection: selection, visibleFrame: visible)
    XCTAssertEqual(frame.minX, InlineAreaLayout.screenPadding, accuracy: 0.5)
  }

  func testTrimKeepsTheRowsBetweenTheHandles() {
    XCTAssertEqual(ScrollingCaptureTrim.rows(height: 1000, top: 0.1, bottom: 0.25), 100..<750)
    XCTAssertEqual(ScrollingCaptureTrim.rows(height: 1000, top: 0, bottom: 0), 0..<1000)
    XCTAssertEqual(ScrollingCaptureTrim.rows(height: 1000, top: 0.6, bottom: 0.6).count, 1)
  }
}
