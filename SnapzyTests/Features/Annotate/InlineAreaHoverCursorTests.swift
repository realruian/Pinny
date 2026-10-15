//
//  InlineAreaHoverCursorTests.swift
//  SnapzyTests
//
//  Pinny: the capture overlay picks the cursor from what is under the pointer.
//

import XCTest
@testable import Snapzy

final class InlineAreaHoverCursorTests: XCTestCase {
  private let rect = CGRect(x: 100, y: 100, width: 400, height: 300)

  func testCornersWinOverEdges() {
    XCTAssertEqual(InlineAreaResizeHandle.handle(at: CGPoint(x: 101, y: 101), in: rect), .topLeft)
    XCTAssertEqual(InlineAreaResizeHandle.handle(at: CGPoint(x: 499, y: 101), in: rect), .topRight)
    XCTAssertEqual(InlineAreaResizeHandle.handle(at: CGPoint(x: 499, y: 399), in: rect), .bottomRight)
    XCTAssertEqual(InlineAreaResizeHandle.handle(at: CGPoint(x: 101, y: 399), in: rect), .bottomLeft)
  }

  func testEdgesAlongTheirWholeLength() {
    XCTAssertEqual(InlineAreaResizeHandle.handle(at: CGPoint(x: 300, y: 95), in: rect), .top)
    XCTAssertEqual(InlineAreaResizeHandle.handle(at: CGPoint(x: 505, y: 250), in: rect), .right)
    XCTAssertEqual(InlineAreaResizeHandle.handle(at: CGPoint(x: 300, y: 405), in: rect), .bottom)
    XCTAssertEqual(InlineAreaResizeHandle.handle(at: CGPoint(x: 95, y: 250), in: rect), .left)
  }

  func testInsideAndFarOutsideHaveNoHandle() {
    XCTAssertNil(InlineAreaResizeHandle.handle(at: CGPoint(x: 300, y: 250), in: rect))
    XCTAssertNil(InlineAreaResizeHandle.handle(at: CGPoint(x: 40, y: 40), in: rect))
    XCTAssertNil(InlineAreaResizeHandle.handle(at: CGPoint(x: 300, y: 450), in: rect))
  }
}
