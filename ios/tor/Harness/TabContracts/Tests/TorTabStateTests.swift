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
  func testModeSnapshotRecreationAndLastSharedTabClose() async throws {
    let session = TorBrowsingSession(runtime: TorRuntime(), automaticallyConnect: false)
    // Constructor values model OFF -> ON -> OFF while older tabs stay open.
    let first = TorTabState(
      id: UUID(), profile: ContractProfile(), session: session, keepTabsSeparate: false
    )
    let isolated = TorTabState(
      id: UUID(), profile: ContractProfile(), session: session, keepTabsSeparate: true
    )
    let second = TorTabState(
      id: UUID(), profile: ContractProfile(), session: session, keepTabsSeparate: false
    )
    defer { [first, isolated, second].forEach { $0.close() } }
    try await createViews([first, isolated, second])
    let originalStore = try XCTUnwrap(first.configuration?.websiteDataStore)
    XCTAssertTrue(originalStore === second.configuration?.websiteDataStore)
    XCTAssertFalse(originalStore === isolated.configuration?.websiteDataStore)
    let cookie = try XCTUnwrap(HTTPCookie(properties: [
      .name: "tab_context", .value: "retained", .domain: "brave-tor-storage.invalid", .path: "/",
    ]))
    await originalStore.httpCookieStore.setCookie(cookie)
    first.deleteWebView()
    try await createViews([first])
    XCTAssertTrue(originalStore === first.configuration?.websiteDataStore)
    let recreatedCookies = await first.configuration?.websiteDataStore.httpCookieStore.allCookies()
    XCTAssertEqual(recreatedCookies?.first { $0.name == "tab_context" }?.value, "retained")
    first.close()
    // Retain both closed tab objects and the old store, as an undo/UI callback
    // can. They must not keep the retired session available to new tabs.
    XCTAssertTrue(originalStore === second.configuration?.websiteDataStore)
    second.close()
    let fresh = TorTabState(
      id: UUID(), profile: ContractProfile(), session: session, keepTabsSeparate: false
    )
    defer { fresh.close() }
    try await createViews([fresh])
    let freshStore = try XCTUnwrap(fresh.configuration?.websiteDataStore)
    XCTAssertFalse(originalStore === freshStore)
    XCTAssertFalse(freshStore === isolated.configuration?.websiteDataStore)
    let freshCookies = await freshStore.httpCookieStore.allCookies()
    XCTAssertFalse(freshCookies.contains { $0.name == "tab_context" })
    // Undo reopens under the tab's original mode, with the current fresh
    // shared session, rather than restoring the closed session's data.
    try await createViews([first])
    XCTAssertTrue(freshStore === first.configuration?.websiteDataStore)
    XCTAssertNil(first.sessionData)
  }

  func testCloseAndReopenWhileCreationIsQueuedUsesOnlyTheNewSession() async throws {
    let session = TorBrowsingSession(runtime: TorRuntime(), automaticallyConnect: false)
    let tab = TorTabState(
      id: UUID(), profile: ContractProfile(), session: session, keepTabsSeparate: false
    )
    let peer = TorTabState(
      id: UUID(), profile: ContractProfile(), session: session, keepTabsSeparate: true
    )
    defer { tab.close(); peer.close() }
    tab.createWebView()
    tab.close()
    try await createViews([tab, peer])
    XCTAssertTrue(tab.isWebViewCreated)
    XCTAssertFalse(tab.configuration?.websiteDataStore === peer.configuration?.websiteDataStore)
    XCTAssertFalse(tab.configuration?.websiteDataStore.isPersistent ?? true)
  }

  private func createViews(_ tabs: [TorTabState]) async throws {
    let created = expectation(description: "Tor tab documents created")
    created.expectedFulfillmentCount = tabs.count
    let observer = CreationObserver { created.fulfill() }
    tabs.forEach { $0.addObserver(observer); $0.createWebView() }
    await fulfillment(of: [created], timeout: 15)
    tabs.forEach { $0.removeObserver(observer) }
    XCTAssertTrue(tabs.allSatisfy(\.isWebViewCreated))
  }

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
