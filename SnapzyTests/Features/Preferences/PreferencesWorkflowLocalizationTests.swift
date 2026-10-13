import XCTest
@testable import Snapzy

final class PreferencesWorkflowLocalizationTests: XCTestCase {
  func testWorkflowStringsResolveFromBundledChineseAndEnglishCatalogs() {
    let key = "preferences-workflow.double-click-title"
    XCTAssertEqual(L10n.string(key, defaultValue: "MISSING", localeIdentifier: "zh-Hans", comment: ""),
                   "双击复制并关闭")
    XCTAssertEqual(L10n.string(key, defaultValue: "MISSING", localeIdentifier: "en", comment: ""),
                   "Double-click to copy and close")
    XCTAssertFalse(L10n.PreferencesWorkflow.captureSection.isEmpty)
    XCTAssertFalse(L10n.PreferencesWorkflow.accessibilityPermission.isEmpty)
  }
}
