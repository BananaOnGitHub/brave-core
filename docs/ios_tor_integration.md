# Private with Tor integration

## Tor settings and bridges

Private Tabs settings now links to a dedicated Tor page. The existing isolation
preference is reused there and stays ON by default. Tor availability defaults
ON for existing installations. Disabling it immediately closes the forwarding
gate, closes Tor tabs, hides Tor entry controls, and prevents stale shortcuts
or menu actions from loading an onion request into regular/private browsing.
The independent onion-only preference defaults ON and is not reset by the master
switch. Navigation policy and a WebKit content rule block onion frame/resource
requests outside Tor. Turning it OFF leaves resolution to the existing network
configuration; it does not give regular/private tabs a Tor route.

The bridge editor follows Desktop's built-in/request/provide choices and Apply
Changes behavior. Desktop uses obfs4, not obfs2. Built-in bridge lines are copied
from components/tor/tor_utils.cc at c5768996bee5d2fd5f4c30a421f9c9cc517558d0.
They are a bundled snapshot rather than automatically refreshed network data.
meek-azure is retained for Desktop compatibility; service reachability is not
guaranteed. User-provided numeric IPv4/IPv6 bridges and the obfs4, snowflake and
meek_lite transports are accepted. Other transports and hostname bridge addresses
are rejected. Bridge count/length, IP/port, fingerprint and argument validation
exclude control characters, quotes and backslashes before constructing commands.

IPtProxy 5.7.0 supplies in-process client transports on iOS, simulator and macOS.
Its package currently requires Swift tools 6.3. It is pinned to revision
46552b8422a200e3e69aa3686b6278be945138a5. Only its transport Controller is used;
the Snowflake volunteer proxy is never instantiated. Snowflake's own WebRTC/STUN
connections belong to Tor bootstrap, while website WebRTC remains blocked.

Applying bridges closes the SOCKS forwarding gate and suspends Tor first. The
runtime validates lines, starts the required loopback transports and installs
UseBridges/Bridge/ClientTransportPlugin while DisableNetwork remains 1. It only
enables networking after configuration succeeds. Invalid settings or transport
failures leave the gate closed, without reverting to public relays. Suspension
stops active transports; route recovery restarts them using the saved settings.
Changing bridge configuration preserves existing nonpersistent website contexts
and SOCKS identities; the isolation toggle still applies only to new tabs.

The native CAPTCHA sheet ports Desktop's JSON Moat fetch/check requests and shim
header from browser/ui/webui/settings/brave_tor_handler.cc. Only an explicit user
request contacts bridges.torproject.org over direct HTTPS, using an ephemeral
URLSession without cookies/cache and with redirects refused. This bootstrap
connection is intentionally outside Tor so requesting bridges does not depend
on Tor already working. Captcha tokens/images remain in memory; only validated
returned bridge lines can be saved. Responses have a 256 KiB limit, images a
192 KiB limit, and returned transports are restricted to obfs4. Failed/wrong
CAPTCHAs allow refresh; cancellation cancels the request. No HTML scraping or
automatic CAPTCHA solving is used. A live fetch from this environment returned
HTTP 405 and the GET endpoint displayed Site Unavailable, so successful live
CAPTCHA retrieval/submission still requires on-device verification.

Validation added: built-in and custom bridge grammar; command-injection rejection;
required transport ports; corrupt preferences and empty lists failing closed;
Moat decoding/bounds; a real offline embedded-Tor check that invalid bridges never
enable networking; master-switch tab cleanup and stale-entry behavior; and native
WebKit rule compilation. Native tests cannot run in the Linux editing environment.
On device, check every built-in transport, manual/requested bridges, bridge changes
with existing tabs, reconnect/background behavior, CAPTCHA success/error/cancel,
the private-browsing lock, both master states and the independent onion switch.
Test iframe, fetch/XHR and WebSocket onion requests outside Tor as well as typed
onion navigations. Confirm no website request leaves through a direct connection.

Branch: `feature/ios-private-with-tor`, based on the validated embedded Tor prototype.

## Behavior

- The existing tab grid has Regular, Private, and Private with Tor groups.
  Tor tabs are distinct from normal private tabs and use the normal browser toolbars.
- Opening a Tor tab starts the shared embedded runtime automatically. The
  default-on **Keep Tor tabs separate** setting gives each tab its own
  nonpersistent website data store and random SOCKS credentials. With it off,
  Tor tabs share a Tor-only nonpersistent store and one random SOCKS identity.
  Page JavaScript is enabled. The prototype-only default-off toggle does not apply here.
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
  native sharing, voice search, and decentralized
  address resolution are detached or blocked. Downloads and media remain blocked.

## Storage and circuit policy

