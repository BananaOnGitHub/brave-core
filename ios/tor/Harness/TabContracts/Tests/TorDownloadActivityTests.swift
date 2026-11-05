import Foundation
import UIKit
import XCTest
@testable import WebTabContracts

@MainActor
final class TorDownloadActivityTests: XCTestCase {
  func testConcurrentDownloadsAndPowerChangesReleaseOnlyTheirOwnAssertion() {
    var idleDisabled = false
    var lowPower = false
    var active = true
    let activity = TorDownloadActivity(
      lowPowerMode: { lowPower }, foreground: { active },
      readIdleTimer: { idleDisabled }, writeIdleTimer: { idleDisabled = $0 },
      notifications: NotificationCenter()
    )
    let first = UUID(), second = UUID()
    activity.begin(first)
    activity.begin(second)
    activity.end(first)
    XCTAssertTrue(idleDisabled)
    lowPower = true
    activity.refresh()
    XCTAssertFalse(idleDisabled)
    lowPower = false
    activity.refresh()
    XCTAssertTrue(idleDisabled)
    active = false
    activity.refresh()
    XCTAssertFalse(idleDisabled)
    active = true
    activity.refresh()
    XCTAssertTrue(idleDisabled)
    activity.end(second)
    activity.end(second)
    XCTAssertFalse(idleDisabled)
  }

  func testStartsInLowPowerAndRestoresPreexistingIdleTimerState() {
    var idleDisabled = false
    var lowPower = true
    let activity = TorDownloadActivity(
      lowPowerMode: { lowPower }, foreground: { true },
      readIdleTimer: { idleDisabled }, writeIdleTimer: { idleDisabled = $0 },
      notifications: NotificationCenter()
    )
    let id = UUID()
    activity.begin(id)
    XCTAssertFalse(idleDisabled)
    idleDisabled = true
    lowPower = false
    activity.refresh()
    activity.end(id)
    XCTAssertTrue(idleDisabled)
  }

  func testPowerStateNotificationReleasesAnActiveAssertion() async {
    var idleDisabled = false
    var lowPower = false
    let center = NotificationCenter()
    let released = expectation(description: "Low Power Mode releases the idle timer")
    let activity = TorDownloadActivity(
      lowPowerMode: { lowPower }, foreground: { true },
      readIdleTimer: { idleDisabled }, writeIdleTimer: {
        idleDisabled = $0
        if !$0 { released.fulfill() }
      }, notifications: center
    )
    let id = UUID()
    activity.begin(id)
    XCTAssertTrue(idleDisabled)
    lowPower = true
    center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
    await fulfillment(of: [released], timeout: 2)
    XCTAssertFalse(idleDisabled)
    activity.end(id)
  }

  func testDownloadFilenamesCannotEscapeOrDisguiseTheirExtension() {
    XCTAssertEqual(TorDownload.safeFilename("../../report.pdf"), "report.pdf")
    XCTAssertEqual(TorDownload.safeFilename("..\\payload.exe"), "payload.exe")
    XCTAssertEqual(TorDownload.safeFilename("report\u{202E}fdp.exe"), "reportfdp.exe")
    XCTAssertEqual(TorDownload.safeFilename(".."), "download")
    XCTAssertEqual(TorDownload.safeFilename("\u{0000}"), "download")
    XCTAssertLessThanOrEqual(TorDownload.safeFilename(String(repeating: "é", count: 300)).utf8.count, 180)
  }
}
