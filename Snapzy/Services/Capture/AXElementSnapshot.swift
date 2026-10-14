//
//  AXElementSnapshot.swift
//  Snapzy
//
//  Accessibility (AX) snapshot value type and the protocol seam that
//  SmartElementQueryService uses to query the AX tree. Splitting this
//  out from AXElementInspector keeps the filter/flip logic isolated
//  and testable without dragging the real AX provider into tests.
//

import AppKit
import ApplicationServices
import Foundation

// MARK: - Snapshot

/// Pure value snapshot of a single AX element at hit-test time.
/// `position`/`size` are in AX top-left global screen coordinates.
/// `parent` is lazy so the full ancestor chain is not eagerly fetched
/// (researcher-01 §7: requesting kAXParentAttribute in a batch can loop).
struct AXElementSnapshot {
  let role: String?
  let position: CGPoint
  let size: CGSize
  let containingWindowSize: CGSize?
  private let parentResolver: () -> AXElementSnapshot?

  init(
    role: String?,
    position: CGPoint,
    size: CGSize,
    containingWindowSize: CGSize? = nil,
    parent: @escaping () -> AXElementSnapshot? = { nil }
  ) {
    self.role = role
    self.position = position
    self.size = size
    self.containingWindowSize = containingWindowSize
    self.parentResolver = parent
  }

  var parent: AXElementSnapshot? { parentResolver() }
  var rect: CGRect { CGRect(origin: position, size: size) }
}

// MARK: - Zoomed Electron content

/// Maps AX frames of a uniformly zoomed root view back onto the window it fills.
///
/// Feishu mixes both kinds of frames: the shell and page content are divided by the zoom, but the
/// scroll area hosting each embedded page reports real screen points. A frame that does not fit
/// inside the shrunken root cannot be a shrunken one, so it is left as it is.
struct AXZoomCorrection: Equatable {
  let scale: CGFloat
  let root: CGRect
  let windowOrigin: CGPoint

  /// Nil unless the root is the window shrunk by one common factor (same ratio on both axes).
  init?(window: CGRect, root: CGRect) {
    guard root.width > 0, root.height > 0 else { return nil }
    let scaleX = window.width / root.width
    let scaleY = window.height / root.height
    guard scaleX > 1.02, scaleX < 4, abs(scaleX - scaleY) <= scaleX * 0.01 else { return nil }
    scale = (scaleX + scaleY) / 2
    self.root = root
    windowOrigin = window.origin
  }

  func apply(to rect: CGRect) -> CGRect {
    guard root.insetBy(dx: -1, dy: -1).contains(rect) else { return rect }
    return CGRect(
      x: windowOrigin.x + (rect.minX - root.minX) * scale,
      y: windowOrigin.y + (rect.minY - root.minY) * scale,
      width: rect.width * scale,
      height: rect.height * scale
    )
  }
}

// MARK: - Protocol Seam

protocol AXSnapshotProviding {
  /// Returns the AX snapshot at the given top-left global point, scoped to `pid` when provided.
  /// Implementations must be safe to call from the main thread.
  func snapshot(at point: CGPoint, pid: Int32?) -> AXElementSnapshot?
}

// MARK: - Real AX Provider

struct AXAccessibilitySnapshotProvider: AXSnapshotProviding {

