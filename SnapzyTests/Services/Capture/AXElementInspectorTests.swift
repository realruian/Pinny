//
//  AXElementInspectorTests.swift
//  SnapzyTests
//
//  Unit tests for the AXElementInspector filter + Y-flip helpers used by
//  SmartElementQueryService.
//

import AppKit
import XCTest
@testable import Snapzy

final class AXElementInspectorTests: XCTestCase {

  func testPrefersCardButKeepsIconAndWindowReachable() {
    let window = AXElementSnapshot(role: "AXWindow", position: .zero, size: CGSize(width: 800, height: 600))
    let card = AXElementSnapshot(role: "AXGroup", position: CGPoint(x: 20, y: 20),
      size: CGSize(width: 240, height: 160), parent: { window })
    let icon = AXElementSnapshot(role: "AXImage", position: CGPoint(x: 40, y: 40),
      size: CGSize(width: 24, height: 24), parent: { card })
    let options = AXElementInspector.candidates(icon, at: CGPoint(x: 50, y: 50))
    XCTAssertEqual(options.map(\.role), ["AXImage", "AXGroup", "AXWindow"])
    XCTAssertEqual(AXElementInspector.preferredIndex(in: options), 1)
  }

  func testSidebarPreferredOverCompactRowAndText() {
    let sidebar = AXElementSnapshot(role: "AXOutline", position: .zero, size: CGSize(width: 180, height: 600))
    let row = AXElementSnapshot(role: "AXRow", position: CGPoint(x: 0, y: 30),
      size: CGSize(width: 180, height: 28), parent: { sidebar })
    let text = AXElementSnapshot(role: "AXStaticText", position: CGPoint(x: 20, y: 35),
      size: CGSize(width: 60, height: 18), parent: { row })
    XCTAssertEqual(AXElementInspector.findMeaningful(text)?.role, "AXOutline")
  }

  func testZoomCorrectionMapsFeishuFramesOntoScreen() throws {
    // Feishu at 110%: the root web view reports 1571x892 inside a 1728x981 window.
    let correction = try XCTUnwrap(AXZoomCorrection(
      window: CGRect(x: 0, y: 33, width: 1728, height: 981),
      root: CGRect(x: 0, y: 30, width: 1571, height: 892)
    ))
    // The "前言" callout, measured on screen at about x 673...1573, y 330...531.
    let callout = correction.apply(to: CGRect(x: 610, y: 296, width: 820, height: 184))
    XCTAssertEqual(callout.minX, 671, accuracy: 3)
    XCTAssertEqual(callout.maxX, 1573, accuracy: 3)
    XCTAssertEqual(callout.minY, 326, accuracy: 6)
    XCTAssertEqual(callout.maxY, 531, accuracy: 6)
  }

  func testZoomCorrectionLeavesFeishuPageHostsInScreenPoints() throws {
    // Messages page: the shell and page content are shrunk, the scroll areas hosting pages are not.
    let correction = try XCTUnwrap(AXZoomCorrection(
      window: CGRect(x: 0, y: 33, width: 1728, height: 981),
      root: CGRect(x: 0, y: 30, width: 1571, height: 892)
    ))
    let listHost = CGRect(x: 260, y: 38, width: 343, height: 969)
    XCTAssertEqual(correction.apply(to: listHost), listHost)
    let rightPaneHost = CGRect(x: 609, y: 38, width: 1113, height: 969)
    XCTAssertEqual(correction.apply(to: rightPaneHost), rightPaneHost)
    // The list's web area inside that host is shrunk and lands on the same screen rect.
    let listWebArea = correction.apply(to: CGRect(x: 236, y: 33, width: 313, height: 882))
    XCTAssertEqual(listWebArea.minX, listHost.minX, accuracy: 2)
    XCTAssertEqual(listWebArea.width, listHost.width, accuracy: 2)
    XCTAssertEqual(listWebArea.maxY, listHost.maxY, accuracy: 4)
  }

  func testZoomCorrectionIgnoresUnzoomedOrNonUniformRoots() {
    let window = CGRect(x: 100, y: 100, width: 1200, height: 800)
    XCTAssertNil(AXZoomCorrection(window: window, root: CGRect(x: 100, y: 128, width: 1200, height: 772)))
    XCTAssertNil(AXZoomCorrection(window: window, root: CGRect(x: 100, y: 100, width: 1200, height: 800)))
    XCTAssertNil(AXZoomCorrection(window: window, root: CGRect(x: 300, y: 100, width: 1000, height: 800)))
  }

  func testThinBarIsSkippedForTheEnclosingPanel() {
    // Shape observed in Feishu: a 1026x49 toolbar strip inside a 1026x745 chat panel.
    let window = AXElementSnapshot(role: "AXWindow", position: .zero, size: CGSize(width: 1728, height: 981))
    let panel = AXElementSnapshot(role: "AXGroup", position: CGPoint(x: 300, y: 60),
      size: CGSize(width: 1026, height: 745), parent: { window })
    let strip = AXElementSnapshot(role: "AXGroup", position: CGPoint(x: 300, y: 400),
      size: CGSize(width: 1026, height: 49), parent: { panel })
    let options = AXElementInspector.candidates(strip, at: CGPoint(x: 600, y: 420))
    XCTAssertEqual(options.map(\.size.height), [49, 745, 981])
    XCTAssertEqual(AXElementInspector.preferredIndex(in: options), 1)
  }

