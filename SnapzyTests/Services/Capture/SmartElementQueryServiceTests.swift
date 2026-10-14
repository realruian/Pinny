//
//  SmartElementQueryServiceTests.swift
//  SnapzyTests
//
//  Unit tests for the public service surface: permission gate, dedup,
//  cancel, and the Combine debounce. Tests use FakeAXSnapshotProvider so
//  they never hit the real Accessibility API.
//

import AppKit
import Combine
import XCTest
@testable import Snapzy

final class SmartElementQueryServiceTests: XCTestCase {

  private var cancellables = Set<AnyCancellable>()

  override func tearDown() {
    cancellables.removeAll()
    super.tearDown()
  }

  func testHierarchyNavigationAndManualChoiceSurviveSameComponentHover() throws {
    guard !NSScreen.screens.isEmpty else { throw XCTSkip("Requires display") }
    let card = AXElementSnapshot(role: "AXGroup", position: CGPoint(x: 20, y: 20), size: CGSize(width: 240, height: 160))
    let icon = AXElementSnapshot(role: "AXImage", position: CGPoint(x: 40, y: 40),
      size: CGSize(width: 24, height: 24), parent: { card })
    let service = SmartElementQueryService(snapshotProvider: FakeAXSnapshotProvider(snapshotForCall: [icon, icon]),
      permissionChecker: { true })
    var received: [CGRect?] = []
    service.elementDetectedPublisher.sink { received.append($0) }.store(in: &cancellables)
    service.queryElement(at: CGPoint(x: 50, y: 50), pid: 1)
    XCTAssertEqual(received.last??.width, 240)
    XCTAssertTrue(service.selectAdjacentCandidate(towardParent: false))
    XCTAssertEqual(received.last??.width, 24)
    service.queryElement(at: CGPoint(x: 51, y: 51), pid: 1)
    XCTAssertEqual(received.count, 2, "Explicit child choice must survive small pointer moves")
    XCTAssertTrue(service.selectAdjacentCandidate(towardParent: true))
    XCTAssertEqual(received.last??.width, 240)
    XCTAssertFalse(service.selectAdjacentCandidate(towardParent: true))
  }

  func testHoverStabilizesNestedChangesAndCancelDiscardsDelayedResult() throws {
    guard !NSScreen.screens.isEmpty else { throw XCTSkip("Requires display") }
    // Both groups are panel-sized, so either may be the default target.
    let outer = AXElementSnapshot(role: "AXGroup", position: CGPoint(x: 20, y: 20), size: CGSize(width: 300, height: 220))
    let inner = AXElementSnapshot(role: "AXGroup", position: CGPoint(x: 30, y: 30),
      size: CGSize(width: 200, height: 150), parent: { outer })
    let service = SmartElementQueryService(snapshotProvider: FakeAXSnapshotProvider(snapshotForCall: [outer, inner]),
      permissionChecker: { true }, stabilizationMilliseconds: 60)
    var received: [CGRect?] = []
    service.elementDetectedPublisher.sink { received.append($0) }.store(in: &cancellables)
    service.queryElement(at: CGPoint(x: 50, y: 50), pid: 1)
    service.queryElement(at: CGPoint(x: 51, y: 51), pid: 1)
    XCTAssertEqual(received.count, 1, "A nested change must not immediately jump")
    let stabilized = expectation(description: "Stable candidate accepted")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { stabilized.fulfill() }
    wait(for: [stabilized], timeout: 1)
    XCTAssertEqual(received.last??.width, 200)
    service.cancelPendingQueries()
    XCTAssertNil(received.last!)
    XCTAssertFalse(service.selectAdjacentCandidate(towardParent: true))
  }

  func testCancelInvalidatesQueuedAXResponse() {
    let service = SmartElementQueryService(snapshotProvider: CountingAXSnapshotProvider(snapshot: nil),
      permissionChecker: { true })
    var received: [CGRect?] = []
    service.elementDetectedPublisher.sink { received.append($0) }.store(in: &cancellables)
    service.updateLocation(.zero, pid: 1)
    service.cancelPendingQueries()
    let drained = expectation(description: "Queued query drained")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { drained.fulfill() }
    wait(for: [drained], timeout: 1)
    XCTAssertEqual(received.count, 1, "Only cancellation may emit after session ends")
  }

  func testSlowAXQueriesCoalesceToLatestPosition() throws {
    guard !NSScreen.screens.isEmpty else { throw XCTSkip("Requires display") }
    let provider = SlowAXSnapshotProvider()
    let service = SmartElementQueryService(snapshotProvider: provider, permissionChecker: { true },
      debounceMilliseconds: 1, stabilizationMilliseconds: 0)
    let resolved = expectation(description: "Latest position resolved")
    service.elementDetectedPublisher.compactMap { $0 }.sink { rect in
      XCTAssertEqual(rect.minX, 111)
      resolved.fulfill()
    }.store(in: &cancellables)
    for offset in 0..<12 {
      DispatchQueue.main.asyncAfter(deadline: .now() + Double(offset) * 0.012) {
        service.updateLocation(CGPoint(x: 100 + offset, y: 100), pid: 1)
      }
    }
    wait(for: [resolved], timeout: 1)
    XCTAssertLessThanOrEqual(provider.callCount, 3, "Obsolete positions must not queue full AX traversals")
  }

