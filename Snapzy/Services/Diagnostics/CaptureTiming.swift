//
//  CaptureTiming.swift
//  Snapzy
//
//  Opt-in stage timing for the F1 capture flow. Enable with
//  `defaults write com.tianruian.openshot.preview debug.captureTiming -bool true`;
//  lines go to ~/Library/Logs/Snapzy/capture-timing.log with wall-clock timestamps
//  so an external probe can line them up with on-screen window times.
//

import Foundation

@MainActor
enum CaptureTiming {
  static let defaultsKey = "debug.captureTiming"
  private static var startedAt: CFAbsoluteTime?
  private static var lines: [String] = []

  static var isEnabled: Bool {
    UserDefaults.standard.bool(forKey: defaultsKey)
  }

  static func begin(_ name: String) {
    guard isEnabled else { return }
    startedAt = CFAbsoluteTimeGetCurrent()
    lines = []
    record(name)
  }

  static func mark(_ name: String) {
    guard startedAt != nil else { return }
    record(name)
  }

  /// Writes the collected marks and stops recording until the next `begin`.
  static func end(_ name: String) {
    guard startedAt != nil else { return }
    record(name)
    startedAt = nil
    let text = lines.joined(separator: "\n") + "\n\n"
    lines = []
    Task.detached(priority: .utility) {
      let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Snapzy", isDirectory: true)
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent("capture-timing.log")
      if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
      } else {
        try? Data(text.utf8).write(to: url)
      }
    }
  }

  private static func record(_ name: String) {
    guard let startedAt else { return }
    let now = CFAbsoluteTimeGetCurrent()
    let wall = Date(timeIntervalSinceReferenceDate: now).timeIntervalSince1970
    lines.append(String(format: "%.3f %7.1f ms  %@", wall, (now - startedAt) * 1000, name))
  }
}
