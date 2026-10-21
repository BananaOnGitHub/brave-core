// Copyright (c) 2026 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the Mozilla Public
// License, v. 2.0. See https://mozilla.org/MPL/2.0/.
import Foundation

extension Strings {
  public enum Tor {
    public static let newTab = NSLocalizedString(
      "Tor.newTab", bundle: .module,
      value: "New Tor tab",
      comment: "Open a private Tor tab"
    )
    public static let reload = NSLocalizedString(
      "Tor.reload", bundle: .module,
      value: "Reload",
      comment: "Reload Tor page"
    )
    public static let title = NSLocalizedString(
      "Tor.title", bundle: .module,
      value: "Private with Tor",
      comment: "Tor tab group title"
    )
    public static let waiting = NSLocalizedString(
      "Tor.waiting", bundle: .module,
      value: "Waiting for a network…",
      comment: "Tor paused"
    )
    public static let connecting = NSLocalizedString(
      "Tor.connecting", bundle: .module,
      value: "Connecting through Tor…",
      comment: "Tor connecting"
    )
    public static let connected = NSLocalizedString(
      "Tor.connected", bundle: .module,
      value: "Connected through Tor",
      comment: "Tor connected"
    )
    public static let unavailable = NSLocalizedString(
      "Tor.unavailable", bundle: .module,
      value: "Tor unavailable. Browsing is paused.",
      comment: "Tor cannot connect"
    )
    public static let utcUnavailable = NSLocalizedString(
      "Tor.utcUnavailable", bundle: .module,
      value: "Tor protections are unavailable on this iOS version. No page was loaded.",
      comment: "Mandatory Tor protection unavailable"
    )
    public static let privacyTitle = NSLocalizedString(
      "Tor.privacyTitle", bundle: .module,
      value: "Browse through the Tor network",
      comment: "Tor empty tab group heading"
    )
    public static let privacyBody = NSLocalizedString(
      "Tor.privacyBody", bundle: .module,
      value: "Tor connects automatically. These tabs use separate private sessions and UTC time. Network changes pause traffic while keeping your pages open.",
      comment: "Tor empty tab group explanation"
    )
    public static let limitations = NSLocalizedString(
      "Tor.limitations", bundle: .module,
      value: "Tor protects these tabs. Downloads, media, previews, translation, and other browser services are unavailable in this build.",
      comment: "Tor integration feature limitations"
    )
  }
}
