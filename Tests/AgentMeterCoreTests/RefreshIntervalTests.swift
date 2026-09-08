import Foundation
import XCTest

@testable import AgentMeterCore

final class RefreshIntervalTests: XCTestCase {
  private let suiteName = "AgentMeterCoreTests.RefreshInterval.\(UUID().uuidString)"
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    super.tearDown()
  }

  func testPersistenceRoundTripUsesIsolatedDefaultsSuite() {
    RefreshInterval.tenMinutes.save(to: defaults)

    XCTAssertEqual(
      defaults.object(forKey: RefreshInterval.userDefaultsKey) as? Int,
      RefreshInterval.tenMinutes.rawValue)
    XCTAssertEqual(RefreshInterval.load(from: defaults), .tenMinutes)
  }

  func testInvalidPersistedValuesUseFiveMinuteDefault() {
    XCTAssertEqual(RefreshInterval.load(from: defaults), .fiveMinutes)

    for rawValue in [-1, 1, 301] {
      defaults.set(rawValue, forKey: RefreshInterval.userDefaultsKey)
      XCTAssertEqual(RefreshInterval.load(from: defaults), .fiveMinutes)
    }

    defaults.set("300", forKey: RefreshInterval.userDefaultsKey)
    XCTAssertEqual(RefreshInterval.load(from: defaults), .fiveMinutes)
  }

  func testOffHasNoDurationAndIntervalsConvertToSeconds() {
    XCTAssertNil(RefreshInterval.off.duration)
    XCTAssertEqual(RefreshInterval.oneMinute.duration, 60)
    XCTAssertEqual(RefreshInterval.fiveMinutes.duration, 300)
    XCTAssertEqual(RefreshInterval.thirtyMinutes.duration, 1_800)
  }
}
