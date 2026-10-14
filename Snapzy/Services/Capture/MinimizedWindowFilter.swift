//
//  MinimizedWindowFilter.swift
//  Snapzy
//
//  Some apps (WeChat) leave a minimized window in the on-screen window list at full alpha.
//  It draws nothing, so window and element detection must look through it.
//

import ApplicationServices
import Foundation

enum MinimizedWindowFilter {
  /// Quartz (top-left) frames of the app's windows that Accessibility reports as minimized.
  /// Empty when Accessibility is unavailable, so nothing is filtered without permission.
  nonisolated static func minimizedFrames(pid: pid_t) -> [CGRect] {
    let app = AXUIElementCreateApplication(pid)
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let windows = windowsRef as? [AXUIElement] else { return [] }
    return windows.compactMap { window in
      var minimizedRef: CFTypeRef?
      guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
            (minimizedRef as? Bool) == true,
            let origin = value(window, kAXPositionAttribute, .cgPoint, CGPoint.zero),
            let size = value(window, kAXSizeAttribute, .cgSize, CGSize.zero) else { return nil }
      return CGRect(origin: origin, size: size)
    }
  }

  nonisolated static func matches(_ quartzFrame: CGRect, anyOf minimizedFrames: [CGRect]) -> Bool {
    minimizedFrames.contains {
      abs($0.minX - quartzFrame.minX) <= 2 && abs($0.minY - quartzFrame.minY) <= 2
        && abs($0.width - quartzFrame.width) <= 2 && abs($0.height - quartzFrame.height) <= 2
    }
  }

  private nonisolated static func value<T>(_ element: AXUIElement, _ attribute: String, _ type: AXValueType, _ initial: T) -> T? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
          let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    var result = initial
    guard AXValueGetValue(raw as! AXValue, type, &result) else { return nil }
    return result
  }
}
