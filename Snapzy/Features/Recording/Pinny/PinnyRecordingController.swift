//
//  PinnyRecordingController.swift
//  Snapzy
//
//  Pinny: records an F1 selection. While recording, a red frame marks the area and a small bar
//  under it has the timer, pause and stop (F1 and the menu bar icon also stop). When it stops,
//  the video plays in place with a bar to copy or save it as MP4 or GIF, record again or close.
//  The recording stays an MP4 in the temporary captures folder; GIF is made only on copy/save.
//

import AppKit
import AVFoundation
import Combine
import SwiftUI

@MainActor
final class PinnyRecordingController: ObservableObject {
  static let shared = PinnyRecordingController()

  private enum Phase { case idle, starting, recording, stopping, playback }

  private let recorder = ScreenRecordingManager.shared
  private var phase: Phase = .idle
  private var selection: CGRect = .zero
  private var frameWindow: PinnyRecordingFrameWindow?
  private var barWindow: PinnyRecordingBarWindow?
  private var playback: PinnyRecordingPlayback?
  private var onRecordingEnded: (() -> Void)?
  private var rerecordHandler: ((CGRect) -> Void)?
  private var saveDirectoryProvider: (() -> URL?)?

  private init() {}

  /// True while recording or paused: F1 and the menu bar icon stop it.
  var isRecording: Bool { phase == .starting || phase == .recording || phase == .stopping }

  /// - Parameters:
  ///   - rect: the selection in AppKit global screen coordinates.
  ///   - onRecordingEnded: runs once recording stops or fails to start (restores hidden windows).
  ///   - rerecord: opens F1 in the prep bar on the given area.
  func start(
    rect: CGRect,
    saveDirectoryProvider: @escaping () -> URL?,
    rerecord: @escaping (CGRect) -> Void,
    onRecordingEnded: @escaping () -> Void
  ) {
    guard phase == .idle else {
      DiagnosticLogger.shared.log(.debug, .recording, "Pinny recording ignored: busy")
      onRecordingEnded()
      return
    }
    phase = .starting
    selection = rect.integral
    self.onRecordingEnded = onRecordingEnded
    self.rerecordHandler = rerecord
    self.saveDirectoryProvider = saveDirectoryProvider
    begin(captureMicrophone: PinnyRecordingPreferences.captureMicrophone)
  }

  /// F1 while recording: stop instead of starting a new capture.
  func stopIfRecording() -> Bool {
    guard isRecording else { return false }
    stop()
    return true
  }

  // MARK: - Recording

  private func begin(captureMicrophone: Bool) {
    let rect = selection
    let defaults = UserDefaults.standard
    var fps = defaults.integer(forKey: PreferencesKeys.recordingFPS)
    if fps == 0 { fps = 30 }
    let quality = VideoQuality(rawValue: defaults.string(forKey: PreferencesKeys.recordingQuality) ?? "") ?? .high
    let showCursor = defaults.object(forKey: PreferencesKeys.recordingShowCursor) as? Bool ?? true
    let excludeOwnApplication = !defaults.bool(forKey: PreferencesKeys.recordingIncludeOwnApp)
    let captureSystemAudio = PinnyRecordingPreferences.captureSystemAudio
    let microphoneDeviceID = defaults.string(forKey: PreferencesKeys.recordingMicrophoneDeviceID)

    DiagnosticLogger.shared.log(.info, .recording, "Pinny recording start", context: [
      "rect": "\(Int(rect.width))x\(Int(rect.height))",
      "fps": "\(fps)",
      "systemAudio": "\(captureSystemAudio)",
      "microphone": "\(captureMicrophone)",
    ])

    showRecordingChrome()
    Task {
      do {
        let temp = TempCaptureManager.shared
        let plan = try temp.makeRecordingSavePlan(exportDirectory: temp.tempCaptureDirectory)
        try await recorder.prepareRecording(
          rect: rect,
          format: .mp4,
          quality: quality,
          fps: fps,
          maxResolution: .native,
          captureSystemAudio: captureSystemAudio,
          captureMicrophone: captureMicrophone,
          microphoneDeviceID: microphoneDeviceID,
          showCursor: showCursor,
          saveDirectory: temp.tempCaptureDirectory,
          processingDirectory: plan.processingDirectory,
          excludeDesktopIcons: DesktopIconManager.shared.isIconHidingEnabled,
          excludeDesktopWidgets: DesktopIconManager.shared.isWidgetHidingEnabled,
          excludeOwnApplication: excludeOwnApplication,
          excludedWindowIDs: [frameWindow, barWindow].compactMap { $0.map { CGWindowID($0.windowNumber) } },
          context: .fromFrontmostApp()
        )
        try await recorder.startRecording()
        phase = .recording
      } catch let error as RecordingError {
        DiagnosticLogger.shared.logError(.recording, error, "Pinny recording setup failed")
        closeRecordingChrome()
        if case .alreadyActive = error {
          // Another recording owns the recorder; leave it alone.
          endRecordingPhase()
          phase = .idle
          return
        }
        await recorder.cancelRecording()
        if case .microphonePermissionDenied = error, askToContinueWithoutMicrophone() {
          begin(captureMicrophone: false)
          return
        }
        showFailure(error.localizedDescription)
        endRecordingPhase()
        phase = .idle
      } catch {
        DiagnosticLogger.shared.logError(.recording, error, "Pinny recording setup failed")
        await recorder.cancelRecording()
        closeRecordingChrome()
        showFailure(error.localizedDescription)
        endRecordingPhase()
        phase = .idle
      }
    }
  }

