//
//  QuickAccessManaging.swift
//  Snapzy
//
//  Protocol extracted from QuickAccessManager for DI.
//

import Foundation

@MainActor
protocol QuickAccessManaging {
  @discardableResult
  func addScreenshot(url: URL) async -> QuickAccessItem?

  @discardableResult
  func addVideo(url: URL) async -> QuickAccessItem?

  func pinScreenshot(id: UUID, sourceScreenRect: CGRect?)

  @discardableResult
  func pinScreenshot(url: URL, sourceScreenRect: CGRect?) async -> QuickAccessItem?
}

extension QuickAccessManager: QuickAccessManaging {}
