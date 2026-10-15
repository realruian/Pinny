//
//  AnnotationToolType.swift
//  Snapzy
//
//  Enum defining all available annotation tools
//

import Foundation

/// Tool types available in annotation editor
nonisolated enum AnnotationToolType: String, CaseIterable, Identifiable {
  case selection
  case crop
  case rectangle
  case filledRectangle
  case oval
  case arrow
  case line
  case text
  case highlighter
  case blur
  case spotlight
  case counter
  case watermark
  case pencil
  case mockup

  var id: String { rawValue }

  /// Annotation tools that create or edit drawable items on the image canvas.
  /// Shared by the full Annotate window and inline area-annotate overlay so the
  /// two surfaces stay in sync when tools are added.
  static let drawableTools: [AnnotationToolType] = [
    .rectangle, .filledRectangle, .oval, .arrow, .line, .text, .highlighter,
    .blur, .spotlight, .counter, .watermark, .pencil
  ]

  static let inlineAnnotateTools: [AnnotationToolType] = [.selection] + drawableTools

  private static let inlineShapeToolSet: Set<AnnotationToolType> = [
    .rectangle, .filledRectangle, .oval, .arrow, .line
  ]

  /// Pinny: tools that share one inline toolbar button, switched in the properties bar. The
  /// first tool of each family is the default.
  static let inlineToolFamilies: [[AnnotationToolType]] = [
    [.rectangle, .filledRectangle, .oval],
    [.arrow, .line],
  ]

  static func inlineFamily(of tool: AnnotationToolType) -> [AnnotationToolType]? {
    inlineToolFamilies.first { $0.contains(tool) }
  }
  static let inlineToolGroups: [[AnnotationToolType]] = [
    // Pinny: one group for every annotation tool; the toolbar splits groups with a hairline,
    // so fewer, larger groups read calmer (validation/toolbar-c-all-bars-mockup.html).
    [.selection] + drawableTools.filter { inlineShapeToolSet.contains($0) }
      + drawableTools.filter { !inlineShapeToolSet.contains($0) }
  ]

  var icon: String {
    switch self {
    case .selection: return "cursorarrow"
    case .crop: return "crop"
    case .rectangle: return "rectangle"
    case .filledRectangle: return "rectangle.fill"
    case .oval: return "circle"
    case .arrow: return "arrow.up.right"
    case .line: return "line.diagonal"
    case .text: return "character.textbox"
    case .highlighter: return "highlighter"
    case .blur: return "eye.slash"
    case .spotlight: return "viewfinder"
    case .counter: return "list.number"
    case .watermark: return "seal"
    case .pencil: return "pencil"
    case .mockup: return "cube.transparent"
    }
  }

  /// Default keyboard shortcut for this tool
  var defaultShortcut: Character {
    switch self {
    case .selection: return "v"
    case .crop: return "c"
    case .rectangle: return "r"
    case .filledRectangle: return "f"
    case .oval: return "o"
    case .arrow: return "a"
    case .line: return "l"
    case .text: return "t"
    case .highlighter: return "h"
    case .blur: return "b"
    case .spotlight: return "s"
    case .counter: return "n"
    case .watermark: return "w"
    case .pencil: return "p"
    case .mockup: return "m"
    }
  }

  /// Display name for the tool
  var displayName: String {
    switch self {
    case .selection: return L10n.Annotate.selectionTool
    case .crop: return L10n.Annotate.cropTool
    case .rectangle: return L10n.Annotate.rectangleTool
    case .filledRectangle: return L10n.Annotate.filledRectangleTool
    case .oval: return L10n.Annotate.ovalTool
    case .arrow: return L10n.Annotate.arrowTool
    case .line: return L10n.Annotate.lineTool
    case .text: return L10n.Annotate.textTool
    case .highlighter: return L10n.Annotate.highlighterTool
    case .blur: return L10n.Annotate.blurTool
    case .spotlight: return L10n.Annotate.spotlightTool
    case .counter: return L10n.Annotate.counterTool
    case .watermark: return L10n.Annotate.watermarkTool
    case .pencil: return L10n.Annotate.pencilTool
    case .mockup: return L10n.Annotate.mockupTool
    }
  }

  var supportsQuickPropertiesBar: Bool {
    switch self {
    case .rectangle, .filledRectangle, .oval, .arrow, .line, .text, .highlighter, .blur, .spotlight, .counter, .watermark, .pencil:
      return true
    case .selection, .crop, .mockup:
      return false
    }
  }

  /// Drawable tools that should only commit a new blank-canvas item after a
  /// drag intent. Counter stays click-to-place, text keeps its click-to-edit
  /// flow, and freehand tools keep their existing path-count behavior.
  var requiresDragToCreateAnnotation: Bool {
    switch self {
    case .rectangle, .filledRectangle, .oval, .arrow, .line, .blur, .spotlight, .watermark:
      return true
    case .selection, .crop, .text, .highlighter, .counter, .pencil, .mockup:
      return false
    }
  }

  var supportsQuickStrokeColor: Bool {
    switch self {
    case .rectangle, .filledRectangle, .oval, .arrow, .line, .text, .highlighter, .spotlight, .counter, .watermark, .pencil:
      return true
    case .selection, .crop, .blur, .mockup:
      return false
    }
  }

  var supportsQuickFillColor: Bool {
    false
  }

  /// A filled rectangle is one solid block; outline width and dashes would only nibble its edge.
  var supportsQuickStrokeWidth: Bool {
    switch self {
    case .rectangle, .oval, .arrow, .line, .highlighter, .blur, .spotlight, .counter, .pencil:
      return true
    case .selection, .crop, .filledRectangle, .text, .watermark, .mockup:
      return false
    }
  }

  /// While parameter sync is on these tools share one color. Highlighter, watermark and
  /// spotlight keep their own: a yellow marker, a white watermark, a borderless spotlight.
  var sharesSyncedColor: Bool {
    switch self {
    case .rectangle, .filledRectangle, .oval, .arrow, .line, .text, .counter, .pencil:
      return true
    case .selection, .crop, .highlighter, .blur, .spotlight, .watermark, .mockup:
      return false
    }
  }

  /// The width slider means line thickness only for outlines. For blur it is the strength,
  /// for a counter the badge size, for a marker the band height, so those are not shared.
  var sharesSyncedStrokeWidth: Bool {
    switch self {
    case .rectangle, .oval, .arrow, .line, .pencil:
      return true
    case .selection, .crop, .filledRectangle, .text, .highlighter, .blur, .spotlight, .counter, .watermark, .mockup:
      return false
    }
  }

  var supportsQuickCornerRadius: Bool {
    switch self {
    case .rectangle, .filledRectangle, .text, .spotlight:
      return true
    case .selection, .crop, .oval, .arrow, .line, .highlighter, .blur, .counter, .watermark, .pencil, .mockup:
      return false
    }
  }

  var supportsQuickLineStyle: Bool {
    switch self {
    case .rectangle, .oval, .arrow, .line, .spotlight:
      return true
    case .selection, .crop, .filledRectangle, .text, .highlighter, .blur, .counter, .watermark, .pencil, .mockup:
      return false
    }
  }
}

