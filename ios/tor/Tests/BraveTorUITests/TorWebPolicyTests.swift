// Copyright (c) 2026 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. See https://mozilla.org/MPL/2.0/.
#if os(iOS)
import BraveTor
import WebKit
import XCTest
@testable import BraveTorUI

@MainActor
final class TorWebPolicyTests: XCTestCase {
  func testProtectionCompilationAndSeparateEphemeralStores() async throws {
    let rules = try await TorWebPolicy.compileRules()
    let endpoint = try TorEndpoint(listener: "127.0.0.1:9050")
    let first = TorWebPolicy.configuration(endpoint: endpoint, rules: rules, isolationID: "first")
    let second = TorWebPolicy.configuration(endpoint: endpoint, rules: rules, isolationID: "second")
    XCTAssertFalse(first.websiteDataStore.isPersistent)
    XCTAssertFalse(first.websiteDataStore === second.websiteDataStore)
    XCTAssertEqual(first.websiteDataStore.proxyConfigurations.count, 1)
    XCTAssertFalse(try XCTUnwrap(first.websiteDataStore.proxyConfigurations.first).allowFailover)
    XCTAssertFalse(first.defaultWebpagePreferences.allowsContentJavaScript)
    XCTAssertTrue(first.defaultWebpagePreferences.isLockdownModeEnabled)
    XCTAssertFalse(first.allowsAirPlayForMediaPlayback)
    XCTAssertFalse(first.allowsPictureInPictureMediaPlayback)
    XCTAssertFalse(first.preferences.javaScriptCanOpenWindowsAutomatically)
  }
}
#endif
