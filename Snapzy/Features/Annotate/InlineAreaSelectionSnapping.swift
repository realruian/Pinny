//
//  InlineAreaSelectionSnapping.swift
//  Snapzy
//
//  Pure snap math for moving / resizing the inline capture selection: edges
//  snap to display edges, display center lines and the visible edges of
//  windows / recognized UI elements. Local overlay coordinates (top-left
//  origin, same space as `InlineAreaAnnotateSession.selectionRect`).
//

import CoreGraphics
import Foundation

/// One straight guide line. Vertical guides sit at `x == position` and cover
/// `span` along y; horizontal guides the other way round.
nonisolated struct InlineAreaSnapLine: Equatable {
  let position: CGFloat
  let span: ClosedRange<CGFloat>
  /// Display center lines also accept the selection's center, not just its edges.
  let isCenterLine: Bool

  init(position: CGFloat, span: ClosedRange<CGFloat>, isCenterLine: Bool = false) {
    self.position = position
    self.span = span
    self.isCenterLine = isCenterLine
  }
}

nonisolated struct InlineAreaSnapGuides: Equatable {
  var vertical: [InlineAreaSnapLine] = []
  var horizontal: [InlineAreaSnapLine] = []

  static let empty = InlineAreaSnapGuides()
}

/// A snapped rect plus the guide position each axis locked onto, so callers can
/// tell when a new snap engages (haptic feedback) versus holding the same one.
nonisolated struct InlineAreaSnapResult: Equatable {
  let rect: CGRect
  let snappedX: CGFloat?
  let snappedY: CGFloat?
}

/// Which selection edges a resize drag moves.
nonisolated struct InlineAreaSnapEdges: Equatable {
  var left = false
  var right = false
  var top = false
  var bottom = false
}