  func togglePause() {
    guard phase == .recording else { return }
    recorder.togglePause()
  }

  func stop() {
    guard phase == .recording || phase == .starting else { return }
    guard phase == .recording else {
      // Still preparing: stop as soon as it has started.
      Task { @MainActor in
        while phase == .starting { try? await Task.sleep(nanoseconds: 50_000_000) }
        stop()
      }
      return
    }
    phase = .stopping
    Task {
      let url = await recorder.stopRecording()
      closeRecordingChrome()
      endRecordingPhase()
      guard let url else {
        phase = .idle
        showFailure(L10n.PinnyRecording.noOutput)
        return
      }
      SoundManager.play("Glass")
      showPlayback(url: url)
    }
  }

  private func showRecordingChrome() {
    let frame = PinnyRecordingFrameWindow(selection: selection)
    frame.orderFrontRegardless()
    frameWindow = frame
    let bar = PinnyRecordingBarWindow(
      selection: selection,
      content: PinnyRecordingLiveBar(
        recorder: recorder,
        togglePause: { [weak self] in self?.togglePause() },
        stop: { [weak self] in self?.stop() }
      )
    )
    bar.orderFrontRegardless()
    barWindow = bar
  }

  private func closeRecordingChrome() {
    frameWindow?.close()
    frameWindow = nil
    barWindow?.close()
    barWindow = nil
  }

  private func endRecordingPhase() {
    let ended = onRecordingEnded
    onRecordingEnded = nil
    ended?()
  }

  private func askToContinueWithoutMicrophone() -> Bool {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = L10n.Microphone.accessRequiredTitle
    alert.informativeText = L10n.Microphone.recordingMessage
    alert.addButton(withTitle: L10n.Common.openSystemSettings)
    alert.addButton(withTitle: L10n.Microphone.continueWithoutMic)
    alert.addButton(withTitle: L10n.Common.cancel)
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
        NSWorkspace.shared.open(url)
      }
      return false
    case .alertSecondButtonReturn:
      return true
    default:
      return false
    }
  }

  private func showFailure(_ message: String) {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = L10n.Recording.failedTitle
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: L10n.Common.ok)
    alert.runModal()
  }

  // MARK: - Playback

  private func showPlayback(url: URL) {
    phase = .playback
    let actions = PinnyRecordingPlayback.Actions(
      rerecord: { [weak self] in self?.rerecord() },
      close: { [weak self] in self?.closePlayback(discardUnexported: true) },
      save: { [weak self] in self?.saveDirectoryProvider?() }
    )
    playback = PinnyRecordingPlayback(videoURL: url, selection: selection, actions: actions)
    playback?.show()
  }

  private func closePlayback(discardUnexported: Bool) {
    playback?.close(discardUnexported: discardUnexported)
    playback = nil
    phase = .idle
  }

  private func rerecord() {
    let rect = selection
    closePlayback(discardUnexported: true)
    rerecordHandler?(rect)
  }
}

// MARK: - Recording frame and bar windows

/// Red frame just outside the selection. Never takes the mouse, never part of a capture.
private final class PinnyRecordingFrameWindow: NSPanel {
  static let lineWidth: CGFloat = 2