  func testSmallControlWithoutPanelFallsBackToWindow() {
    let window = AXElementSnapshot(role: "AXWindow", position: .zero, size: CGSize(width: 480, height: 320))
    let button = AXElementSnapshot(role: "AXButton", position: CGPoint(x: 20, y: 20),
      size: CGSize(width: 90, height: 32), parent: { window })
    let options = AXElementInspector.candidates(button, at: CGPoint(x: 40, y: 30))
    XCTAssertEqual(options.map(\.role), ["AXButton", "AXWindow"])
    XCTAssertEqual(AXElementInspector.preferredIndex(in: options), 1)
  }

  func testButtonPreferredOverItsLabelWithoutComponentAncestor() {
    let button = AXElementSnapshot(role: "AXButton", position: .zero, size: CGSize(width: 90, height: 32))
    let label = AXElementSnapshot(role: "AXStaticText", position: CGPoint(x: 5, y: 5),
      size: CGSize(width: 60, height: 18), parent: { button })
    XCTAssertEqual(AXElementInspector.findMeaningful(label)?.role, "AXButton")
  }

  func testSubstantialImageDoesNotJumpToEnormousPage() {
    let page = AXElementSnapshot(role: "AXScrollArea", position: .zero, size: CGSize(width: 1000, height: 800))
    let photo = AXElementSnapshot(role: "AXImage", position: CGPoint(x: 30, y: 30),
      size: CGSize(width: 200, height: 150), parent: { page })
    XCTAssertEqual(AXElementInspector.findMeaningful(photo)?.role, "AXImage")
  }

  func testDeduplicatesWrappersAndRejectsStaleHitOutsidePointer() {
    let group = AXElementSnapshot(role: "AXGroup", position: .zero, size: CGSize(width: 100, height: 80))
    let image = AXElementSnapshot(role: "AXImage", position: .zero,
      size: CGSize(width: 100, height: 80), parent: { group })
    XCTAssertEqual(AXElementInspector.candidates(image).count, 1)
    XCTAssertTrue(AXElementInspector.candidates(image, at: CGPoint(x: 200, y: 200)).isEmpty)
  }

  // MARK: - Y-flip

  func testScreenRect_flipsAxTopLeftToAppKitBottomLeft_onPrimaryDisplay() throws {
    // Resolve the same screen the inspector uses for its baseline so this test
    // is robust against unusual NSScreen.screens orderings on CI.
    guard let primary = NSScreen.screens.first(where: { $0.displayID == CGMainDisplayID() }) else {
      throw XCTSkip("Headless CI lacks a main NSScreen.")
    }
    let primaryHeight = primary.frame.height
    let axRect = CGRect(x: 100, y: 50, width: 200, height: 80)

    let flipped = try XCTUnwrap(AXElementInspector.screenRect(forTopLeftRect: axRect))

    XCTAssertEqual(flipped.origin.x, 100)
    XCTAssertEqual(flipped.size.width, 200)
    XCTAssertEqual(flipped.size.height, 80)
    XCTAssertEqual(flipped.origin.y, primaryHeight - axRect.maxY)
  }

  func testScreenRect_returnsNil_whenRectIsFarOffAllScreens() {
    let axRect = CGRect(x: -10_000, y: -10_000, width: 50, height: 50)
    XCTAssertNil(AXElementInspector.screenRect(forTopLeftRect: axRect))
  }

  // MARK: - Parent walk filter

  func testFindMeaningful_acceptsAXButtonOfReasonableSize() {
    let button = AXElementSnapshot(
      role: "AXButton",
      position: CGPoint(x: 100, y: 100),
      size: CGSize(width: 80, height: 32),
      containingWindowSize: CGSize(width: 800, height: 600)
    )
    let found = AXElementInspector.findMeaningful(button)
    XCTAssertEqual(found?.role, "AXButton")
    XCTAssertEqual(found?.size, CGSize(width: 80, height: 32))
  }

  func testFindMeaningful_rejectsAXApplication() {
    let app = AXElementSnapshot(
      role: "AXApplication",
      position: .zero,
      size: CGSize(width: 1920, height: 1080)
    )
    XCTAssertNil(AXElementInspector.findMeaningful(app))
  }

  func testFindMeaningful_walksFromTinyChildToAcceptableParent() {
    let parentButton = AXElementSnapshot(
      role: "AXButton",
      position: CGPoint(x: 100, y: 100),
      size: CGSize(width: 80, height: 32),
      containingWindowSize: CGSize(width: 800, height: 600)
    )
    let tinyChild = AXElementSnapshot(
      role: "AXStaticText",
      position: CGPoint(x: 110, y: 105),
      size: CGSize(width: 4, height: 4),   // below 12pt threshold
      containingWindowSize: CGSize(width: 800, height: 600),
      parent: { parentButton }
    )

    let found = AXElementInspector.findMeaningful(tinyChild)
    XCTAssertEqual(found?.role, "AXButton")
  }

  func testFindMeaningful_rejectsElementCoveringNearlyEntireWindow() {
    let oversized = AXElementSnapshot(
      role: "AXGroup",
      position: .zero,
      size: CGSize(width: 800, height: 595),
      containingWindowSize: CGSize(width: 800, height: 600)
    )
    XCTAssertNil(AXElementInspector.findMeaningful(oversized))
  }

  func testFindMeaningful_stopsAtMaxDepth() {
    func chain(depth: Int) -> AXElementSnapshot {
      AXElementSnapshot(
        role: "AXUnknown",
        position: .zero,
        size: CGSize(width: 1, height: 1),
        parent: depth > 0 ? { chain(depth: depth - 1) } : { nil }
      )
    }
    let root = chain(depth: AXElementInspector.maxParentDepth + 4)
    XCTAssertNil(AXElementInspector.findMeaningful(root))
  }
}
