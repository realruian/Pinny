import AppKit
import XCTest
@testable import Snapzy

@MainActor
final class QuickAccessPinInteractionTests: XCTestCase {
  private func makeState() -> QuickAccessPinWindowState {
    let image = NSImage(size: NSSize(width: 200, height: 120))
    return QuickAccessPinWindowState(id: UUID(), url: URL(fileURLWithPath: "/tmp/pin-interaction.png"),
      image: image, thumbnail: image, baseSize: image.size, zoomMode: .windowFollowsImage)
  }

  func testPinCannotStealKeyboardFocusOnClick() {
    let state = makeState()
    let window = QuickAccessPinWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 120), state: state)
    defer { window.close() }
    let image = QuickAccessPinImageDocumentView()
    window.contentView = image
    window.orderFrontRegardless()
    window.makeKey()
    XCTAssertFalse(window.canBecomeKey)
    XCTAssertFalse(window.isKeyWindow)
    XCTAssertFalse(image.needsPanelToBecomeKey)
    XCTAssertFalse(image.acceptsFirstResponder)
  }

  func testLargeScrollIsBoundedAndTrackpadIsGentler() {
    XCTAssertEqual(QuickAccessPinImageScrollView.scrollZoomDelta(-1000, precise: false), 0.1, accuracy: 0.0001)
    XCTAssertEqual(QuickAccessPinImageScrollView.scrollZoomDelta(1000, precise: true), -0.1, accuracy: 0.0001)
    XCTAssertEqual(QuickAccessPinImageScrollView.scrollZoomDelta(10, precise: true), -0.02, accuracy: 0.0001)
    XCTAssertEqual(QuickAccessPinImageScrollView.scrollZoomDelta(.infinity, precise: false), 0)
  }

  func testZoomFitsDisplayWithoutChangingOriginalOrAspectRatio() {
    XCTAssertEqual(QuickAccessPinWindowSizing.maximumZoom(baseSize: CGSize(width: 500, height: 350),
      visibleSize: CGSize(width: 1200, height: 800)), 800.0 / 350, accuracy: 0.0001)
    XCTAssertEqual(QuickAccessPinWindowSizing.maximumZoom(baseSize: CGSize(width: 2000, height: 1400),
      visibleSize: CGSize(width: 1200, height: 800)), 1)
    let frame = CGRect(x: -100, y: 600, width: 1000, height: 700)
    let constrained = QuickAccessPinWindowSizing.repositionAfterZoom(frame, within: CGRect(x: 0, y: 0, width: 1200, height: 800))
    XCTAssertEqual(constrained, CGRect(x: 0, y: 100, width: 1000, height: 700))
  }

  func testQueuedDragUsesEventPositionWithoutGlobalMouseButtonState() throws {
    let state = makeState()
    let window = QuickAccessPinWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 120), state: state)
    defer { window.close() }
    func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
      try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    window.sendEvent(try event(.leftMouseDown, NSPoint(x: 50, y: 40)))
    window.sendEvent(try event(.leftMouseDragged, NSPoint(x: 80, y: 60)))
    XCTAssertEqual(window.frame.origin.x, 130, accuracy: 0.01)
    XCTAssertEqual(window.frame.origin.y, 120, accuracy: 0.01)
    window.sendEvent(try event(.leftMouseUp, NSPoint(x: 50, y: 40)))
    window.sendEvent(try event(.leftMouseDragged, NSPoint(x: 90, y: 70)))
    XCTAssertEqual(window.frame.origin.x, 130, accuracy: 0.01)
  }

  func testHoverDoesNotMakePinKey() {
    let state = makeState()
    let window = QuickAccessPinWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 120), state: state)
    defer { window.close() }
    window.updateMousePassthrough(at: NSPoint(x: 150, y: 150))
    XCTAssertTrue(state.isMouseInside)
    XCTAssertFalse(window.isKeyWindow)
    XCTAssertFalse(window.ignoresMouseEvents)
  }

  func testDoubleClickRequestsCopyAndCloseOnce() throws {
    let state = makeState()
    let window = QuickAccessPinWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 120), state: state)
    defer { window.close() }
    var count = 0
    window.onCopyAndCloseRequested = { count += 1 }
    let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 50, y: 40),
      modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
      eventNumber: 0, clickCount: 2, pressure: 1))
    window.sendEvent(event)
    XCTAssertEqual(count, 1)
  }
}