Tor tab-grid thumbnails use WebKit viewport snapshots cached only in the tab's
memory. Icons are read from same-origin raster icon links (or `/favicon.ico`)
inside the existing proxied web view, in an isolated script world. Requests reject
redirects, limit response bytes/time and rasterize to 64x64 PNGs. Cross-origin,
SVG-only, CSP-blocked or failed icons retain the default placeholder. No native
favicon downloader, shared favicon cache or screenshot persistence is enabled.
Navigation/closure invalidates pending visual results. Device validation should
check grid opening, tab switching, scrolling, navigation and closure while Tor
is reconnecting; verify icon requests at the SOCKS listener, not just the UI.

The setting is captured at tab creation. ON tabs never join an OFF store or
reuse its credentials. OFF tabs created while other OFF tabs remain open join
that same shared session, including across OFF -> ON -> OFF changes. They do
not join regular/private Brave stores. Cookies, LocalStorage, IndexedDB and other
website data follow the selected store; normal web origin restrictions still apply.

An explicit tab-session handle retains this context across web-view recreation,
backgrounding and network recovery. Closing a tab releases its handle separately
from detaching its web view. Closing the last OFF tab synchronously retires the
shared context, even if closed tab objects are retained for undo or configuration
creation is still pending. A later OFF tab gets a fresh store and credentials.
Undo reopens the tab in its original mode with a fresh/current context, without
resurrecting a retired store. All stores are created with `nonPersistent()`; no
store identifier or session restoration data is written. An app restart cannot
reacquire the previous store. Releasing a store is not a guarantee of immediate
zeroing of WebKit/OS memory or data held by unrelated outstanding references.

### WebKit limitation and supported fallback

**OFF does not implement Desktop's per-top-level-website circuit isolation.**
Different top-level websites in an OFF session can use the same Tor circuits.
All requests in that shared store have the same username/password until its last
tab closes. Tor still makes its own circuit/exit decisions; matching credentials
do not promise the same circuit or exit IP. ON contexts have distinct credentials,
enforced by the runtime's existing `IsolateSOCKSAuth` option.

The inspected Apple public proxy APIs set credentials on a `ProxyConfiguration`
attached to `WKWebsiteDataStore.proxyConfigurations`, with no per-request
top-frame-site credential callback. WebKit's public header explicitly applies
this configuration to **all web views using the store**, and warns that changes
can interrupt their networking. Its Cocoa network session applies these proxies
to `NSURLSessionConfiguration`; updates replace sessions while old tasks can
finish on old sessions. Navigation delegate callbacks cannot atomically attach
a top-level identity to every subresource, redirect, frame, worker and concurrent
request. The existing loopback gate sees opaque SOCKS bytes and destination
addresses, not the initiating top-level site. Destination-domain matching or
TLS/SOCKS interception would not reconstruct that missing context reliably.

Consequently this change does not mutate proxy credentials on navigation, add
destination bypass lists, copy cookies between stores, or intercept HTTPS.
Keeping ON is the safest supported choice. OFF is an explicit compatibility
tradeoff for shared logins/data and shared circuits, not a Desktop-equivalence
claim. Desktop's nominal ten-minute credential rotation is not implemented:
there is no equivalent per-site request hook here, and rotating a shared store
would affect every live OFF tab. Tor's own circuit ageing remains independent.

Sources inspected:

