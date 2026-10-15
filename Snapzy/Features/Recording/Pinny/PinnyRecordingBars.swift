//
//  PinnyRecordingBars.swift
//  Snapzy
//
//  Pinny: the three recording toolbars, all in the F1 toolbar's look. The prep bar replaces
//  the capture toolbar inside the overlay; the recording bar and the playback bar sit under
//  the selection in their own panels. Mockup: validation/recording-toolbar-mockup.html.
//

import Combine
import SwiftUI

enum PinnyRecordingPreferences {
  /// System sound is on and the microphone off until the user changes them on the prep bar.
  static var captureSystemAudio: Bool {
    UserDefaults.standard.object(forKey: PreferencesKeys.recordingCaptureAudio) as? Bool ?? true
  }

  static var captureMicrophone: Bool {
    UserDefaults.standard.object(forKey: PreferencesKeys.recordingCaptureMicrophone) as? Bool ?? false
  }
}

/// Icon button that stays highlighted while on and shows a different icon when off.
struct PinnyRecordingToggleButton: View {
  let onIcon: String
  let offIcon: String
  let tooltip: String
  let isOn: Bool
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      InlineAreaGlyph(name: isOn ? onIcon : offIcon, size: InlineAreaToolbarMetrics.iconSize)
        .foregroundColor(isOn ? InlineAreaChrome.toolbarIconSelectedForeground : .primary.opacity(isHovering ? 1 : 0.85))
        .frame(width: InlineAreaChrome.controlSize, height: InlineAreaChrome.controlSize)
        .background(
          RoundedRectangle(cornerRadius: InlineAreaChrome.controlCornerRadius, style: .continuous)
            .fill(isOn ? InlineAreaChrome.itemSelectedBackground
                  : (isHovering ? InlineAreaChrome.toolbarHoverBackground : .clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: InlineAreaChrome.controlCornerRadius, style: .continuous))
    }
    .buttonStyle(InlineAreaToolbarButtonStyle())
    .inlineAreaHelp(tooltip)
    .accessibilityLabel(tooltip)
    .accessibilityAddTraits(isOn ? .isSelected : [])
    .onHover { isHovering = $0 }
    .animation(InlineAreaToolbarMetrics.hoverAnimation, value: isHovering)
  }
}

/// Text label in the toolbars (size, time): 11 pt medium, tabular digits.
private struct PinnyRecordingLabel: View {
  let text: String
  var color: Color = InlineAreaChrome.secondaryText

  var body: some View {
    Text(text)
      .font(.system(size: 11, weight: .medium).monospacedDigit())
      .foregroundColor(color)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 6)
  }
}

// MARK: - Prep bar (inside the F1 overlay)

struct PinnyRecordingPrepBar: View {
  @ObservedObject var session: InlineAreaAnnotateSession
  let pixelSize: CGSize

  @AppStorage(PreferencesKeys.recordingCaptureAudio) private var captureSystemAudio = true
  @AppStorage(PreferencesKeys.recordingCaptureMicrophone) private var captureMicrophone = false

  static let sizeLabelWidth: CGFloat = 84
  static let startButtonWidth: CGFloat = 96

  /// Fixed so the overlay can place the bar before it is laid out.
  static var width: CGFloat {
    let metrics = InlineAreaToolbarMetrics.self
    return metrics.horizontalPadding * 2 + sizeLabelWidth + metrics.groupWidth(2) + startButtonWidth
      + metrics.groupWidth(1) + metrics.dividerWidth * 3
  }

  var body: some View {
    HStack(spacing: 0) {
      PinnyRecordingLabel(text: "\(Int(pixelSize.width)) × \(Int(pixelSize.height))")
        .frame(width: Self.sizeLabelWidth)
      InlineAreaDivider()
      HStack(spacing: InlineAreaToolbarMetrics.itemSpacing) {
        PinnyRecordingToggleButton(
          onIcon: "rec-audio-on", offIcon: "rec-audio-off",
          tooltip: captureSystemAudio ? L10n.PinnyRecording.systemAudioOn : L10n.PinnyRecording.systemAudioOff,
          isOn: captureSystemAudio
        ) { captureSystemAudio.toggle() }
        PinnyRecordingToggleButton(
          onIcon: "rec-mic-on", offIcon: "rec-mic-off",
          tooltip: captureMicrophone ? L10n.PinnyRecording.microphoneOn : L10n.PinnyRecording.microphoneOff,
          isOn: captureMicrophone
        ) { captureMicrophone.toggle() }
      }
      InlineAreaDivider()
      PinnyRecordingStartButton { session.startRecording() }
        .frame(width: Self.startButtonWidth)
      InlineAreaDivider()
      InlineAreaIconButton(icon: "cancel", tooltip: L10n.Common.withShortcut(L10n.Common.close, "Esc")) {
        session.endRecordingPrep()
      }
    }
    .padding(.horizontal, InlineAreaToolbarMetrics.horizontalPadding)
    .frame(width: Self.width, height: InlineAreaLayout.toolbarHeight)
    .environment(\.inlineAreaHoverTipAbove, true)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("inline.recordingPrepBar")
  }
}

