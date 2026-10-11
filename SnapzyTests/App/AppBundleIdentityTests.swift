import XCTest
@testable import Snapzy

@MainActor
final class AppBundleIdentityTests: XCTestCase {
  func testDevelopmentBuildAcceptsNormalIdentityUsedByInstalledApp() async {
    XCTAssertTrue(AppBundleIdentity.matches("com.trongduong.snapzy", debugBuild: true))
  }

  func testDevelopmentBuildAcceptsSeparateDebugIdentity() async {
    XCTAssertTrue(AppBundleIdentity.matches("com.trongduong.snapzy.debug", debugBuild: true))
  }

  func testReleaseBuildRequiresReleaseIdentity() async {
    XCTAssertTrue(AppBundleIdentity.matches("com.trongduong.snapzy", debugBuild: false))
    XCTAssertFalse(AppBundleIdentity.matches("com.trongduong.snapzy.debug", debugBuild: false))
  }

  func testPreviewIdentityIsLimitedToDevelopmentBuilds() async {
    XCTAssertTrue(AppBundleIdentity.matches("com.tianruian.openshot.preview", debugBuild: true))
    XCTAssertFalse(AppBundleIdentity.matches("com.tianruian.openshot.preview", debugBuild: false))
    XCTAssertFalse(AppBundleIdentity.matches("com.tianruian.openshot.preview.other", debugBuild: true))
  }

  func testNeitherBuildAcceptsMissingOrUnrelatedIdentity() async {
    for debugBuild in [true, false] {
      for identifier in [nil, "", "com.example.snapzy", "com.trongduong.snapzy.debug.other"] as [String?] {
        XCTAssertFalse(AppBundleIdentity.matches(identifier, debugBuild: debugBuild))
      }
    }
  }

  func testCurrentBuildUsesItsConfiguredDefault() async {
    XCTAssertTrue(AppBundleIdentity.matches(AppBundleIdentity.expected))
  }
}