- [Brave Desktop proxy authorization](https://github.com/brave/brave-core/blob/master/net/proxy_resolution/proxy_config_service_tor.cc)
- [Apple proxy credentials](https://developer.apple.com/documentation/network/proxyconfiguration/applycredential(username:password:))
- [WebKit data-store proxy contract](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebsiteDataStore.h)
- [WebKit Cocoa network session](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/NetworkProcess/cocoa/NetworkSessionCocoa.mm)

## Validation and build paths

The reusable `iOS Tor prototype` workflow compiles/tests the native Tor/WebKit
package and the actual `TorTabState` against Brave's real tab protocols, with
small Profile/string/disabled-download test doubles. It checks both storage modes and retained
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
6. For both setting values, test cookies, LocalStorage and IndexedDB from two
   same-origin Tor tabs. ON must isolate them; OFF must share them. Verify with
   actual regular/private Brave tabs that neither can read either Tor context.
7. Exercise OFF -> ON -> OFF with tabs coexisting; recreate a web view; close
   one/all shared tabs; undo closing; close during creation. Closing the last
   shared tab and force-quitting/relaunching the app must lose shared data,
   including cookies with future expiry dates. Keep an ON tab open when testing
   last-OFF-tab closure so runtime lifetime cannot mask retention bugs.
8. Inspect SOCKS authentication identities rather than exit addresses. ON tabs
   must differ; OFF tabs in a shared session must match, even on different
   websites. Repeat route/background recovery and confirm no direct/DNS fallback.

Focused tests cover API-level cookie boundaries (including ordinary WebKit
stores), mixed-mode contexts, explicit retirement, owner boundaries and queued
creation. The SOCKS stub records actual username/password bytes through the
unchanged gate and serves a reserved `.invalid` origin for cookie/LocalStorage/
IndexedDB checks. Native tab-contract tests cover recreation, close/undo and
mode snapshots. A fresh session owner tests the storage construction path for
relaunch; it does not substitute for an actual process-restart/device test.

The refinement's full-app build and device acceptance remain unverified until
their actual results are recorded. This implementation does not provide
Tor Browser-equivalent fingerprinting protection.

## Native Tor new tab page

Tor tabs display the existing native private new tab page, retained in a separate
tab-data slot without installing Chromium browser helpers. The New Tab Page
preferences control the Privacy Hub widget, local backgrounds and favorites.
The Privacy Hub detail view remains disabled as in ordinary private browsing;
its displayed totals are Brave's existing global statistics, not Tor measurements.

Tor backgrounds use local image files and never request sponsored placements.
Favorites use cached icons or a placeholder without starting native favicon
requests. Brave News loads and shortcut donations are disabled for Tor.
Website requests still use the Tor tab's ephemeral proxied WebKit store.

On-device checks: open multiple Tor new tabs while disconnected; toggle the
Privacy Hub, background and favorites preferences; switch tab groups; open a
favorite and verify the destination stays in Tor. Check there are no favicon,
news or sponsored-ad requests when opening the page. The tab-contract test
covers the new-tab URL surviving blank-document creation and web-view recreation.

## Tor link menus and previews

Tor link long-press menus use custom actions for opening a new Tor tab, copying
the URL, copying a clean URL, sharing link text, and toggling Brave's existing
link-preview preference. Sharing supplies text and local metadata without a
URL item or metadata fetch. Selecting an external share destination hands the
text to that app; its behavior is outside Tor's routing guarantees. Tapping a preview
loads its link in the source Tor tab. New tabs are explicitly created as Tor tabs
even if the active browsing group changes while a menu is open.

The preview is a separate TorTabState using the source tab's frozen isolation
mode and TorBrowsingSession. It uses the same fail-closed SOCKS gate, nonpersistent
store policy, UTC process pool, destination restrictions, and media/download
blocks. With tab isolation ON it has a fresh storage context and SOCKS identity;
with isolation OFF it joins that Tor session's shared store. It never creates
a Chromium preview, LinkPresentation fetch, Quick Look download, or native URL
session. Dismissal, source web-view deletion, and source closure release its
context and detach its Tor runtime client.

The WKUIDelegate implementation uses the completion-handler selector explicitly.
The previous async method incorrectly used `contextMenuConfigurationForElement`
instead of the SDK's async label `contextMenuConfigurationFor`; WebKit did not
recognize it and could fall back to its native menu and unproxied preview loader.
The corrected callback always returns a custom non-nil configuration, with an
explicit preview provider even when previews are disabled or a link is rejected.

The contract tests check the actual Objective-C delegate selectors, storage
boundaries, proxy failover, blocked destinations and cleanup when the source
closes. On-device validation is still required for
long-press presentation, redirects and subresources through Tor, hide/show preview,
preview tap, background-tab creation, dismissal and reconnect behavior.

## Onion-Location

All tab modes inspect the main-frame HTTP response already received by their
existing browsing session; Tor tabs receive that response through Tor.
Following Desktop's policy, successful HTTPS responses from non-onion sites
can advertise an absolute HTTP(S) onion URL in the Onion-Location header.
Credentials, whitespace, other schemes and non-onion destinations are rejected.
The advertised URL is exposed only after a matching main-frame commit; new
navigations and web-view deletion clear it. Subframes cannot set the action.

The URL bar uses Desktop's Leo product Tor icon immediately before reload.
Tapping opens and selects a new Tor tab through addTorTab; detection itself
never resolves or fetches the onion destination. The action is available in
regular, private and Tor tabs. Entering Tor from a regular tab respects the
private-browsing lock, and always creates a Tor tab with its own Tor storage
policy rather than reusing the source tab's data store. The icon uses a small
symbol size while preserving its full tap target.
HTML meta tags are not scanned, matching Desktop's header implementation.
A back-forward cache restore without response headers requires a reload to
rediscover the advertised URL.

Tests cover header validation, frame and commit boundaries, and cleanup.
Device checks: visit an HTTPS site advertising Onion-Location, tap the icon,
verify the new tab stays in Tor, navigate away, switch tab groups and confirm
the icon follows the selected tab. Verify placement and VoiceOver on phone and
iPad, and test the private-browsing lock when opening from regular mode.
