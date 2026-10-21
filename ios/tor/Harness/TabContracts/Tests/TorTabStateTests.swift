import BraveCore
import BraveTor
import BraveTorUI
import UIKit
import WebKit
import XCTest
@testable import WebTabContracts

private final class ContractProfile: Profile { let isOffTheRecord = true }

@MainActor
final class TorTabStateTests: XCTestCase {
  func testTwoTabsKeepIndependentPrivateStoresAndRetainDOMAcrossReconnect() async throws {
    let session = TorBrowsingSession(runtime: TorRuntime(), automaticallyConnect: false)
    let first = TorTabState(id: UUID(), profile: ContractProfile(), session: session)
    let second = TorTabState(id: UUID(), profile: ContractProfile(), session: session)
    let created = expectation(description: "Both native tabs created")
    created.expectedFulfillmentCount = 2
    let observer = CreationObserver { created.fulfill() }
    first.addObserver(observer)
    second.addObserver(observer)
    first.createWebView()
    second.createWebView()
    defer { first.deleteWebView(); second.deleteWebView() }
    await fulfillment(of: [created], timeout: 15)
    XCTAssertTrue(first.isTor)
    XCTAssertTrue(first.isPrivate)
    let firstStore = try XCTUnwrap(first.configuration?.websiteDataStore)
    XCTAssertFalse(firstStore.isPersistent)
    XCTAssertFalse(firstStore === second.configuration?.websiteDataStore)
    XCTAssertFalse(try XCTUnwrap(firstStore.proxyConfigurations.first).allowFailover)
    XCTAssertNil(first.sessionData)
    let scrollView = try XCTUnwrap(first.webViewProxy?.scrollView)
    let initial = try await first.callAsyncJavaScript("""
      document.documentElement.innerHTML = '<body><input id="test" value="retained"></body>';
      window.sessionMarker = 'same page';
      return Intl.DateTimeFormat().resolvedOptions().timeZone;
      """, arguments: [:], in: nil, contentWorld: .page)
    XCTAssertEqual(initial as? String, "UTC")
    session.reconnect()
    first.loadRequest(URLRequest(url: URL(string: "https://pending-tor-request.invalid/")!))
    XCTAssertTrue(first.webViewProxy?.scrollView === scrollView)
    let retained = try await first.callAsyncJavaScript(
      "return [document.getElementById('test').value, window.sessionMarker].join('|');",
      arguments: [:], in: nil, contentWorld: .page
    )
    XCTAssertEqual(retained as? String, "retained|same page")
    XCTAssertEqual(session.state, .waiting)
    XCTAssertNil(first.sessionData)
  }

  private final class CreationObserver: TabObserver {
    let callback: () -> Void
    init(callback: @escaping () -> Void) { self.callback = callback }
    func tabDidFinishNavigation(_ tab: some TabState) { callback() }
  }
}
