// Copyright (c) 2026 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. See https://mozilla.org/MPL/2.0/.
#if os(iOS)
import BraveTor
import Foundation
import Network
import WebKit

@MainActor
enum TorWebPolicy {
  // Onion Browser's Mysk mitigation uses the ping resource type for DNS prefetch.
  // Media is blocked until AVFoundation/streaming routes have been verified.
  static let contentRules = """
    [
      {"trigger":{"url-filter":".*","resource-type":["ping","media"]},
       "action":{"type":"block"}}
    ]
    """

  static func compileRules() async throws -> WKContentRuleList {
    // This local compilation has no cancellable WebKit API. Callers check their
    // lifecycle generation after the callback and before creating any web view.
    try await withCheckedThrowingContinuation { continuation in
      WKContentRuleListStore.default().compileContentRuleList(
        forIdentifier: "brave-tor-dns-containment-v1", encodedContentRuleList: contentRules
      ) { ruleList, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let ruleList {
          continuation.resume(returning: ruleList)
        } else {
          continuation.resume(throwing: TorError.unavailable)
        }
      }
    }
  }

  static func configuration(
    endpoint: TorEndpoint, rules: WKContentRuleList, isolationID: String,
    javaScriptEnabled: Bool
  ) -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    let store = WKWebsiteDataStore.nonPersistent()
    var proxy = ProxyConfiguration(
      socksv5Proxy: .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: endpoint.port)!)
    )
    proxy.allowFailover = false
    proxy.applyCredential(username: isolationID, password: isolationID)
    store.proxyConfigurations = [proxy]
    configuration.websiteDataStore = store
    configuration.userContentController.add(rules)
    applyPagePreferences(
      configuration.defaultWebpagePreferences, javaScriptEnabled: javaScriptEnabled
    )
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    // Selection menus can hand text/URLs to system lookup and share services.
    configuration.preferences.isTextInteractionEnabled = false
    configuration.allowsAirPlayForMediaPlayback = false
    configuration.allowsPictureInPictureMediaPlayback = false
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    return configuration
  }

  static func applyPagePreferences(
    _ preferences: WKWebpagePreferences, javaScriptEnabled: Bool
  ) {
    preferences.allowsContentJavaScript = javaScriptEnabled
    preferences.isLockdownModeEnabled = true
  }
}
#endif
