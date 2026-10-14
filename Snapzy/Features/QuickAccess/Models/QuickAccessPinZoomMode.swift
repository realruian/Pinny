//
//  QuickAccessPinZoomMode.swift
//  Snapzy
//

import Combine
import Foundation

enum QuickAccessPinZoomMode: String, CaseIterable, Identifiable {
  case windowFollowsImage
  case fixedViewport

  nonisolated static let defaultMode: Self = .windowFollowsImage

  var id: String { rawValue }
}

@MainActor
final class QuickAccessPinZoomModeStore: ObservableObject {
  static let shared = QuickAccessPinZoomModeStore()

  @Published private(set) var mode: QuickAccessPinZoomMode
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let rawValue = defaults.string(forKey: PreferencesKeys.quickAccessPinZoomMode),
       let stored = QuickAccessPinZoomMode(rawValue: rawValue) {
      mode = .windowFollowsImage
      if stored != mode { defaults.set(mode.rawValue, forKey: PreferencesKeys.quickAccessPinZoomMode) }
    } else {
      mode = .defaultMode
    }
  }

  func setMode(_ value: QuickAccessPinZoomMode) {
    let value: QuickAccessPinZoomMode = .windowFollowsImage
    guard mode != value else { return }
    mode = value
    defaults.set(value.rawValue, forKey: PreferencesKeys.quickAccessPinZoomMode)
  }
}