private struct PinnyRecordingStartButton: View {
  let action: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Circle().fill(Color.white).frame(width: 9, height: 9)
        Text(L10n.PinnyRecording.start)
          .font(.system(size: 12, weight: .semibold))
          .lineLimit(1)
          .fixedSize()
      }
      .foregroundColor(.white)
      .padding(.horizontal, 10)
      .frame(height: 28)
      .background(
        RoundedRectangle(cornerRadius: InlineAreaChrome.controlCornerRadius, style: .continuous)
          .fill(Color(nsColor: .systemRed).opacity(isHovering ? 0.88 : 1))
      )
      .contentShape(RoundedRectangle(cornerRadius: InlineAreaChrome.controlCornerRadius, style: .continuous))
    }
    .buttonStyle(InlineAreaToolbarButtonStyle())
    .inlineAreaHelp(L10n.Common.withShortcut(L10n.PinnyRecording.start, L10n.AnnotateUI.pinnyReturnKey))
    .accessibilityLabel(L10n.PinnyRecording.start)
    .onHover { isHovering = $0 }
  }
}

// MARK: - Recording bar

struct PinnyRecordingLiveBar: View {
  @ObservedObject var recorder: ScreenRecordingManager
  let togglePause: () -> Void
  let stop: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      HStack(spacing: 6) {
        Circle()
          .fill(recorder.isPaused ? Color.secondary : Color(nsColor: .systemRed))
          .frame(width: 8, height: 8)
        Text(recorder.formattedDuration)
          .font(.system(size: 12, weight: .semibold).monospacedDigit())
          .foregroundColor(recorder.isPaused ? InlineAreaChrome.secondaryText : InlineAreaChrome.primaryText)
          .fixedSize()
      }
      .padding(.horizontal, 6)
      InlineAreaDivider()
      HStack(spacing: InlineAreaToolbarMetrics.itemSpacing) {
        InlineAreaIconButton(
          icon: recorder.isPaused ? "rec-play" : "rec-pause",
          tooltip: recorder.isPaused ? L10n.PinnyRecording.resume : L10n.PinnyRecording.pause,
          action: togglePause
        )
        PinnyRecordingStopButton(action: stop)
      }
    }
    .padding(.horizontal, InlineAreaToolbarMetrics.horizontalPadding)
    .padding(.vertical, InlineAreaToolbarMetrics.verticalPadding)
    .inlineAreaPanelChrome()
    .padding(12) // room for the panel shadow
    .fixedSize()
  }
}

private struct PinnyRecordingStopButton: View {
  let action: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      InlineAreaGlyph(name: "rec-stop", size: InlineAreaToolbarMetrics.iconSize)
        .foregroundColor(Color(nsColor: .systemRed))
        .frame(width: InlineAreaChrome.controlSize, height: InlineAreaChrome.controlSize)
        .background(
          RoundedRectangle(cornerRadius: InlineAreaChrome.controlCornerRadius, style: .continuous)
            .fill(isHovering ? InlineAreaChrome.toolbarHoverBackground : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: InlineAreaChrome.controlCornerRadius, style: .continuous))
    }
    .buttonStyle(InlineAreaToolbarButtonStyle())
    .help(L10n.Common.withShortcut(L10n.PinnyRecording.stop, "F1"))
    .accessibilityLabel(L10n.PinnyRecording.stop)
    .onHover { isHovering = $0 }
  }
}

// MARK: - Playback bar

enum PinnyRecordingOutputFormat: String, CaseIterable, Identifiable {
  case mp4, gif
  var id: String { rawValue }
  var title: String { rawValue.uppercased() }
}