  func testStationaryUpdatesDoNotStarveSlowAXQuery() throws {
    guard !NSScreen.screens.isEmpty else { throw XCTSkip("Requires display") }
    let provider = SlowAXSnapshotProvider()
    let service = SmartElementQueryService(snapshotProvider: provider, permissionChecker: { true }, debounceMilliseconds: 1)
    let resolved = expectation(description: "Stationary candidate resolved")
    service.elementDetectedPublisher.compactMap { $0 }.prefix(1).sink { _ in resolved.fulfill() }
      .store(in: &cancellables)
    for offset in 0..<7 {
      DispatchQueue.main.asyncAfter(deadline: .now() + Double(offset) * 0.01) {
        service.updateLocation(CGPoint(x: 100, y: 100), pid: 1)
      }
    }
    wait(for: [resolved], timeout: 1)
    XCTAssertEqual(provider.callCount, 1)
  }

  // MARK: - Permission gate

  func testQueryElement_permissionDenied_emitsNil_logsOnce() {
    let service = SmartElementQueryService(
      snapshotProvider: FakeAXSnapshotProvider(snapshotForCall: [nil]),
      permissionChecker: { false }
    )
    var received: [CGRect?] = []
    service.elementDetectedPublisher.sink { received.append($0) }.store(in: &cancellables)

    service.queryElement(at: .zero, pid: nil)
    service.queryElement(at: CGPoint(x: 10, y: 10), pid: nil)
    service.queryElement(at: CGPoint(x: 20, y: 20), pid: nil)

    XCTAssertEqual(received.count, 1, "Subsequent nil emissions are deduped.")
    XCTAssertNil(received.first ?? .zero)
    XCTAssertEqual(service.permissionDeniedLogCount, 1, "Warning must be logged exactly once.")
  }

  // MARK: - Dedup

  func testQueryElement_dedupesIdenticalRect() throws {
    guard NSScreen.screens.first != nil else {
      throw XCTSkip("Needs at least one NSScreen.")
    }
    let button = AXElementSnapshot(
      role: "AXButton",
      position: CGPoint(x: 50, y: 50),
      size: CGSize(width: 40, height: 20)
    )
    let service = SmartElementQueryService(
      snapshotProvider: FakeAXSnapshotProvider(snapshotForCall: [button, button]),
      permissionChecker: { true }
    )
    var received: [CGRect?] = []
    service.elementDetectedPublisher.sink { received.append($0) }.store(in: &cancellables)

    service.queryElement(at: CGPoint(x: 60, y: 60), pid: 1)
    service.queryElement(at: CGPoint(x: 60, y: 60), pid: 1)

    XCTAssertEqual(received.count, 1, "Identical rect must emit only once.")
  }

  // MARK: - Cancel

  func testCancelPendingQueries_emitsNil_andResetsDedup() throws {
    guard NSScreen.screens.first != nil else {
      throw XCTSkip("Needs at least one NSScreen.")
    }
    let button = AXElementSnapshot(
      role: "AXButton",
      position: CGPoint(x: 50, y: 50),
      size: CGSize(width: 40, height: 20)
    )
    let service = SmartElementQueryService(
      snapshotProvider: FakeAXSnapshotProvider(snapshotForCall: [button, button]),
      permissionChecker: { true }
    )
    var received: [CGRect?] = []
    service.elementDetectedPublisher.sink { received.append($0) }.store(in: &cancellables)

    service.queryElement(at: CGPoint(x: 60, y: 60), pid: 1)
    service.cancelPendingQueries()
    service.queryElement(at: CGPoint(x: 60, y: 60), pid: 1)

    XCTAssertEqual(received.count, 3, "Expected: rect, nil (cancel), rect again (dedup reset).")
    XCTAssertNotNil(received[0])
    XCTAssertNil(received[1])
    XCTAssertNotNil(received[2])
  }

  // MARK: - Debounce

  func testDebounce_collapsesRapidUpdatesIntoOneQuery() throws {
    guard NSScreen.screens.first != nil else {
      throw XCTSkip("Needs at least one NSScreen.")
    }
    let provider = CountingAXSnapshotProvider(
      snapshot: AXElementSnapshot(
        role: "AXButton",
        position: CGPoint(x: 10, y: 10),
        size: CGSize(width: 30, height: 30)
      )
    )
    let service = SmartElementQueryService(
      snapshotProvider: provider,
      permissionChecker: { true },
      debounceMilliseconds: 25
    )

    let expectation = expectation(description: "Debounced emission")
    var received: [CGRect?] = []
    service.elementDetectedPublisher
      .sink { rect in
        received.append(rect)
        expectation.fulfill()
      }
      .store(in: &cancellables)

    for offset in 0..<5 {
      service.pushInputForTesting(
        point: CGPoint(x: 20 + Double(offset), y: 20),
        pid: 1
      )
    }

    wait(for: [expectation], timeout: 0.5)
    XCTAssertEqual(received.count, 1, "Debounce must collapse rapid inputs to one.")
    XCTAssertEqual(provider.callCount, 1, "Underlying AX query fires once after debounce window.")
  }
}

private final class SlowAXSnapshotProvider: AXSnapshotProviding {
  private let lock = NSLock()
  private var count = 0
  var callCount: Int { lock.lock(); defer { lock.unlock() }; return count }
  func snapshot(at point: CGPoint, pid: Int32?) -> AXElementSnapshot? {
    lock.lock(); count += 1; lock.unlock()
    Thread.sleep(forTimeInterval: 0.08) // Simulates an unresponsive target app on the worker queue.
    return AXElementSnapshot(role: "AXGroup", position: point, size: CGSize(width: 200, height: 120))
  }
}
