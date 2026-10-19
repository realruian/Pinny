//
//  AXElementInspector.swift
//  Snapzy
//
//  Filter + coordinate-flip helpers used by SmartElementQueryService.
//  Walks the AX snapshot parent chain to find a "meaningful" element
//  and converts AX top-left global rects into AppKit bottom-left.
//

import AppKit
import Foundation

enum AXElementInspector {

  /// Roles that produce a "good capture target". Narrowest interactive first.
  static let acceptableRoles: Set<String> = [
    "AXButton", "AXLink", "AXCheckBox", "AXRadioButton",
    "AXTextField", "AXTextArea", "AXPopUpButton", "AXMenuItem",
    "AXImage", "AXCell", "AXStaticText", "AXGroup",
    "AXScrollArea", "AXSheet", "AXWebArea", "AXMenu",
    "AXMenuBar", "AXSplitGroup", "AXTable", "AXOutline",
    "AXRow", "AXColumn", "AXToolbar",
    // Website specific roles
    "AXHeading", "AXParagraph", "AXList", "AXForm", "AXGrid",
    "AXDocument", "AXLandmark", "AXRegion", "AXBlockQuote",
    "AXComboBox", "AXSlider", "AXDisclosureTriangle", "AXTabGroup",
    // Dock icons
    "AXDockItem"
  ]

  /// Roles to reject outright — too coarse or non-renderable.
  static let rejectedRoles: Set<String> = [
    "AXApplication", "AXSystemWide", "AXUnknown",
  ]

  /// Subroles that look like components but draw nothing worth capturing.
  static let rejectedSubroles: Set<String> = ["AXSeparatorDockItem"]

  static let minSide: CGFloat = 12
  /// Electron and web content nest 30+ levels below the window.
  static let maxParentDepth = 64
  static let windowFillThreshold: CGFloat = 0.95

  /// Keep every distinct ancestor so the scroll wheel can walk up to the window.
  static func candidates(_ snapshot: AXElementSnapshot, at point: CGPoint? = nil) -> [AXElementSnapshot] {
    var result: [AXElementSnapshot] = []
    var current: AXElementSnapshot? = snapshot
    for depth in 0..<maxParentDepth {
      guard let raw = current else { break }
      guard let candidate = fittedToWindow(raw) else {
        current = raw.parent
        continue
      }
      let rect = candidate.rect
      let validBounds = rect.origin.x.isFinite && rect.origin.y.isFinite
        && rect.width.isFinite && rect.height.isFinite
        && rect.width >= minSide && rect.height >= minSide
      let containsPointer = point.map { rect.insetBy(dx: -1, dy: -1).contains($0) } ?? true
      let containsChild = result.last.map { rect.insetBy(dx: -1, dy: -1).contains($0.rect) } ?? true
      if validBounds, containsPointer, containsChild,
         isMeaningful(candidate, atDepth: depth) || candidate.role == "AXWindow" {
        // AX wrappers often repeat exactly the same geometry. Keep the semantic parent.
        if let last = result.last, approximatelyEqual(last.rect, rect) {
          if componentRoles.contains(candidate.role ?? "") { result[result.count - 1] = candidate }
        } else {
          result.append(candidate)
        }
      }
      if candidate.role == "AXWindow" || candidate.role == "AXApplication" { break }
      current = candidate.parent
    }
    return result
  }

  /// Real UI lies inside its window. An element sticking out sideways is an invisible hit area
  /// (Aside's sidebar splitter reports a 1660x1114 group reaching into the menu bar), so it is
  /// dropped. Content scrolled partly out of view only sticks out above or below; keep its
  /// visible part.
  static func fittedToWindow(_ snapshot: AXElementSnapshot) -> AXElementSnapshot? {
    guard snapshot.role != "AXWindow", let window = snapshot.containingWindowFrame,
          window.width > 0, window.height > 0 else { return snapshot }
    let rect = snapshot.rect
    if rect.minX < window.minX - 2 || rect.maxX > window.maxX + 2 { return nil }
    guard rect.minY < window.minY - 2 || rect.maxY > window.maxY + 2 else { return snapshot }
    let visible = rect.intersection(window)
    guard !visible.isNull else { return nil }
    return AXElementSnapshot(
      role: snapshot.role,
      subrole: snapshot.subrole,
      position: visible.origin,
      size: visible.size,
      containingWindowFrame: window,
      parent: { snapshot.parent }
    )
  }