struct PinnyRecordingPlaybackActions {
  let togglePlay: () -> Void
  let seek: (Double) -> Void
  let rerecord: () -> Void
  let copy: () -> Void
  let save: () -> Void
  let close: () -> Void
}

struct PinnyRecordingPlaybackBar: View {
  @ObservedObject var model: PinnyRecordingPlaybackModel
  let actions: PinnyRecordingPlaybackActions

  var body: some View {
    HStack(spacing: 0) {
      InlineAreaIconButton(
        icon: model.isPlaying ? "rec-pause" : "rec-play",
        tooltip: L10n.Common.withShortcut(model.isPlaying ? L10n.PinnyRecording.pause : L10n.PinnyRecording.play,
                                          L10n.PinnyRecording.spaceKey),
        action: actions.togglePlay
      )
      PinnyRecordingLabel(text: Self.time(model.currentTime))
      PinnyRecordingProgress(progress: model.duration > 0 ? model.currentTime / model.duration : 0,
                             seek: actions.seek)
        .frame(width: 150, height: InlineAreaChrome.controlSize)
      PinnyRecordingLabel(text: Self.time(model.duration))
      InlineAreaDivider()
      PinnyRecordingFormatPicker(selection: $model.format)
      InlineAreaDivider()
      HStack(spacing: InlineAreaToolbarMetrics.itemSpacing) {
        InlineAreaIconButton(icon: "rec-redo", tooltip: L10n.PinnyRecording.rerecord,
                             isEnabled: !model.isBusy, action: actions.rerecord)
        InlineAreaIconButton(
          icon: "copy",
          tooltip: L10n.Common.withShortcut(L10n.AnnotateUI.copyToClipboard, "\(L10n.AnnotateUI.pinnyReturnKey) / ⌘C"),
          isEnabled: !model.isBusy, action: actions.copy)
        InlineAreaIconButton(icon: "save", tooltip: L10n.Common.withShortcut(L10n.Common.save, "⌘S"),
                             isEnabled: !model.isBusy, action: actions.save)
        InlineAreaIconButton(icon: "cancel", tooltip: L10n.Common.withShortcut(L10n.Common.close, "Esc"),
                             action: actions.close)
      }
      .overlay {
        if model.isBusy { ProgressView().controlSize(.small).allowsHitTesting(false) }
      }
    }
    .padding(.horizontal, InlineAreaToolbarMetrics.horizontalPadding)
    .padding(.vertical, InlineAreaToolbarMetrics.verticalPadding)
    .inlineAreaPanelChrome()
    .padding(12) // room for the panel shadow
    .fixedSize()
  }

  static func time(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d", total / 60, total % 60)
  }
}

private struct PinnyRecordingProgress: View {
  let progress: Double
  let seek: (Double) -> Void

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let x = width * min(max(progress, 0), 1)
      ZStack(alignment: .leading) {
        Capsule().fill(Color.primary.opacity(0.14)).frame(height: 4)
        Capsule().fill(Color.accentColor).frame(width: x, height: 4)
        Circle()
          .fill(Color.white)
          .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
          .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
          .frame(width: 12, height: 12)
          .offset(x: x - 6)
      }
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 0).onChanged { value in
        guard width > 0 else { return }
        seek(min(max(value.location.x / width, 0), 1))
      })
    }
    .padding(.horizontal, 6)
    .accessibilityLabel(L10n.PinnyRecording.progress)
  }
}

private struct PinnyRecordingFormatPicker: View {
  @Binding var selection: PinnyRecordingOutputFormat

  var body: some View {
    HStack(spacing: 0) {
      ForEach(PinnyRecordingOutputFormat.allCases) { format in
        Button { selection = format } label: {
          Text(format.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(selection == format ? InlineAreaChrome.primaryText : InlineAreaChrome.secondaryText)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
              RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(selection == format ? Color(nsColor: .controlBackgroundColor) : .clear)
                .shadow(color: .black.opacity(selection == format ? 0.18 : 0), radius: 1, y: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == format ? .isSelected : [])
      }
    }
    .padding(2)
    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(InlineAreaChrome.itemBackground))
    .help(L10n.PinnyRecording.formatHint)
  }
}

@MainActor
final class PinnyRecordingPlaybackModel: ObservableObject {
  @Published var isPlaying = true
  @Published var currentTime: Double = 0
  @Published var duration: Double = 0
  @Published var format: PinnyRecordingOutputFormat = .mp4
  /// GIF conversion or saving in progress.
  @Published var isBusy = false
}