nonisolated enum InlineAreaSelectionSnapping {
  /// Snap distance in points: close enough to feel magnetic, small enough that
  /// a deliberate placement a few points off a line is still reachable.
  static let defaultTolerance: CGFloat = 6
  /// Visible edge pieces shorter than this are slivers between overlapping
  /// windows, not something anyone aims for.
  private static let minimumSegmentLength: CGFloat = 12

  // MARK: Guides

  /// - Parameters:
  ///   - displayFrames: each display, local coordinates.
  ///   - windowFrames: windows front-to-back, local coordinates. An edge only
  ///     counts where no window in front of it covers it.
  ///   - elementRects: recognized UI elements, local coordinates. They were
  ///     visible when recognized, so their edges are used as-is.
  static func guides(
    displayFrames: [CGRect],
    windowFrames: [CGRect],
    elementRects: [CGRect]
  ) -> InlineAreaSnapGuides {
    var guides = InlineAreaSnapGuides()

    for frame in displayFrames where !frame.isEmpty {
      let ys = frame.minY...frame.maxY
      let xs = frame.minX...frame.maxX
      guides.vertical += [
        InlineAreaSnapLine(position: frame.minX, span: ys),
        InlineAreaSnapLine(position: frame.midX, span: ys, isCenterLine: true),
        InlineAreaSnapLine(position: frame.maxX, span: ys),
      ]
      guides.horizontal += [
        InlineAreaSnapLine(position: frame.minY, span: xs),
        InlineAreaSnapLine(position: frame.midY, span: xs, isCenterLine: true),
        InlineAreaSnapLine(position: frame.maxY, span: xs),
      ]
    }

    for (index, frame) in windowFrames.enumerated() where !frame.isEmpty {
      let inFront = Array(windowFrames[..<index])
      for x in [frame.minX, frame.maxX] {
        for span in visibleSegments(of: frame.minY...frame.maxY, atCross: x, vertical: true, occluders: inFront) {
          guides.vertical.append(InlineAreaSnapLine(position: x, span: span))
        }
      }
      for y in [frame.minY, frame.maxY] {
        for span in visibleSegments(of: frame.minX...frame.maxX, atCross: y, vertical: false, occluders: inFront) {
          guides.horizontal.append(InlineAreaSnapLine(position: y, span: span))
        }
      }
    }

    for rect in elementRects where rect.width >= minimumSegmentLength || rect.height >= minimumSegmentLength {
      let ys = rect.minY...rect.maxY
      let xs = rect.minX...rect.maxX
      guides.vertical += [InlineAreaSnapLine(position: rect.minX, span: ys), InlineAreaSnapLine(position: rect.maxX, span: ys)]
      guides.horizontal += [InlineAreaSnapLine(position: rect.minY, span: xs), InlineAreaSnapLine(position: rect.maxY, span: xs)]
    }

    return guides
  }

  /// The parts of an edge (running along `span`, sitting at `cross` on the other
  /// axis) not hidden behind any occluder.
  private static func visibleSegments(
    of span: ClosedRange<CGFloat>,
    atCross cross: CGFloat,
    vertical: Bool,
    occluders: [CGRect]
  ) -> [ClosedRange<CGFloat>] {
    var segments = [span]
    for occluder in occluders {
      let crossRange = vertical ? (occluder.minX, occluder.maxX) : (occluder.minY, occluder.maxY)
      // An edge lying exactly on the occluder's border is still visible.
      guard cross > crossRange.0, cross < crossRange.1 else { continue }
      let lower = vertical ? occluder.minY : occluder.minX
      let upper = vertical ? occluder.maxY : occluder.maxX
      segments = segments.flatMap { segment -> [ClosedRange<CGFloat>] in
        guard lower < segment.upperBound, upper > segment.lowerBound else { return [segment] }
        var pieces: [ClosedRange<CGFloat>] = []
        if lower > segment.lowerBound { pieces.append(segment.lowerBound...lower) }
        if upper < segment.upperBound { pieces.append(upper...segment.upperBound) }
        return pieces
      }
    }
    return segments.filter { $0.upperBound - $0.lowerBound >= minimumSegmentLength }
  }

  // MARK: Snapping

  /// Snap a moved selection: on each axis the nearer of its two edges (or its
  /// center, against display center lines) locks to a guide within tolerance.
  /// Size never changes.
  static func snapMove(
    _ rect: CGRect,
    guides: InlineAreaSnapGuides,
    tolerance: CGFloat = defaultTolerance
  ) -> InlineAreaSnapResult {
    let rect = rect.standardized
    let dx = bestOffset(
      anchors: [(rect.minX, false), (rect.maxX, false), (rect.midX, true)],
      lines: guides.vertical, crossSpan: rect.minY...rect.maxY, tolerance: tolerance
    )
    let dy = bestOffset(
      anchors: [(rect.minY, false), (rect.maxY, false), (rect.midY, true)],
      lines: guides.horizontal, crossSpan: rect.minX...rect.maxX, tolerance: tolerance
    )
    return InlineAreaSnapResult(
      rect: rect.offsetBy(dx: dx?.offset ?? 0, dy: dy?.offset ?? 0),
      snappedX: dx?.position,
      snappedY: dy?.position
    )
  }

  /// Snap the edges a resize drag moves; the opposite edges stay put. A snap
  /// that would shrink the rect below `minSize` is skipped.
  static func snapResize(
    _ rect: CGRect,
    edges: InlineAreaSnapEdges,
    guides: InlineAreaSnapGuides,
    minSize: CGFloat,
    tolerance: CGFloat = defaultTolerance
  ) -> InlineAreaSnapResult {
    let rect = rect.standardized
    var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
    var snappedX: CGFloat?
    var snappedY: CGFloat?
    let ys = rect.minY...rect.maxY
    let xs = rect.minX...rect.maxX

    if edges.left, let hit = bestOffset(anchors: [(minX, false)], lines: guides.vertical, crossSpan: ys, tolerance: tolerance),
       maxX - hit.position >= minSize {
      minX = hit.position
      snappedX = hit.position
    } else if edges.right, let hit = bestOffset(anchors: [(maxX, false)], lines: guides.vertical, crossSpan: ys, tolerance: tolerance),
              hit.position - minX >= minSize {
      maxX = hit.position
      snappedX = hit.position
    }

    if edges.top, let hit = bestOffset(anchors: [(minY, false)], lines: guides.horizontal, crossSpan: xs, tolerance: tolerance),
       maxY - hit.position >= minSize {
      minY = hit.position
      snappedY = hit.position
    } else if edges.bottom, let hit = bestOffset(anchors: [(maxY, false)], lines: guides.horizontal, crossSpan: xs, tolerance: tolerance),
              hit.position - minY >= minSize {
      maxY = hit.position
      snappedY = hit.position
    }

    return InlineAreaSnapResult(
      rect: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
      snappedX: snappedX,
      snappedY: snappedY
    )
  }

  /// Nearest guide to any anchor, among guides that overlap `crossSpan` (a
  /// window edge far above or below the selection is not a target).
  private static func bestOffset(
    anchors: [(value: CGFloat, isCenter: Bool)],
    lines: [InlineAreaSnapLine],
    crossSpan: ClosedRange<CGFloat>,
    tolerance: CGFloat
  ) -> (offset: CGFloat, position: CGFloat)? {
    var best: (offset: CGFloat, position: CGFloat)?
    for line in lines where line.span.overlaps(crossSpan) {
      for anchor in anchors where !anchor.isCenter || line.isCenterLine {
        let offset = line.position - anchor.value
        guard abs(offset) <= tolerance else { continue }
        if best == nil || abs(offset) < abs(best!.offset) {
          best = (offset, line.position)
        }
      }
    }
    return best
  }
}