  private static let componentRoles: Set<String> = [
    "AXGroup", "AXCell", "AXRow", "AXScrollArea", "AXOutline", "AXTable",
    "AXList", "AXGrid", "AXForm", "AXRegion", "AXLandmark", "AXSheet", "AXTabGroup"
  ]

  /// Smallest block the default selection may land on. Text lines and single rows are shorter.
  static let minBlockSize = CGSize(width: 120, height: 40)

  /// Default selection is the first block around the pointer — a card, a panel, the sidebar —
  /// skipping text lines and rows inside it. The scroll wheel still walks down to them.
  /// Falls back to the innermost element when nothing below the window is big enough.
  static func preferredIndex(in candidates: [AXElementSnapshot]) -> Int? {
    guard !candidates.isEmpty else { return nil }
    return candidates.firstIndex {
      $0.role != "AXWindow" && $0.size.width >= minBlockSize.width && $0.size.height >= minBlockSize.height
    } ?? 0
  }

  static func findMeaningful(_ snapshot: AXElementSnapshot) -> AXElementSnapshot? {
    let options = candidates(snapshot)
    guard let index = preferredIndex(in: options) else { return nil }
    return options[index]
  }

  private static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.minX - rhs.minX) <= 1 && abs(lhs.minY - rhs.minY) <= 1
      && abs(lhs.maxX - rhs.maxX) <= 1 && abs(lhs.maxY - rhs.maxY) <= 1
  }

  static func isMeaningful(_ snapshot: AXElementSnapshot, atDepth depth: Int = 0) -> Bool {
    guard let role = snapshot.role else {
      DiagnosticLogger.shared.log(.debug, .capture, "isMeaningful(depth: \(depth)): false (role is nil)")
      return false
    }
    
    if rejectedRoles.contains(role) {
      DiagnosticLogger.shared.log(.debug, .capture, "isMeaningful(depth: \(depth)): false (rejected role)", context: ["role": role])
      return false
    }
    
    if let subrole = snapshot.subrole, rejectedSubroles.contains(subrole) {
      DiagnosticLogger.shared.log(.debug, .capture, "isMeaningful(depth: \(depth)): false (rejected subrole)", context: ["subrole": subrole])
      return false
    }

    if !acceptableRoles.contains(role) {
      DiagnosticLogger.shared.log(.debug, .capture, "isMeaningful(depth: \(depth)): false (role not in acceptableRoles)", context: ["role": role])
      return false
    }
    
    let size = snapshot.size
    guard size.width >= minSide, size.height >= minSide else {
      DiagnosticLogger.shared.log(.debug, .capture, "isMeaningful(depth: \(depth)): false (size too small)", context: ["role": role, "size": "\(size.width)x\(size.height)"])
      return false
    }
    
    if let windowSize = snapshot.containingWindowSize, windowSize.width > 0, windowSize.height > 0 {
      let areaRatio = (size.width * size.height) / (windowSize.width * windowSize.height)
      if areaRatio > windowFillThreshold {
        DiagnosticLogger.shared.log(.debug, .capture, "isMeaningful(depth: \(depth)): false (window ratio > \(windowFillThreshold))", context: ["role": role, "ratio": "\(areaRatio)"])
        return false
      }
    }
    
    return true
  }

  /// Flips an AX top-left rect into AppKit bottom-left global coordinates
  /// using the screen that contains the rect. Returns nil if no screen matches.
  static func screenRect(forTopLeftRect axRect: CGRect) -> CGRect? {
    let primaryHeight = NSScreen.screens.first(where: { $0.displayID == CGMainDisplayID() })?.frame.height
      ?? CGDisplayBounds(CGMainDisplayID()).height
    // AppKit frames are in bottom-left. Flip the AX rect into AppKit space
    // using the primary-display height, then verify a screen contains it.
    let flippedProbe = CGRect(
      x: axRect.origin.x,
      y: primaryHeight - axRect.maxY,
      width: axRect.width,
      height: axRect.height
    )
    let screen = NSScreen.screens.first(where: { $0.frame.intersects(flippedProbe) })
      ?? NSScreen.screens.first(where: { $0.frame.contains(flippedProbe.origin) })
    guard screen != nil else { return nil }
    return flippedProbe.integral
  }
}
