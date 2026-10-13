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
    "AXComboBox", "AXSlider", "AXDisclosureTriangle", "AXTabGroup"
  ]

  /// Roles to reject outright — too coarse or non-renderable.
  static let rejectedRoles: Set<String> = [
    "AXApplication", "AXSystemWide", "AXUnknown",
  ]

  static let minSide: CGFloat = 12
  static let maxParentDepth = 25
  static let windowFillThreshold: CGFloat = 0.95

  /// Keep every distinct ancestor so a precise target stays reachable with Shift-Tab.
  /// Default selection is a separate policy; it must not discard small controls.
  static func candidates(_ snapshot: AXElementSnapshot, at point: CGPoint? = nil) -> [AXElementSnapshot] {
    var result: [AXElementSnapshot] = []
    var current: AXElementSnapshot? = snapshot
    for depth in 0..<maxParentDepth {
      guard let candidate = current else { break }
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

  private static let componentRoles: Set<String> = [
    "AXGroup", "AXCell", "AXRow", "AXScrollArea", "AXOutline", "AXTable",
    "AXList", "AXGrid", "AXForm", "AXRegion", "AXLandmark", "AXSheet", "AXTabGroup"
  ]

  static func preferredIndex(in candidates: [AXElementSnapshot]) -> Int? {
    guard !candidates.isEmpty else { return nil }
    // Prefer the nearest useful component, rather than its icon, label, or compact row.
    if let component = candidates.firstIndex(where: {
      componentRoles.contains($0.role ?? "")
        && $0.size.width >= 80 && $0.size.height >= 48
        && $0.size.width * $0.size.height >= 6_000
    }) {
      // A substantial image is already a useful capture target when the only containing
      // component is an enormous page. A small icon does not receive this exception.
      if let image = candidates[..<component].firstIndex(where: {
        $0.role == "AXImage" && $0.size.width >= 160 && $0.size.height >= 120
          && candidates[component].rect.width * candidates[component].rect.height
            > $0.size.width * $0.size.height * 6
      }) { return image }
      return component
    }
    // With no card/pane exposed by the app, prefer the enclosing control to its label.
    if let control = candidates.firstIndex(where: {
      ["AXButton", "AXLink", "AXTextField", "AXTextArea", "AXPopUpButton", "AXMenuItem"].contains($0.role ?? "")
    }) { return control }
    return 0
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
