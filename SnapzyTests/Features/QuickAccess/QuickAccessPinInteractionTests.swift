import AppKit
import XCTest
@testable import Snapzy

@MainActor
final class QuickAccessPinInteractionTests: XCTestCase {
  func testClipboardImagePreservesBitmapPixelsAndDoesNotReplaceClipboard() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let cg = try XCTUnwrap(TestImageFactory.solidColor(width: 640, height: 360, red: 100, green: 150, blue: 200))
    let image = NSImage(cgImage: cg, size: CGSize(width: 320, height: 180))
    XCTAssertTrue(pasteboard.writeObjects([image]))
    let changeCount = pasteboard.changeCount
    let read = try XCTUnwrap(QuickAccessPinWindowManager.clipboardImage(from: pasteboard))
    let pixels = try XCTUnwrap(AnnotateExporter.bestCGImage(from: read))
    XCTAssertEqual(pixels.width, 640)
    XCTAssertEqual(pixels.height, 360)
    XCTAssertEqual(pasteboard.changeCount, changeCount)
  }

  func testClipboardImageReadsCopiedImageFileAndRejectsPlainText() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
    defer { try? FileManager.default.removeItem(at: url) }
    let cg = try XCTUnwrap(TestImageFactory.solidColor(width: 80, height: 50, red: 10, green: 20, blue: 30))
    let data = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
    try data.write(to: url)
    XCTAssertTrue(pasteboard.writeObjects([url as NSURL]))
    let read = try XCTUnwrap(QuickAccessPinWindowManager.clipboardImage(from: pasteboard))
    let pixels = try XCTUnwrap(AnnotateExporter.bestCGImage(from: read))
    XCTAssertEqual(pixels.width, 80)
    XCTAssertEqual(pixels.height, 50)
    pasteboard.clearContents()
    pasteboard.setString("ordinary text", forType: .string)
    XCTAssertNil(QuickAccessPinWindowManager.clipboardImage(from: pasteboard))
  }

  func testClipboardPinCreatesIndependentWindowsWithoutMutatingClipboard() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let cg = try XCTUnwrap(TestImageFactory.solidColor(width: 400, height: 300, red: 20, green: 30, blue: 40))
    XCTAssertTrue(pasteboard.writeObjects([NSImage(cgImage: cg, size: CGSize(width: 200, height: 150))]))
    let changeCount = pasteboard.changeCount
    let existing = Set(NSApp.windows.map(\.windowNumber))
    let manager = QuickAccessPinWindowManager.shared
    let first = try XCTUnwrap(manager.showClipboardImage(from: pasteboard))
    defer { manager.close(id: first) }
    let second = try XCTUnwrap(manager.showClipboardImage(from: pasteboard))
    defer { manager.close(id: second) }
    XCTAssertNotEqual(first, second)
    let pins = NSApp.windows.filter { !existing.contains($0.windowNumber) && $0 is QuickAccessPinWindow }
    XCTAssertEqual(pins.count, 2)
    XCTAssertTrue(pins.allSatisfy { $0.isVisible && !$0.canBecomeKey })
    XCTAssertEqual(pasteboard.changeCount, changeCount)
    manager.close(id: first)
    XCTAssertEqual(pins.filter(\.isVisible).count, 1)
  }

  func testClipboardAndDirectPinShareFrameSizeAndSquareCorners() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let cg = try XCTUnwrap(TestImageFactory.solidColor(width: 160, height: 100, red: 70, green: 80, blue: 90))
    let image = NSImage(cgImage: cg, size: CGSize(width: 80, height: 50))
    let rect = CGRect(x: 320, y: 250, width: 80, height: 50)
    let manager = QuickAccessPinWindowManager.shared
    let existing = Set(NSApp.windows.map(\.windowNumber))
    let direct = manager.show(image: image, sourceScreenRect: rect)
    defer { manager.close(id: direct) }
    XCTAssertTrue(pasteboard.writeObjects([image]))
    PinClipboardGeometry.write(rect, to: pasteboard)
    let count = pasteboard.changeCount
    let pasted = try XCTUnwrap(manager.showClipboardImage(from: pasteboard))
    defer { manager.close(id: pasted) }
    let pins = NSApp.windows.filter { !existing.contains($0.windowNumber) && $0 is QuickAccessPinWindow }
    XCTAssertEqual(pins.count, 2)
    for pin in pins {
      XCTAssertEqual(pin.frame, rect)
      XCTAssertEqual((pin.value(forKey: "cornerRadius") as? NSNumber)?.doubleValue, 0)
      XCTAssertFalse(pin.canBecomeKey)
    }
    XCTAssertEqual(pasteboard.changeCount, count)
  }

  func testExternalClipboardPinKeepsTinyImageSizeAndHasNoRoundedCorners() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let cg = try XCTUnwrap(TestImageFactory.solidColor(width: 80, height: 50, red: 70, green: 80, blue: 90))
    XCTAssertTrue(pasteboard.writeObjects([NSImage(cgImage: cg, size: CGSize(width: 80, height: 50))]))
    let existing = Set(NSApp.windows.map(\.windowNumber))
    let manager = QuickAccessPinWindowManager.shared
    let id = try XCTUnwrap(manager.showClipboardImage(from: pasteboard))
    defer { manager.close(id: id) }
    let pin = try XCTUnwrap(NSApp.windows.first { !existing.contains($0.windowNumber) && $0 is QuickAccessPinWindow })
    XCTAssertEqual(pin.frame.size, CGSize(width: 80, height: 50), "Clipboard image size: \(NSImage(pasteboard: pasteboard)?.size ?? .zero)")
    XCTAssertEqual((pin.value(forKey: "cornerRadius") as? NSNumber)?.doubleValue, 0)
  }

  func testClipboardGeometryBelongsOnlyToCurrentItemAndRejectsInvalidRect() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("first", forType: .string)
    let rect = CGRect(x: -400, y: 120, width: 80, height: 50)
    PinClipboardGeometry.write(rect, to: pasteboard)
    XCTAssertEqual(PinClipboardGeometry.sourceRect(from: pasteboard), rect)
    pasteboard.clearContents()
    pasteboard.setString("second", forType: .string)
    XCTAssertNil(PinClipboardGeometry.sourceRect(from: pasteboard))
    PinClipboardGeometry.write(.zero, to: pasteboard)
    XCTAssertNil(PinClipboardGeometry.sourceRect(from: pasteboard))
    pasteboard.setPropertyList([0, 0, -1, 20], forType: PinClipboardGeometry.pasteboardType)
    XCTAssertNil(PinClipboardGeometry.sourceRect(from: pasteboard))
  }

  func testExternalPinFitsWholeLargeImageWithoutChangingAspectRatio() {
    let visible = CGRect(x: 100, y: 30, width: 1000, height: 600)
    let frame = QuickAccessPinWindowSizing.initialFrame(imageSize: CGSize(width: 2000, height: 500),
                                                       visibleFrame: visible, mode: .windowFollowsImage)
    XCTAssertEqual(frame, CGRect(x: 100, y: 205, width: 1000, height: 250))
  }

  func testDoubleClickThenClipboardPinRestoresMovedAndResizedFrameAndOriginalPixels() throws {
    let cg = try XCTUnwrap(TestImageFactory.solidColor(width: 800, height: 600, red: 30, green: 90, blue: 150))
    let image = NSImage(cgImage: cg, size: CGSize(width: 400, height: 300))
    let manager = QuickAccessPinWindowManager.shared
    let existing = Set(NSApp.windows.map(\.windowNumber))
    let first = manager.show(image: image, sourceScreenRect: CGRect(x: 200, y: 200, width: 400, height: 300))
    defer { manager.close(id: first) }
    let pin = try XCTUnwrap(NSApp.windows.first { !existing.contains($0.windowNumber) && $0 is QuickAccessPinWindow })
    let changedFrame = CGRect(x: 410, y: 320, width: 200, height: 150)
    pin.setFrame(changedFrame, display: true)
    pin.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 40, y: 40),
      modifierFlags: [], timestamp: 0, windowNumber: pin.windowNumber, context: nil,
      eventNumber: 0, clickCount: 2, pressure: 1)))
    XCTAssertFalse(pin.isVisible)
    XCTAssertEqual(PinClipboardGeometry.sourceRect(from: .general), changedFrame)
    let pixels = try XCTUnwrap(AnnotateExporter.bestCGImage(from: XCTUnwrap(NSImage(pasteboard: .general))))
    XCTAssertEqual(pixels.width, 800)
    XCTAssertEqual(pixels.height, 600)
    let beforeRepin = Set(NSApp.windows.map(\.windowNumber))
    let second = try XCTUnwrap(manager.showClipboardImage())
    defer { manager.close(id: second) }
    let repin = try XCTUnwrap(NSApp.windows.first { !beforeRepin.contains($0.windowNumber) && $0 is QuickAccessPinWindow })
    XCTAssertEqual(repin.frame, changedFrame)
  }

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