/// Pinny: annotation tools the user switched off in Settings. A hidden tool leaves the capture
/// toolbar and its shortcut stops working; the selection tool cannot be hidden.
enum AnnotateToolVisibility {
  static func hiddenTools(userDefaults: UserDefaults = .standard) -> Set<AnnotationToolType> {
    let rawValues = userDefaults.stringArray(forKey: PreferencesKeys.annotateHiddenTools) ?? []
    return Set(rawValues.compactMap(AnnotationToolType.init(rawValue:))).subtracting([.selection])
  }

  static func isVisible(_ tool: AnnotationToolType, userDefaults: UserDefaults = .standard) -> Bool {
    !hiddenTools(userDefaults: userDefaults).contains(tool)
  }

  static func setVisible(_ visible: Bool, for tool: AnnotationToolType, userDefaults: UserDefaults = .standard) {
    guard tool != .selection else { return }
    var hidden = hiddenTools(userDefaults: userDefaults)
    if visible { hidden.remove(tool) } else { hidden.insert(tool) }
    userDefaults.set(AnnotationToolType.drawableTools.filter(hidden.contains).map(\.rawValue),
                     forKey: PreferencesKeys.annotateHiddenTools)
  }

  /// `AnnotationToolType.inlineToolGroups` without hidden tools; empty groups are dropped.
  static func visibleInlineToolGroups(userDefaults: UserDefaults = .standard) -> [[AnnotationToolType]] {
    let hidden = hiddenTools(userDefaults: userDefaults)
    return AnnotationToolType.inlineToolGroups
      .map { $0.filter { !hidden.contains($0) } }
      // A family's button stands in for its visible tools, at the first one's place.
      .map { group in
        var seen: Set<Int> = []
        return group.filter { tool in
          guard let index = AnnotationToolType.inlineToolFamilies.firstIndex(where: { $0.contains(tool) })
          else { return true }
          return seen.insert(index).inserted
        }
      }
      .filter { !$0.isEmpty }
  }

  /// Visible tools that the family button of `tool` switches between.
  static func visibleInlineFamily(of tool: AnnotationToolType,
                                  userDefaults: UserDefaults = .standard) -> [AnnotationToolType] {
    let hidden = hiddenTools(userDefaults: userDefaults)
    return (AnnotationToolType.inlineFamily(of: tool) ?? []).filter { !hidden.contains($0) }
  }
}
