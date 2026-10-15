//
//  SnapzyConfigurationPaths.swift
//  Snapzy
//
//  Path helpers for user-managed configuration files.
//

import Darwin
import Foundation

nonisolated enum SnapzyConfigurationPaths {
  static var userHomeDirectory: URL {
    if let accountHomeDirectory {
      return accountHomeDirectory
    }

    return FileManager.default.homeDirectoryForCurrentUser
  }

  static var suggestedConfigURL: URL {
    suggestedConfigDirectoryURL
      .appendingPathComponent("config.toml")
  }

  static var suggestedConfigDirectoryURL: URL {
    suggestedConfigDirectoryURL(homeDirectory: userHomeDirectory)
  }

  static func expandedUserPath(_ path: String) -> String {
    guard path.hasPrefix("~/") else { return path }
    return userHomeDirectory
      .appendingPathComponent(String(path.dropFirst(2)))
      .path
  }

  /// Pinny is packaged under this bundle ID; it keeps its own config so it never
  /// shares (and overwrites) the upstream Snapzy builds' `~/.config/snapzy`.
  static let pinnyBundleIdentifier = "com.tianruian.openshot.preview"

  static func suggestedConfigURL(
    homeDirectory: URL,
    bundleIdentifier: String? = Bundle.main.bundleIdentifier
  ) -> URL {
    suggestedConfigDirectoryURL(homeDirectory: homeDirectory, bundleIdentifier: bundleIdentifier)
      .appendingPathComponent("config.toml")
  }

  static func suggestedConfigDirectoryURL(
    homeDirectory: URL,
    bundleIdentifier: String? = Bundle.main.bundleIdentifier
  ) -> URL {
    homeDirectory
      .appendingPathComponent(".config", isDirectory: true)
      .appendingPathComponent(bundleIdentifier == pinnyBundleIdentifier ? "pinny" : "snapzy", isDirectory: true)
  }

  /// First Pinny launch with the separate config: start from the shared Snapzy file once.
  /// Skipped as soon as the Pinny config directory exists, so a deleted file is not re-copied.
  static func migrateLegacyConfigIfNeeded(
    homeDirectory: URL = userHomeDirectory,
    bundleIdentifier: String? = Bundle.main.bundleIdentifier
  ) {
    guard bundleIdentifier == pinnyBundleIdentifier else { return }
    let fileManager = FileManager.default
    let pinnyDirectory = suggestedConfigDirectoryURL(homeDirectory: homeDirectory, bundleIdentifier: bundleIdentifier)
    let legacyURL = suggestedConfigURL(homeDirectory: homeDirectory, bundleIdentifier: nil)
    guard !fileManager.fileExists(atPath: pinnyDirectory.path), fileManager.fileExists(atPath: legacyURL.path) else {
      return
    }
    try? fileManager.createDirectory(at: pinnyDirectory, withIntermediateDirectories: true)
    try? fileManager.copyItem(
      at: legacyURL,
      to: suggestedConfigURL(homeDirectory: homeDirectory, bundleIdentifier: bundleIdentifier)
    )
  }

  static func collapsingHomePath(_ path: String) -> String {
    collapsingHomePath(path, homeDirectory: userHomeDirectory)
  }

  static func collapsingHomePath(_ path: String, homeDirectory: URL) -> String {
    let home = homeDirectory.path
    if path == home {
      return "~"
    }
    if path.hasPrefix(home + "/") {
      return "~/" + String(path.dropFirst(home.count + 1))
    }
    return path
  }

  static func expandedUserPath(_ path: String, homeDirectory: URL) -> String {
    guard path.hasPrefix("~/") else { return path }
    return homeDirectory
      .appendingPathComponent(String(path.dropFirst(2)))
      .path
  }

  private static var accountHomeDirectory: URL? {
    guard
      let passwd = getpwuid(getuid()),
      let home = passwd.pointee.pw_dir
    else {
      return nil
    }

    let path = String(cString: home)
    guard !path.isEmpty else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }
}
