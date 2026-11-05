import Flutter
import UIKit
import XCTest

class RunnerTests: XCTestCase {

  func testBluetoothUsageDescriptionIsPresent() {
    let description = Bundle.main.object(
      forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription"
    ) as? String
    XCTAssertFalse(description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
  }

  func testAppDoesNotRequestPermanentBluetoothBackgroundMode() {
    let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
    XCTAssertFalse(modes.contains("bluetooth-central"))
  }

}
