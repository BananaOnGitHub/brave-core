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
    let first = try TorWebPolicy.configuration(
      endpoint: endpoint, rules: rules, isolationID: "first", javaScriptEnabled: false
    )
    let second = try TorWebPolicy.configuration(
      endpoint: endpoint, rules: rules, isolationID: "second", javaScriptEnabled: false
    )
    XCTAssertFalse(first.websiteDataStore.isPersistent)
    XCTAssertFalse(first.websiteDataStore === second.websiteDataStore)
    XCTAssertEqual(first.websiteDataStore.proxyConfigurations.count, 1)
    XCTAssertFalse(try XCTUnwrap(first.websiteDataStore.proxyConfigurations.first).allowFailover)
    XCTAssertFalse(first.defaultWebpagePreferences.allowsContentJavaScript)
    XCTAssertTrue(first.defaultWebpagePreferences.isLockdownModeEnabled)
    XCTAssertFalse(first.allowsAirPlayForMediaPlayback)
    XCTAssertFalse(first.allowsPictureInPictureMediaPlayback)
    XCTAssertFalse(first.preferences.javaScriptCanOpenWindowsAutomatically)
    XCTAssertFalse(first.preferences.isTextInteractionEnabled)
  }

  func testJavaScriptChoicePreservesNativeProtectionsAndNavigationPreferences() async throws {
    let rules = try await TorWebPolicy.compileRules()
    let endpoint = try TorEndpoint(listener: "127.0.0.1:9050")
    let configuration = try TorWebPolicy.configuration(
      endpoint: endpoint, rules: rules, isolationID: "script-test", javaScriptEnabled: true
    )
    XCTAssertTrue(configuration.defaultWebpagePreferences.allowsContentJavaScript)
    XCTAssertTrue(configuration.defaultWebpagePreferences.isLockdownModeEnabled)
    XCTAssertFalse(configuration.websiteDataStore.isPersistent)
    XCTAssertEqual(configuration.websiteDataStore.proxyConfigurations.count, 1)
    XCTAssertFalse(
      try XCTUnwrap(configuration.websiteDataStore.proxyConfigurations.first).allowFailover
    )
    XCTAssertFalse(configuration.preferences.javaScriptCanOpenWindowsAutomatically)
    XCTAssertFalse(configuration.allowsAirPlayForMediaPlayback)
    XCTAssertFalse(configuration.allowsPictureInPictureMediaPlayback)
    let navigation = WKWebpagePreferences()
    TorWebPolicy.applyPagePreferences(navigation, javaScriptEnabled: true)
    XCTAssertTrue(navigation.allowsContentJavaScript)
    TorWebPolicy.applyPagePreferences(navigation, javaScriptEnabled: false)
    XCTAssertFalse(navigation.allowsContentJavaScript)
    XCTAssertTrue(navigation.isLockdownModeEnabled)
  }
}
#endif