  func snapshot(at point: CGPoint, pid: Int32?) -> AXElementSnapshot? {
    let root = pid.map { AXUIElementCreateApplication($0) } ?? AXUIElementCreateSystemWide()
    var element: AXUIElement?
    let error = AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &element)
    guard error == .success, let axElement = element else {
      DiagnosticLogger.shared.log(.error, .capture, "AXUIElementCopyElementAtPosition failed: \(error.rawValue)", context: ["pid": pid.map(String.init) ?? "sys"])
      return nil
    }
    return Self.snapshot(of: axElement, correction: Self.zoomCorrection(for: axElement))
  }

  fileprivate static func snapshot(of element: AXUIElement, correction: AXZoomCorrection?) -> AXElementSnapshot? {
    let role = stringAttribute(of: element, attribute: kAXRoleAttribute)
    guard
      let rawPosition = pointValue(of: element, attribute: kAXPositionAttribute),
      let rawSize = sizeValue(of: element, attribute: kAXSizeAttribute)
    else {
      DiagnosticLogger.shared.log(.error, .capture, "AX element missing position or size", context: ["role": role ?? "nil"])
      return nil
    }

    let windowSize = windowSize(for: element)
    // Windows are reported by the window server and are never zoomed.
    let rect = role == kAXWindowRole
      ? CGRect(origin: rawPosition, size: rawSize)
      : (correction?.apply(to: CGRect(origin: rawPosition, size: rawSize)) ?? CGRect(origin: rawPosition, size: rawSize))

    return AXElementSnapshot(
      role: role,
      position: rect.origin,
      size: rect.size,
      containingWindowSize: windowSize,
      parent: { parentSnapshot(of: element, correction: correction) }
    )
  }

  /// Electron apps with an app-wide zoom (e.g. Feishu at 110%) report element frames divided by the
  /// zoom factor while hit testing uses real screen points. Their root web view then looks smaller than
  /// the window by exactly that factor; measure it and map frames back onto the screen.
  private static func zoomCorrection(for element: AXUIElement) -> AXZoomCorrection? {
    var windowRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef) == .success,
          let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
    let window = windowRef as! AXUIElement
    guard let windowOrigin = pointValue(of: window, attribute: kAXPositionAttribute),
          let windowSize = sizeValue(of: window, attribute: kAXSizeAttribute) else { return nil }

    // The window's direct child on the path from the element is the root content view.
    var root = element
    for _ in 0..<AXElementInspector.maxParentDepth {
      var parentRef: CFTypeRef?
      guard AXUIElementCopyAttributeValue(root, kAXParentAttribute as CFString, &parentRef) == .success,
            let parentRef, CFGetTypeID(parentRef) == AXUIElementGetTypeID() else { return nil }
      let parent = parentRef as! AXUIElement
      if CFEqual(parent, window) { break }
      root = parent
    }
    guard !CFEqual(root, window),
          let rootOrigin = pointValue(of: root, attribute: kAXPositionAttribute),
          let rootSize = sizeValue(of: root, attribute: kAXSizeAttribute) else { return nil }
    return AXZoomCorrection(
      window: CGRect(origin: windowOrigin, size: windowSize),
      root: CGRect(origin: rootOrigin, size: rootSize)
    )
  }

  fileprivate static func parentSnapshot(of element: AXUIElement, correction: AXZoomCorrection?) -> AXElementSnapshot? {
    var parentRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef)
    guard
      result == .success,
      let parentRef,
      CFGetTypeID(parentRef) == AXUIElementGetTypeID()
    else { return nil }
    return snapshot(of: parentRef as! AXUIElement, correction: correction)
  }

  private static func windowSize(for element: AXUIElement) -> CGSize? {
    var windowRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef)
    guard
      result == .success,
      let windowRef,
      CFGetTypeID(windowRef) == AXUIElementGetTypeID()
    else { return nil }
    let windowElement = windowRef as! AXUIElement
    return sizeValue(of: windowElement, attribute: kAXSizeAttribute)
  }

  private static func stringAttribute(of element: AXUIElement, attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
  }

  private static func pointValue(
    of element: AXUIElement,
    attribute: String,
  ) -> CGPoint? {
    guard let axValue = axValue(of: element, attribute: attribute, type: .cgPoint) else { return nil }
    var value = CGPoint.zero
    guard AXValueGetValue(axValue, .cgPoint, &value) else { return nil }
    return value
  }

  private static func sizeValue(
    of element: AXUIElement,
    attribute: String
  ) -> CGSize? {
    guard let axValue = axValue(of: element, attribute: attribute, type: .cgSize) else { return nil }
    var value = CGSize.zero
    guard AXValueGetValue(axValue, .cgSize, &value) else { return nil }
    return value
  }

  private static func axValue(
    of element: AXUIElement,
    attribute: String,
    type: AXValueType
  ) -> AXValue? {
    var raw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
      let raw,
      CFGetTypeID(raw) == AXValueGetTypeID()
    else { return nil }
    let axValue = raw as! AXValue
    guard AXValueGetType(axValue) == type else { return nil }
    return axValue
  }
}
