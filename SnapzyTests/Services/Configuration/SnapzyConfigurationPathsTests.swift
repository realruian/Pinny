//
//  SnapzyConfigurationPathsTests.swift
//  SnapzyTests
//
//  Tests for user-managed TOML configuration paths.
//

import Darwin
import XCTest
@testable import Snapzy

@MainActor
final class SnapzyConfigurationPathsTests: XCTestCase {
  func testSuggestedConfigURLUsesProvidedHomeDirectory() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    let url = SnapzyConfigurationPaths.suggestedConfigURL(homeDirectory: home)

    XCTAssertEqual(url.path, "/Users/example/.config/snapzy/config.toml")
  }

  func testSuggestedConfigDirectoryURLUsesProvidedHomeDirectory() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    let url = SnapzyConfigurationPaths.suggestedConfigDirectoryURL(homeDirectory: home)

    XCTAssertEqual(url.path, "/Users/example/.config/snapzy")
  }

  func testPinnyBundleUsesSeparateConfigDirectory() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    let url = SnapzyConfigurationPaths.suggestedConfigURL(
      homeDirectory: home,
      bundleIdentifier: SnapzyConfigurationPaths.pinnyBundleIdentifier
    )

    XCTAssertEqual(url.path, "/Users/example/.config/pinny/config.toml")
  }

  func testMigrateLegacyConfigCopiesSnapzyFileOnceForPinny() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let legacyURL = SnapzyConfigurationPaths.suggestedConfigURL(homeDirectory: home, bundleIdentifier: nil)
    try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "legacy = true\n".write(to: legacyURL, atomically: true, encoding: .utf8)
    let pinnyURL = SnapzyConfigurationPaths.suggestedConfigURL(
      homeDirectory: home,
      bundleIdentifier: SnapzyConfigurationPaths.pinnyBundleIdentifier
    )

    SnapzyConfigurationPaths.migrateLegacyConfigIfNeeded(
      homeDirectory: home,
      bundleIdentifier: SnapzyConfigurationPaths.pinnyBundleIdentifier
    )
    XCTAssertEqual(try String(contentsOf: pinnyURL, encoding: .utf8), "legacy = true\n")

    try FileManager.default.removeItem(at: pinnyURL)
    SnapzyConfigurationPaths.migrateLegacyConfigIfNeeded(
      homeDirectory: home,
      bundleIdentifier: SnapzyConfigurationPaths.pinnyBundleIdentifier
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: pinnyURL.path))
  }

  func testCollapsingHomePathConvertsAbsolutePathToTilde() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    XCTAssertEqual(
      SnapzyConfigurationPaths.collapsingHomePath("/Users/example/Desktop", homeDirectory: home),
      "~/Desktop"
    )
    XCTAssertEqual(
      SnapzyConfigurationPaths.collapsingHomePath("/Users/example", homeDirectory: home),
      "~"
    )
    XCTAssertEqual(
      SnapzyConfigurationPaths.collapsingHomePath("/tmp/snapzy", homeDirectory: home),
      "/tmp/snapzy"
    )
  }

  func testExpandedUserPathUsesProvidedHomeDirectory() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    XCTAssertEqual(
      SnapzyConfigurationPaths.expandedUserPath("~/Desktop", homeDirectory: home),
      "/Users/example/Desktop"
    )
    XCTAssertEqual(
      SnapzyConfigurationPaths.expandedUserPath("/tmp/snapzy", homeDirectory: home),
      "/tmp/snapzy"
    )
  }

  func testSuggestedConfigURLUsesAccountHomeDirectory() throws {
    guard
      let passwd = getpwuid(getuid()),
      let home = passwd.pointee.pw_dir
    else {
      throw XCTSkip("No POSIX home directory is available for the current user.")
    }

    let expectedHome = URL(fileURLWithPath: String(cString: home), isDirectory: true)
    let expectedURL = SnapzyConfigurationPaths.suggestedConfigURL(homeDirectory: expectedHome)

    XCTAssertEqual(SnapzyConfigurationService.shared.suggestedConfigURL.path, expectedURL.path)
  }
}
