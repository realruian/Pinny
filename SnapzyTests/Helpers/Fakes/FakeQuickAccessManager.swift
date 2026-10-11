//
//  FakeQuickAccessManager.swift
//  SnapzyTests
//
//  Records QuickAccessManaging calls for assertion.
//

import AppKit
import Foundation
@testable import Snapzy

@MainActor
final class FakeQuickAccessManager: QuickAccessManaging {
  private(set) var addedScreenshots: [URL] = []
  private(set) var addedVideos: [URL] = []
  private(set) var createdScreenshotItems: [QuickAccessItem] = []
  private(set) var createdVideoItems: [QuickAccessItem] = []
  private(set) var pinnedScreenshotIDs: [UUID] = []
  private(set) var pinnedScreenshotURLs: [URL] = []
  private(set) var pinnedSourceRects: [CGRect?] = []
  var onAddScreenshot: ((URL) -> Void)?
  var onAddVideo: ((URL) -> Void)?

  @discardableResult
  func addScreenshot(url: URL) async -> QuickAccessItem? {
    onAddScreenshot?(url)
    addedScreenshots.append(url)
    let item = QuickAccessItem(url: url, thumbnail: NSImage(size: NSSize(width: 1, height: 1)))
    createdScreenshotItems.append(item)
    return item
  }

  @discardableResult
  func addVideo(url: URL) async -> QuickAccessItem? {
    onAddVideo?(url)
    addedVideos.append(url)
    let item = QuickAccessItem(
      url: url,
      thumbnail: NSImage(size: NSSize(width: 1, height: 1)),
      duration: 0
    )
    createdVideoItems.append(item)
    return item
  }

  func pinScreenshot(id: UUID, sourceScreenRect: CGRect? = nil) {
    pinnedScreenshotIDs.append(id)
    pinnedSourceRects.append(sourceScreenRect)
  }

  @discardableResult
  func pinScreenshot(url: URL, sourceScreenRect: CGRect? = nil) async -> QuickAccessItem? {
    pinnedScreenshotURLs.append(url)
    pinnedSourceRects.append(sourceScreenRect)
    let item = QuickAccessItem(url: url, thumbnail: NSImage(size: NSSize(width: 1, height: 1)))
    createdScreenshotItems.append(item)
    return item
  }
}
