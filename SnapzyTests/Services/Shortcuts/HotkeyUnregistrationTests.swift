//
//  HotkeyUnregistrationTests.swift
//  SnapzyTests
//
//  Regression probe for GitHub issue #418:
//  "When a screenshot shortcut is disabled, the key combo still works
//   and cannot be reused by other apps."
//
//  These tests exercise the real `KeyboardShortcutManager` inside the app
//  test host and verify at the Carbon level that disabling a shortcut
//  synchronously frees its `RegisterEventHotKey` registration.
//

import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Snapzy

final class HotkeyUnregistrationTests: XCTestCase {

  /// Bare F17 exercises modifier-free Carbon registration without using user F1/F2.
  private let probeConfig = ShortcutConfig(
    keyCode: UInt32(kVK_F17),
    modifiers: 0
  )

  private let probeHotkeyID = EventHotKeyID(signature: OSType(0x5A54_5354), id: 999)  // "ZTST"

  /// Attempt to register the probe combo from this process.
  /// Returns `eventHotKeyExistsErr` (-9878) when someone already holds it.
  @discardableResult
  private func probeRegister() -> (status: OSStatus, ref: EventHotKeyRef?) {
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      probeConfig.keyCode,
      probeConfig.modifiers,
      probeHotkeyID,
      GetApplicationEventTarget(),
      0,
      &ref
    )
    return (status, ref)
  }

  @MainActor
  private func preserveMasterEnabledState(of manager: KeyboardShortcutManager) {
    let wasEnabled = manager.isEnabled
    addTeardownBlock { @MainActor in
      wasEnabled ? manager.enable() : manager.disable()
    }
  }

  @MainActor
  func testDisablingShortcutFreesCarbonRegistration() throws {
    try skipIfRunningInCI("Carbon hotkey registration is unsupported on headless CI runners")
    let manager = KeyboardShortcutManager.shared

    let originalConfig = manager.shortcut(for: .areaAnnotate)
    let originalFullscreenEnabled = manager.isShortcutEnabled(for: .areaAnnotate)
    preserveMasterEnabledState(of: manager)
    addTeardownBlock { @MainActor in
      manager.setAreaAnnotateShortcut(originalConfig)
      manager.setShortcutEnabled(originalFullscreenEnabled, for: .areaAnnotate)
    }

    // Preconditions: combo must be free before we start.
    let pre = probeRegister()
    guard pre.status == noErr else {
      throw XCTSkip("Probe combo unexpectedly held before test (status \(pre.status))")
    }
    UnregisterEventHotKey(pre.ref!)

    // Arm Snapzy's fullscreen shortcut with the probe combo.
    manager.enable()
    manager.setAreaAnnotateShortcut(probeConfig)
    manager.setShortcutEnabled(true, for: .areaAnnotate)

    // While enabled, the combo must be held by Snapzy (duplicate registration rejected).
    let held = probeRegister()
    XCTAssertEqual(
      held.status, OSStatus(-9878),
      "Expected Snapzy to hold the combo while the shortcut is enabled"
    )
    if let ref = held.ref { UnregisterEventHotKey(ref) }

    // Issue #418: disable the shortcut — the combo must become free immediately.
    manager.setShortcutEnabled(false, for: .areaAnnotate)

    let freed = probeRegister()
    XCTAssertEqual(
      freed.status, noErr,
      "Combo must be free at the Carbon level after disabling the shortcut (issue #418)"
    )
    if let ref = freed.ref { UnregisterEventHotKey(ref) }

    // And the manager must report it disabled.
    XCTAssertFalse(manager.isShortcutEnabled(for: .areaAnnotate))
  }

  @MainActor
  func testDisabledComboCanBeReassignedToAnotherKind() throws {
    try skipIfRunningInCI("Carbon hotkey registration is unsupported on headless CI runners")
    let manager = KeyboardShortcutManager.shared

    let originalFullscreen = manager.shortcut(for: .areaAnnotate)
    let originalCutout = manager.shortcut(for: .pinClipboard)
    let originalFullscreenEnabled = manager.isShortcutEnabled(for: .areaAnnotate)
    let originalCutoutEnabled = manager.isShortcutEnabled(for: .pinClipboard)
    preserveMasterEnabledState(of: manager)
    addTeardownBlock { @MainActor in
      manager.setAreaAnnotateShortcut(originalFullscreen)
      manager.setPinClipboardShortcut(originalCutout)
      manager.setShortcutEnabled(originalFullscreenEnabled, for: .areaAnnotate)
      manager.setShortcutEnabled(originalCutoutEnabled, for: .pinClipboard)
    }

    let pre = probeRegister()
    guard pre.status == noErr else {
      throw XCTSkip("Probe combo unexpectedly held before test (status \(pre.status))")
    }
    UnregisterEventHotKey(pre.ref!)

    // Fullscreen holds the combo, then gets disabled; user reassigns the
    // combo to objectCutout (the "不能把这个 3 的按键换成别的" scenario).
    manager.enable()
    manager.setAreaAnnotateShortcut(probeConfig)
    manager.setShortcutEnabled(true, for: .areaAnnotate)
    manager.setShortcutEnabled(false, for: .areaAnnotate)
    manager.setPinClipboardShortcut(probeConfig)
    manager.setShortcutEnabled(true, for: .pinClipboard)

    // objectCutout must now own the registration — probe still reports held…
    let held = probeRegister()
    XCTAssertEqual(held.status, OSStatus(-9878))
    if let ref = held.ref { UnregisterEventHotKey(ref) }

    // …and disabling objectCutout frees it again.
    manager.setShortcutEnabled(false, for: .pinClipboard)
    let freed = probeRegister()
    XCTAssertEqual(freed.status, noErr, "Combo must be freed after disabling the reassigned kind")
    if let ref = freed.ref { UnregisterEventHotKey(ref) }
  }
}
