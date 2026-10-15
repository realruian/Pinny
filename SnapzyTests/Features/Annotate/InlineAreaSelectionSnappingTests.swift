//
//  InlineAreaSelectionSnappingTests.swift
//  SnapzyTests
//
//  Unit tests for the inline capture selection's snap guides and snapping.
//

import CoreGraphics
import XCTest
@testable import Snapzy

final class InlineAreaSelectionSnappingTests: XCTestCase {
  private let display = CGRect(x: 0, y: 0, width: 1000, height: 800)

  private func displayGuides() -> InlineAreaSnapGuides {
    InlineAreaSelectionSnapping.guides(displayFrames: [display], windowFrames: [], elementRects: [])
  }

  func testMoveSnapsNearEdgeToDisplayEdge() {
    let result = InlineAreaSelectionSnapping.snapMove(CGRect(x: 4, y: 250, width: 200, height: 100), guides: displayGuides())
    XCTAssertEqual(result.rect, CGRect(x: 0, y: 250, width: 200, height: 100))
    XCTAssertEqual(result.snappedX, 0)
    XCTAssertNil(result.snappedY)
  }

  func testMoveLeavesRectAloneOutsideTolerance() {
    let rect = CGRect(x: 20, y: 250, width: 200, height: 100)
    let result = InlineAreaSelectionSnapping.snapMove(rect, guides: displayGuides())
    XCTAssertEqual(result.rect, rect)
    XCTAssertNil(result.snappedX)
    XCTAssertNil(result.snappedY)
  }

  func testMoveSnapsCenterToDisplayCenterLine() {
    // midX = 503 → display center 500.
    let result = InlineAreaSelectionSnapping.snapMove(CGRect(x: 403, y: 300, width: 200, height: 100), guides: displayGuides())
    XCTAssertEqual(result.rect.midX, 500)
    XCTAssertEqual(result.snappedX, 500)
  }

  func testMoveSnapsEdgeToDisplayCenterLine() {
    let result = InlineAreaSelectionSnapping.snapMove(CGRect(x: 503, y: 300, width: 120, height: 100), guides: displayGuides())
    XCTAssertEqual(result.rect.minX, 500)
  }

  func testWindowEdgeHiddenBehindFrontWindowIsNotAGuide() {
    let front = CGRect(x: 100, y: 100, width: 400, height: 400)
    let back = CGRect(x: 300, y: 150, width: 400, height: 200) // left edge x=300 fully inside `front`
    let guides = InlineAreaSelectionSnapping.guides(displayFrames: [], windowFrames: [front, back], elementRects: [])
    XCTAssertFalse(guides.vertical.contains { $0.position == 300 })
    XCTAssertTrue(guides.vertical.contains { $0.position == 700 })
    XCTAssertTrue(guides.vertical.contains { $0.position == 100 })
  }

  func testPartlyCoveredWindowEdgeKeepsVisiblePart() {
    let front = CGRect(x: 0, y: 0, width: 400, height: 200)
    let back = CGRect(x: 300, y: 100, width: 400, height: 400) // left edge 100...500, covered 100...200
    let guides = InlineAreaSelectionSnapping.guides(displayFrames: [], windowFrames: [front, back], elementRects: [])
    let spans = guides.vertical.filter { $0.position == 300 }.map(\.span)
    XCTAssertEqual(spans, [200...500])
  }

  func testGuideMustOverlapSelectionOnOtherAxis() {
    let element = CGRect(x: 200, y: 600, width: 100, height: 50)
    let guides = InlineAreaSelectionSnapping.guides(displayFrames: [], windowFrames: [], elementRects: [element])
    // Selection far above the element: its x=200 edge must not pull.
    let far = InlineAreaSelectionSnapping.snapMove(CGRect(x: 203, y: 100, width: 80, height: 80), guides: guides)
    XCTAssertNil(far.snappedX)
    let near = InlineAreaSelectionSnapping.snapMove(CGRect(x: 203, y: 580, width: 80, height: 80), guides: guides)
    XCTAssertEqual(near.snappedX, 200)
  }

  func testResizeOnlySnapsMovingEdgeAndKeepsOppositeEdge() {
    var edges = InlineAreaSnapEdges()
    edges.right = true
    let result = InlineAreaSelectionSnapping.snapResize(
      CGRect(x: 4, y: 300, width: 993, height: 100), edges: edges, guides: displayGuides(), minSize: 10
    )
    // Right edge 997 → 1000; left edge at 4 stays (not a moving edge).
    XCTAssertEqual(result.rect, CGRect(x: 4, y: 300, width: 996, height: 100))
    XCTAssertEqual(result.snappedX, 1000)
  }

  func testResizeSkipsSnapThatWouldGoBelowMinimumSize() {
    var edges = InlineAreaSnapEdges()
    edges.left = true
    let rect = CGRect(x: 495, y: 300, width: 8, height: 100) // maxX 503
    let result = InlineAreaSelectionSnapping.snapResize(rect, edges: edges, guides: displayGuides(), minSize: 10)
    XCTAssertEqual(result.rect, rect)
    XCTAssertNil(result.snappedX)
  }
}
