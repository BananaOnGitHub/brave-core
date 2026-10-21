# Private with Tor integration

Branch: `feature/ios-private-with-tor`, based on the validated embedded Tor prototype.

## Behavior

- The existing tab grid has Regular, Private, and Private with Tor groups.
  Tor tabs are distinct from normal private tabs and use the normal browser toolbars.
- Opening a Tor tab starts the shared embedded runtime automatically. Each tab
  has its own ephemeral data store and SOCKS isolation credentials. Page JavaScript
  is enabled. The prototype-only default-off toggle does not apply here.
- A stable numeric loopback gate forwards opaque SOCKS traffic only to a ready
  embedded Tor listener. There is no destination resolver or direct fallback in
  the gate. Route changes and app suspension close active transports, disable Tor
  networking, and retain the page, DOM, storage and history. Foreground/network
  recovery reconnects automatically. Existing failed HTTP requests may need a
  site retry or reload; unsafe POST requests are not automatically replayed.
- Native WebKit process-pool timezone configuration forces UTC, covering Date,
  Intl, child frames and workers. This currently requires WebKit SPI in a sideload
  build. If that capability is missing, the tab does not create a web view.
  Other browsing modes retain their own process configuration.
- Tor tab sessions, URLs and screenshots are excluded from session persistence.
  Ordinary tab helpers, native metadata/favicons, translation, external schemes,
  native previews, sharing, voice search, favorite tiles, and decentralized
  address resolution are detached or blocked. Downloads and media remain blocked.

## Validation and build paths

The reusable `iOS Tor prototype` workflow compiles/tests the native Tor/WebKit
package and the actual `TorTabState` against Brave's real tab protocols, with
small Profile/string/disabled-download test doubles. It checks separate private stores and retained
DOM/form state during reconnect. Other tab-grid sources receive syntax checks;
the group-switch/reorder regression tests in `ClientTests` require the full app
workspace. Its IPA is a standalone harness, not Brave, and does not establish
full-app build validation.

`Brave iOS with Tor` initializes the pinned Chromium/Brave dependencies on its
runner, builds ARM64 BraveCore, and archives the actual Client Xcode target. It
uploads `BravePrivateTor-unsigned.ipa` directly, with a separate package report and
retained build logs. Its bundle prefix is `com.banana.brave.tor`, so it does not
replace the App Store Brave installation. The first full build can take hours.
Matching BraveCore frameworks are cached by backend source tree, exact Xcode/SDK,
and build recipe, so Swift-only fixes can reuse them while rebuilding the app.

Both build paths remove Xcode's redundant static Tor framework bundle before
validation, checking dynamic dependencies and unexpected resources first. Full
linking must verify embedded Tor/OpenSSL compatibility with BraveCore's crypto
dependencies. The native test package alone cannot establish this.

Required device acceptance:

1. Open, select, reorder, close and reopen tabs in all three groups. Tor children
   must remain Tor tabs. Ordinary/private tab stores must never acquire a proxy
   or UTC override. Tor tabs must not reappear after an app restart.
2. Verify Date, Intl and local-date construction in UTC, including frames and
   workers, on a device configured with a non-UTC timezone.
3. Fill a form and alter page DOM, then switch Wi-Fi/cellular or background the
   app. The same page must survive, with traffic paused until Tor is ready.
4. Capture gateway/device traffic and authoritative DNS probes, including IPv6,
   while changing routes, restarting Tor, and opening/closing concurrent tabs.
5. Repeat BrowserLeaks, CreepJS, DNS-prefetch, WebRTC, worker and WebAuthn probes.
   Prior prototype test results do not certify the integrated app.

The full-app archive and device acceptance remain unverified until their actual
results are recorded. This implementation does not provide Tor Browser-equivalent
fingerprinting protection.
