//
//  PreferencesAnnotateSettingsView.swift
//  Snapzy
//
//  Annotate preferences tab for editor behavior settings.
//

import SwiftUI

struct AnnotateSettingsView: View {
  @AppStorage(PreferencesKeys.annotateClipboardImageOpenBehavior)
  private var annotateClipboardImageOpenBehavior = AnnotateClipboardImageBehavior.ask.rawValue
  @AppStorage(PreferencesKeys.annotateDefaultTool)
  private var annotateDefaultTool = AnnotationToolType.selection.rawValue
  @AppStorage(PreferencesKeys.annotateRememberLastTool)
  private var annotateRememberLastTool = false
  @AppStorage(PreferencesKeys.annotateCloseAfterDrag) private var annotateCloseAfterDrag = true
  @AppStorage(PreferencesKeys.annotateBringForwardAfterDrag)
  private var annotateBringForwardAfterDrag = false
  @AppStorage(PreferencesKeys.annotateQuickPropertiesSyncEnabled)
  private var annotateQuickPropertiesSyncEnabled = true
  @AppStorage(PreferencesKeys.annotateCombineSaveAsEdit)
  private var annotateCombineSaveAsEdit = true
  @AppStorage(PreferencesKeys.annotateCropSnapToEdgesEnabled)
  private var annotateCropSnapToEdgesEnabled = true
  @AppStorage(PreferencesKeys.annotateHighlighterTextSnappingEnabled)
  private var annotateHighlighterTextSnappingEnabled = true
  @State private var hiddenTools = AnnotateToolVisibility.hiddenTools()

  /// Pinny edits inline after F1; options that only affect the standalone editor (default and
  /// remembered tool, stitching, crop snapping, clipboard opening, drag-out) stay hidden.
  private static let showsLegacyOptions = false

  var body: some View {
    Form {
      Section {
        ForEach(AnnotationToolType.drawableTools) { tool in
          HStack(spacing: 12) {
            Image("CaptureTool-" + tool.rawValue)
              .renderingMode(.template).resizable().scaledToFit()
              .frame(width: 20, height: 20)
              .foregroundColor(.secondary)
              .frame(width: 28)
            Text(tool.displayName)
            Spacer()
            Toggle("", isOn: toolVisibilityBinding(for: tool))
              .labelsHidden()
          }
        }
      } header: {
        Text(L10n.PreferencesAnnotate.toolbarToolsSection)
      } footer: {
        Text(L10n.PreferencesAnnotate.toolbarToolsDescription)
          .foregroundColor(.secondary)
      }

      Section(L10n.PreferencesAnnotate.behaviorSection) {
        SettingRow(
          icon: "slider.horizontal.3",
          title: L10n.PreferencesAnnotate.quickPropertiesSyncTitle,
          description: L10n.PreferencesAnnotate.quickPropertiesSyncDescription
        ) {
          Toggle("", isOn: $annotateQuickPropertiesSyncEnabled)
            .labelsHidden()
        }

        SettingRow(
          icon: "highlighter",
          title: L10n.AnnotateUI.highlighterTextSnapping,
          description: L10n.AnnotateUI.highlighterTextSnappingDescription
        ) {
          Toggle("", isOn: $annotateHighlighterTextSnappingEnabled)
            .labelsHidden()
        }

        if Self.showsLegacyOptions {
        SettingRow(
          icon: "cursorarrow",
          title: L10n.PreferencesAnnotate.defaultToolTitle,
          description: L10n.PreferencesAnnotate.defaultToolDescription
        ) {
          Picker("", selection: $annotateDefaultTool) {
            ForEach(AnnotationToolType.inlineAnnotateTools) { tool in
              Label(tool.displayName, systemImage: tool.icon).tag(tool.rawValue)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .fixedSize()
          .frame(width: 180, alignment: .trailing)
        }
        .disabled(annotateRememberLastTool)
        .opacity(annotateRememberLastTool ? 0.5 : 1)

        SettingRow(
          icon: "clock.arrow.circlepath",
          title: L10n.PreferencesAnnotate.rememberLastToolTitle,
          description: L10n.PreferencesAnnotate.rememberLastToolDescription
        ) {
          Toggle("", isOn: $annotateRememberLastTool)
            .labelsHidden()
        }

        SettingRow(
          icon: "rectangle.stack",
          title: L10n.PreferencesAnnotate.combineSaveAsEditTitle,
          description: L10n.PreferencesAnnotate.combineSaveAsEditDescription
        ) {
          Toggle("", isOn: $annotateCombineSaveAsEdit)
            .labelsHidden()
        }

        SettingRow(
          icon: CropToolbarSymbols.snapToEdges,
          title: L10n.AnnotateUI.cropSnapToEdges,
          description: L10n.AnnotateUI.cropSnapToEdgesDescription
        ) {
          Toggle("", isOn: $annotateCropSnapToEdgesEnabled)
            .labelsHidden()
        }

        SettingRow(
          icon: "doc.on.clipboard",
          title: L10n.PreferencesAnnotate.clipboardTitle,
          description: L10n.PreferencesAnnotate.clipboardDescription
        ) {
          Picker("", selection: $annotateClipboardImageOpenBehavior) {
            ForEach(AnnotateClipboardImageBehavior.allCases) { behavior in
              Text(behavior.displayName).tag(behavior.rawValue)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .fixedSize()
          .frame(width: 180, alignment: .trailing)
        }

        SettingRow(
          icon: "arrow.up.forward.app",
          title: L10n.PreferencesAnnotate.closeAfterDragTitle,
          description: L10n.PreferencesAnnotate.closeAfterDragDescription
        ) {
          Toggle("", isOn: $annotateCloseAfterDrag)
            .labelsHidden()
        }

        SettingRow(
          icon: "macwindow",
          title: L10n.PreferencesAnnotate.bringForwardAfterDragTitle,
          description: L10n.PreferencesAnnotate.bringForwardAfterDragDescription
        ) {
          Toggle("", isOn: $annotateBringForwardAfterDrag)
            .labelsHidden()
        }
        .disabled(annotateCloseAfterDrag)
        }
      }
    }
    .formStyle(.grouped)
  }

  private func toolVisibilityBinding(for tool: AnnotationToolType) -> Binding<Bool> {
    Binding(
      get: { !hiddenTools.contains(tool) },
      set: { visible in
        AnnotateToolVisibility.setVisible(visible, for: tool)
        hiddenTools = AnnotateToolVisibility.hiddenTools()
      }
    )
  }
}

#Preview {
  AnnotateSettingsView()
    .frame(width: 600, height: 550)
}
