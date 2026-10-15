//
//  ScrollingCaptureFixedElementTests.swift
//  SnapzyTests
//
//  Pinny: a sticky header and a floating button appear once in a long screenshot.
//

import CoreGraphics
import XCTest
@testable import Snapzy

final class ScrollingCaptureFixedElementTests: XCTestCase {
  private let width = 240
  private let height = 400
  private let navRows = 0..<48
  private let buttonRows = 340..<380
  private let buttonColumns = 170..<210

  /// Never-repeating page rows, as in `ScrollingCaptureRetreatTests`.
  private func pageRows(_ offset: Int, count: Int) -> [UInt8] {
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 255, count: count * bytesPerRow)
    for y in 0..<count {
      var seed = UInt64(truncatingIfNeeded: (offset + y) &* 2_654_435_761 &+ 97)
      for x in 0..<width {
        if x % 40 == 0 { seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
        let i = y * bytesPerRow + x * 4
        pixels[i] = UInt8(truncatingIfNeeded: seed >> 24)
        pixels[i + 1] = UInt8(truncatingIfNeeded: seed >> 32)
        pixels[i + 2] = UInt8(truncatingIfNeeded: seed >> 40)
      }
    }
    return pixels
  }

  /// The page scrolled to `offset`, with the fixed nav and floating button drawn over it.
  private func framePixels(_ offset: Int, nav: Bool = true, button: Bool = true) -> [UInt8] {
    var pixels = pageRows(offset, count: height)
    let bytesPerRow = width * 4
    if nav {
      for y in navRows {
        for x in 0..<width {
          let i = y * bytesPerRow + x * 4
          pixels[i] = 30; pixels[i + 1] = x % 32 < 16 ? 110 : 140; pixels[i + 2] = 235
        }
      }
    }
    if button {
      for y in buttonRows {
        for x in buttonColumns {
          let i = y * bytesPerRow + x * 4
          pixels[i] = 229; pixels[i + 1] = 83; pixels[i + 2] = x == 190 || y == 360 ? 255 : 75
        }
      }
    }
    return pixels
  }

  private func image(_ pixels: [UInt8], rows: Int) -> CGImage {
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(
      width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
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

  private func rows(_ pixels: [UInt8], _ range: Range<Int>) -> [UInt8] {
    Array(pixels[(range.lowerBound * width * 4)..<(range.upperBound * width * 4)])
  }

  private func stitch(positions: [Int], nav: Bool = true, button: Bool = true) -> ScrollingCaptureStitcher {
    let stitcher = ScrollingCaptureStitcher()
    _ = stitcher.start(with: image(framePixels(positions[0], nav: nav, button: button), rows: height))
    for (previous, position) in zip(positions, positions.dropFirst()) {
      let update = stitcher.append(image(framePixels(position, nav: nav, button: button), rows: height),
                                   maxOutputHeight: 10_000,
                                   expectedSignedDeltaPixels: position - previous)
      guard case .appended(position - previous)? = update?.outcome else {
        XCTFail("Step to \(position) not appended: \(String(describing: update?.outcome))")
        return stitcher
      }
    }
    return stitcher
  }

  /// Number of rows where the button's middle column shows the button color.
  private func buttonRowCount(_ pixels: [UInt8], rows count: Int) -> Int {
    (0..<count).filter { y in
      let i = y * width * 4 + 180 * 4
      return pixels[i] == 229 && pixels[i + 1] == 83
    }.count
  }

  func testStickyNavAndFloatingButtonAppearOnce() {
    let positions = [0, 60, 140, 220, 300]
    let stitcher = stitch(positions: positions)
    guard let merged = stitcher.mergedImage() else { return XCTFail("No merged image") }
    let pixels = pixelsOf(merged)
    let last = positions.last!

    // The whole page from the first frame's top to the last frame's bottom, once.
    XCTAssertEqual(merged.height, last + height)
    XCTAssertEqual(buttonRowCount(pixels, rows: merged.height), buttonRows.count)
    // Nav on top, taken from the first frame.
    XCTAssertTrue(rows(pixels, navRows) == rows(framePixels(0), navRows))
    // Floating button at the bottom, taken from the last frame.
    XCTAssertTrue(rows(pixels, (last..<(last + height)).clamped(to: (last + 300)..<(last + height)))
                  == rows(framePixels(last), 300..<height))
    // Everything between them is clean page content.
    let content = (navRows.upperBound + 24)..<(last + 300)
    XCTAssertTrue(rows(pixels, content)
                  == rows(pageRows(0, count: last + height), content),
                  "Page content between the fixed elements differs")
  }

  func testPageWithoutFixedElementsIsUnchanged() {
    let positions = [0, 60, 140, 220]
    let stitcher = stitch(positions: positions, nav: false, button: false)
    guard let merged = stitcher.mergedImage() else { return XCTFail("No merged image") }
    XCTAssertEqual(merged.height, positions.last! + height)
    XCTAssertTrue(pixelsOf(merged) == pageRows(0, count: positions.last! + height))
  }
}
