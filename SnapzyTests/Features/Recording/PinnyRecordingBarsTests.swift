//
//  PinnyRecordingBarsTests.swift
//  SnapzyTests
//
//  Pinny: recording toolbars from the F1 toolbar.
//

import XCTest
@testable import Snapzy

@MainActor
final class PinnyRecordingBarsTests: XCTestCase {
  func testPlaybackTimeIsMinutesAndSeconds() {
    XCTAssertEqual(PinnyRecordingPlaybackBar.time(0), "0:00")
    XCTAssertEqual(PinnyRecordingPlaybackBar.time(5.9), "0:05")
    XCTAssertEqual(PinnyRecordingPlaybackBar.time(83), "1:23")
    XCTAssertEqual(PinnyRecordingPlaybackBar.time(-1), "0:00")
  }

  func testPrepBarIsNarrowerThanCaptureToolbar() {
    XCTAssertLessThan(PinnyRecordingPrepBar.width(showsBack: true), InlineAreaToolbarMetrics.idealWidth)
    XCTAssertEqual(PinnyRecordingPrepBar.width(showsBack: true) - PinnyRecordingPrepBar.width(showsBack: false),
                   InlineAreaToolbarMetrics.groupWidth(1) + InlineAreaToolbarMetrics.dividerWidth)
  }

  func testPrepBarPlacementUsesItsOwnWidth() {
    let placement = InlineAreaControlGeometry.placement(
      for: CGRect(x: 400, y: 200, width: 300, height: 200),
      containerSize: CGSize(width: 1440, height: 900),
      showsProperties: false, propertiesContentWidth: 0,
      controlInsets: InlineAreaControlInsets(),
      toolbarWidth: PinnyRecordingPrepBar.width(showsBack: false)
    )
    XCTAssertEqual(placement.toolbarWidth, PinnyRecordingPrepBar.width(showsBack: false))
    XCTAssertEqual(placement.toolbarCenter.x, 550)
    XCTAssertGreaterThan(placement.toolbarCenter.y, 400) // below the selection
  }
}