  init(selection: CGRect) {
    let inset = -Self.lineWidth
    super.init(contentRect: selection.insetBy(dx: inset, dy: inset),
               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    ignoresMouseEvents = true
    level = .statusBar
    sharingType = LongScreenshotChrome.sharingType
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    let view = NSView()
    view.wantsLayer = true
    view.layer?.borderColor = NSColor.systemRed.cgColor
    view.layer?.borderWidth = Self.lineWidth
    contentView = view
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// Non-activating, so the recorded app keeps the keyboard; accepts the first click.
final class PinnyRecordingBarWindow: NSPanel {
  private let selection: CGRect

  init<Content: View>(selection: CGRect, content: Content) {
    self.selection = selection
    super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
               backing: .buffered, defer: false)
    isFloatingPanel = true
    level = .popUpMenu
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    sharingType = LongScreenshotChrome.sharingType
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    contentView = PinnyRecordingFirstClickHostingView(rootView: content)
    layoutToSelection()
  }

  /// Under the selection (above when there is no room), like the F1 toolbar.
  func layoutToSelection() {
    guard let contentView else { return }
    contentView.layoutSubtreeIfNeeded()
    let size = contentView.fittingSize
    // The 12 pt shadow margin inside the content sits in the selection gap.
    let padded = selection.insetBy(dx: 0, dy: -PinnyRecordingFrameWindow.lineWidth + 12)
    let screen = NSScreen.screens.first { $0.frame.intersects(selection) } ?? NSScreen.main
    guard let screen else { return }
    // Like the F1 toolbar: only the menu bar is off limits, the Dock is not, so the bar stays
    // under a selection that ends just above the Dock.
    var bounds = screen.frame
    bounds.size.height = screen.visibleFrame.maxY - bounds.minY
    setFrame(LongScreenshotToolbarGeometry.frame(size: size, selection: padded, visibleFrame: bounds),
             display: true)
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

final class PinnyRecordingFirstClickHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - In-place playback

/// The recording looping at the selection's position and size, with its bar underneath.
/// Pinny comes to the front while it shows, so Space, Return/⌘C, ⌘S and Esc work.
@MainActor
private final class PinnyRecordingPlayback {
  struct Actions {
    let rerecord: () -> Void
    let close: () -> Void
    let save: () -> URL?
  }

  private let videoURL: URL
  private let selection: CGRect
  private let actions: Actions
  private let model = PinnyRecordingPlaybackModel()
  private let player: AVQueuePlayer
  private let looper: AVPlayerLooper
  private var videoWindow: PinnyRecordingVideoWindow?
  private var barWindow: PinnyRecordingBarWindow?
  private var timeObserver: Any?
  private var gifURL: URL?
  /// Copied or saved: closing no longer asks, and a copied file is kept for pasting.
  private var wasExported = false
  private var wasCopied = false
  private var previousApp: NSRunningApplication?
  private var observations: Set<AnyCancellable> = []

  init(videoURL: URL, selection: CGRect, actions: Actions) {
    self.videoURL = videoURL
    self.selection = selection
    self.actions = actions
    let item = AVPlayerItem(url: videoURL)
    player = AVQueuePlayer()
    looper = AVPlayerLooper(player: player, templateItem: item)
  }

  func show() {
    previousApp = NSWorkspace.shared.frontmostApplication
    let handleKey: (NSEvent) -> Bool = { [weak self] event in self?.handleKey(event) ?? false }
    let video = PinnyRecordingVideoWindow(selection: selection, player: player, handleKey: handleKey)
    videoWindow = video
    let bar = PinnyRecordingBarWindow(
      selection: selection,
      content: PinnyRecordingPlaybackBar(model: model, actions: .init(
        togglePlay: { [weak self] in self?.togglePlay() },
        seek: { [weak self] in self?.seek(to: $0) },
        rerecord: actions.rerecord,
        copy: { [weak self] in self?.copy() },
        save: { [weak self] in self?.save() },
        close: { [weak self] in self?.requestClose() }
      ))
    )
    barWindow = bar
    NSApp.activate(ignoringOtherApps: true)
    video.makeKeyAndOrderFront(nil)
    bar.orderFrontRegardless()

    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(value: 1, timescale: 20), queue: .main
    ) { [weak self] time in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.model.currentTime = time.seconds.isFinite ? time.seconds : 0
      }
    }
    let asset = AVURLAsset(url: videoURL)
    Task { [weak self] in
      guard let duration = try? await asset.load(.duration) else { return }
      self?.model.duration = duration.seconds.isFinite ? duration.seconds : 0
    }
    // Switching format resizes the bar; keep it centered under the selection.
    model.$format.dropFirst().sink { [weak bar] _ in
      DispatchQueue.main.async { bar?.layoutToSelection() }
    }.store(in: &observations)
    player.play()
  }

  func close(discardUnexported: Bool) {
    if let timeObserver { player.removeTimeObserver(timeObserver) }
    timeObserver = nil
    player.pause()
    player.removeAllItems()
    videoWindow?.close()
    barWindow?.close()
    videoWindow = nil
    barWindow = nil
    observations.removeAll()
    if discardUnexported, !wasCopied {
      // The copied file stays so it can still be pasted; temp captures are cleaned up later.
      for url in [videoURL, gifURL].compactMap({ $0 }) {
        try? FileManager.default.removeItem(at: url)
        try? RecordingMetadataStore.delete(for: url)
      }
    }
    previousApp?.activate(options: [])
    previousApp = nil
  }

  private func handleKey(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown else { return false }
    let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
    switch (event.keyCode, modifiers) {
    case (49, []): togglePlay()
    case (36, []), (76, []), (8, .command): copy()
    case (1, .command): save()
    case (53, []): requestClose()
    default: return false
    }
    return true
  }

  private func togglePlay() {
    if model.isPlaying { player.pause() } else { player.play() }
    model.isPlaying.toggle()
  }

  private func seek(to fraction: Double) {
    guard model.duration > 0 else { return }
    let time = CMTime(seconds: fraction * model.duration, preferredTimescale: 600)
    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    model.currentTime = fraction * model.duration
  }

  /// The file for the chosen format, converting to GIF the first time it is needed.
  private func outputURL() async -> URL? {
    switch model.format {
    case .mp4:
      return videoURL
    case .gif:
      if let gifURL, FileManager.default.fileExists(atPath: gifURL.path) { return gifURL }
      model.isBusy = true
      defer { model.isBusy = false }
      do {
        let url = try await GIFConverter.convert(videoURL: videoURL, onProgress: { _ in })
        gifURL = url
        return url
      } catch {
        DiagnosticLogger.shared.logError(.recording, error, "Pinny GIF conversion failed")
        AppToastManager.shared.show(message: L10n.PinnyRecording.gifFailed, style: .error)
        return nil
      }
    }
  }

  private func copy() {
    guard !model.isBusy else { return }
    Task {
      guard let url = await outputURL() else { return }
      ClipboardHelper.copyMediaFile(from: url)
      SoundManager.play("Pop")
      wasCopied = true
      wasExported = true
      AppToastManager.shared.show(message: L10n.PinnyRecording.copied, style: .success)
    }
  }

  private func save() {
    guard !model.isBusy, let directory = actions.save() else { return }
    Task {
      guard let url = await outputURL() else { return }
      model.isBusy = true
      defer { model.isBusy = false }
      let access = SandboxFileAccessManager.shared.beginAccessingURL(directory)
      defer { access.stop() }
      do {
        let destination = Self.availableURL(in: directory, name: url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: destination)
        SoundManager.playScreenshotCapture()
        wasExported = true
        AppToastManager.shared.show(message: L10n.PinnyRecording.saved(destination.lastPathComponent),
                                    style: .success)
      } catch {
        DiagnosticLogger.shared.logError(.recording, error, "Pinny recording save failed")
        AppToastManager.shared.show(message: error.localizedDescription, style: .error)
      }
    }
  }

  private static func availableURL(in directory: URL, name: String) -> URL {
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var candidate = directory.appendingPathComponent(name)
    var index = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = directory.appendingPathComponent("\(base) \(index)").appendingPathExtension(ext)
      index += 1
    }
    return candidate
  }

  private func requestClose() {
    guard !model.isBusy else { return }
    if !wasExported {
      let alert = NSAlert()
      alert.messageText = L10n.PinnyRecording.discardTitle
      alert.informativeText = L10n.PinnyRecording.discardMessage
      alert.addButton(withTitle: L10n.PinnyRecording.discard)
      alert.addButton(withTitle: L10n.Common.cancel)
      alert.buttons.first?.hasDestructiveAction = true
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }
    actions.close()
  }
}

private final class PinnyRecordingVideoWindow: NSPanel {
  private let handleKey: (NSEvent) -> Bool

  init(selection: CGRect, player: AVPlayer, handleKey: @escaping (NSEvent) -> Bool) {
    self.handleKey = handleKey
    super.init(contentRect: selection, styleMask: [.borderless], backing: .buffered, defer: false)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    level = .floating
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    let view = PinnyRecordingPlayerView(player: player)
    contentView = view
  }

  override func keyDown(with event: NSEvent) {
    if handleKey(event) { return }
    super.keyDown(with: event)
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

private final class PinnyRecordingPlayerView: NSView {
  private let playerLayer: AVPlayerLayer

  init(player: AVPlayer) {
    playerLayer = AVPlayerLayer(player: player)
    super.init(frame: .zero)
    wantsLayer = true
    playerLayer.videoGravity = .resize
    layer?.addSublayer(playerLayer)
    layer?.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor
    layer?.borderWidth = 1
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    playerLayer.frame = bounds
    CATransaction.commit()
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
