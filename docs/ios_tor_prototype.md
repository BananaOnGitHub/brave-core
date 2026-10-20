# Embedded Tor prototype for iOS

## Goal

Run Tor inside Brave without Network Extension entitlements or an iOS VPN
profile. Prevent destination DNS from escaping Tor. A different public IP on a
test page is insufficient evidence of containment.

The finished browsing mode should support ordinary websites and JavaScript,
like desktop Brave's Tor mode. Default-off JavaScript is a temporary setting of
this developer test prototype, not the intended production default.

Base: `279f12a02cbfd9d2b340ce1a3c248e63c808e87b`.

## Plan and implementation

1. **Isolate browsing.** Add a developer-only browsing screen in Brave, backed by
   a separate nonpersistent WebKit data store. Do not attach ordinary tab
   services until they have Tor-aware networking.
2. **Embed Tor.** Link the C Tor XCFramework, start offline on a native thread,
   and control it through an owning socket pair. Bind SOCKS only to numeric
   IPv4 loopback. Expose no TCP control listener.
3. **Require protections before browsing.** Compile native content rules before
   enabling Tor networking. Require bootstrap 100%, an established circuit,
   and a validated SOCKS listener before creating the web view. Disable direct
   proxy failover. Pass hostnames through SOCKS5; configure Tor SafeSocks and
   stream isolation.
4. **Contain lifecycle failures.** Destroy the browsing surface before
   suspension, path changes, control failure, or leaving the screen. Serialize
   pending suspension before reconnecting. Keep the proxy attached until the
   web view is destroyed.
5. **Validate independently.** Test the embedded runtime offline on macOS and
   WebKit configuration on the iOS simulator. Provide a small device harness
   that does not need Chromium. Perform the device DNS matrix below before
   broadening features.

## Trying the prototype

### In Brave

Build the fork using the existing iOS instructions in
[`ios/brave-ios/README.md`](../ios/brave-ios/README.md).
Open **Settings > Developer Options > Tor prototype**.
Select Connect, wait for connection, enter a hostname and select Go.
Check Tor opens the Tor Project check page only after connection.

This screen is deliberately separate from the ordinary tab tray. It does not
yet inherit Brave Shields, history, Sync, suggestions, favicons, link previews,
sharing, or download services. Normal/private Brave tabs are not Tor tabs.
Do not enter a sensitive destination in the ordinary address bar.

### Lightweight test app

The package in [`ios/tor`](../ios/tor) has no Chromium dependency.

On a Mac with Xcode and XcodeGen:

```sh
cd ios/tor
swift test
cd Harness
xcodegen generate
open BraveTorPrototype.xcodeproj
```

Set signing for your device in Xcode and run. The standalone app uses the same
runtime, policy, and controller as the Brave integration. It is a test harness,
not a rebuilt Brave IPA.

The `iOS Tor prototype` GitHub Actions workflow uses a sparse checkout of only
this package, runs offline/runtime and simulator tests, and builds an unsigned
device harness IPA. Forks may need Actions enabled in GitHub. The artifact
requires signing before installation. The workflow does not build all of Brave.

Downloads are individual files: `BraveTorPrototype-unsigned.ipa` and
`package-report.json`. The workflow uses pinned `actions/upload-artifact` v7 with
`archive: false` and one file per upload, so downloading the IPA does not add an
outer ZIP. Direct links appear in the workflow summary. CI uses the Xcode 27
runner and selects the simulator matching the active iOS SDK. Simulator boot is
explicit and native test-result bundles are retained for diagnosis.

The IPA is packaged from an unsigned Release archive, with explicit version/build
metadata. The packager validates device architecture, Mach-O platform, executable
permissions and ZIP layout. It removes Xcode's copied codeless static Tor framework
only after checking that the executable has no dynamic Tor framework dependency;
the pinned Tor code is already statically linked. Unexpected framework resources
or remaining versioned bundles fail packaging. A JSON package report accompanies
the IPA. This checks packaging, not certificate validity or physical installation.

For ESign, download the IPA directly, import it, sign with a valid
certificate and provisioning profile for your device, then install the newly
signed copy. The unsigned IPA itself cannot be installed. A generic installation
error may also require device installation logs to distinguish packaging,
provisioning, certificate revocation and installation-service failures.

### JavaScript and checker testing

Build 4 adds **JavaScript (test)** and **Mullvad check** controls. JavaScript starts
off for each newly created prototype screen and is not persisted in preferences.
Changing it immediately tears down the current web view and requires Connect
again, creating a fresh ephemeral browsing session with the selected setting.
The same choice is applied to the initial configuration and navigation policy.

To test on a device:

1. Enable **JavaScript (test)**, then select **Connect**.
2. Wait for **Connected through Tor**, then select **Mullvad check**.
3. Record the visible exit IP, DNS resolver addresses, and WebRTC results.
   Mullvad's VPN status is not the pass criterion for a Tor connection.
4. Repeat after Disconnect/Connect and on Wi-Fi and cellular. Changing networks
   must stop browsing and require explicit reconnection.
5. Disable JavaScript and reconnect to compare against the script-disabled mode.

The simulator serves synthetic HTML through a loopback SOCKS server, executes
inline page JavaScript, follows a cross-origin fetch and redirect, and verifies
that all three unresolved hostnames reach SOCKS. A separate test verifies that
page scripts do not run when disabled. These are functional routing tests, not
packet-capture proof against simultaneous DNS or other system bypasses.

## DNS and network containment

- A native content rule blocks WebKit's `ping` resource type, following Onion
  Browser's mitigation for the Mysk DNS-prefetch finding.
- Network monitoring compares reachability, interface identities used by the
  path (including the preferred interface), and gateways. Repeated callbacks and DNS/cost/Low Data Mode metadata
  updates do not disconnect an unchanged route. An initial satisfied path is
  required before Connect. Connectivity loss or route changes still destroy
  the browser and require explicit reconnection; events are consumed in order
  on the main queue. This is route monitoring, not an OS firewall.
- Each web view receives its proxy and protections before creation/loading.
  The only allowed proxy endpoint is one numeric `127.0.0.1` listener.
- `allowFailover` is explicitly false. The proxy is never cleared to recover
  connectivity. No URLSession or custom direct-fetch fallback is used.
- JavaScript is selectable for testing in both initial and per-navigation
  preferences. The prototype starts with it off; the eventual production mode
  is intended to support JavaScript normally. WebKit Lockdown Mode remains
  enabled in either setting. WebAuthn, WebTransport, WebRTC, workers, and other
  script-triggered networking require explicit platform/device verification.
- Media is blocked by content rules; AirPlay/PiP are disabled. Downloads,
  external schemes, local addresses, popout web views, and media permissions
  are rejected. Native link menus and text selection are disabled to avoid
  system sharing/lookup services. Target-blank links reuse the protected view.
- The prototype never makes an app-side destination DNS query. A DNS packet
  capture is still required to verify the platform does not bypass this design.
- This is an application proxy, not an OS firewall. It does not cover ordinary
  Brave tabs, other apps, or unknown WebKit/system bypasses.

## Device acceptance matrix

Use a controlled domain with authoritative DNS logging and distinct random
labels per case. Observe the device/gateway network, not just the browser UI.
Resolve destination names through Tor; distinguish destination traffic from Tor
bootstrap/relay traffic. Check cellular and Wi-Fi, IPv4 and IPv6 networks, and
the intended iOS releases.

| Trigger | Required outcome |
| --- | --- |
| Top-level page and redirect | Origin observes a Tor exit; destination DNS does not use the device resolver |
| Static HTML `dns-prefetch`, including subframes and HTTP Link headers | No device-resolver query for unique probe labels |
| Images, CSS, fonts, embeds, redirects, target-blank links | Proxied or blocked; no destination DNS outside Tor |
| JavaScript disabled | Inline and external page scripts do not execute |
| JavaScript enabled: script loads, fetch/XHR and redirects | Proxied; no destination DNS outside Tor |
| WebRTC, WebTransport, WebAuthn and worker probes | Blocked or contained; no direct connection or OS credential fetch |
| Media, download, share and external-app navigation attempts | Blocked without handing the destination to another networking service |
| Before bootstrap, Tor/control failure, Disconnect | No page requests or direct fallback |
| Background, lock/unlock, foreground | Browser is torn down; explicit Connect is required |
| Wi-Fi/cellular transition, VPN activation/deactivation, captive portal | Browser is torn down; explicit Connect is required |
| Repeated Connect/Disconnect, close/reopen, concurrent windows | One active C Tor runtime; no stale task reopens a browser |
| New browsing session | Separate ephemeral store and SOCKS isolation credentials |

A device capture and authoritative logs are release blockers. Simulator
configuration tests alone do not prove no leaks.

## Scope and remaining work

- **Prototype only; containment has not been certified on a physical device.**
- JavaScript is available through the prototype testing toggle. Media,
  downloads, link previews and text selection remain disabled.
- No bridge/pluggable-transport UI, circuit display, or per-site new-circuit
  controls. This version uses one isolated browsing surface.
- Full Brave tab integration needs an explicit browsing mode and Tor-aware
  native requests. Existing shared private configurations must not be mutated.
- C Tor allows one active instance per process. A process guard refuses a
  concurrent start; reopening immediately during asynchronous shutdown may
  require retrying. Sequential restarts need device stress testing.
- Browser fingerprinting protections are not equivalent to Tor Browser.
- The attached 1.96 IPA was not inspected or modified: this session did not
  provide a usable shell/Xcode environment. It is not used as a build input.
- The fork's full Brave application has not been built by this lightweight CI.
  Full linking must also check compatibility between the embedded Tor/OpenSSL
  symbols and BraveCore's crypto dependencies.

## Dependency provenance

The SwiftPM binary target pins iCepa Tor.framework release `v409.14.1`,
containing Tor `0.4.9.14`. Its ZIP SHA-256 is
`823d98fcafd8eba089f31b32989ad70e15a0e8a1b5709bc0d5941fb09ef1b625`,
matching both the release asset digest and the upstream podspec. SwiftPM verifies
the archive; no code is downloaded at runtime. This verifies the pinned artifact
identity, not a reproducible source build.

Sources:

- [Brave desktop launcher](https://github.com/brave/brave-core/blob/master/components/services/tor/tor_launcher_impl.cc)
- [Brave desktop proxy isolation](https://github.com/brave/brave-core/blob/master/net/proxy_resolution/proxy_config_service_tor.cc)
- [Tor public embedding API](https://tpo.pages.torproject.net/core/doc/tor/tor__api_8h.html)
- [Tor.framework release](https://github.com/iCepa/Tor.framework/releases/tag/v409.14.1)
- [Onion Browser tab configuration](https://github.com/OnionBrowser/OnionBrowser/blob/3.X/OnionBrowser/Browsing/Tab.swift)
- [Onion Browser DNS mitigation](https://github.com/OnionBrowser/OnionBrowser/blob/3.X/OnionBrowser/Blocking/ContentRules.swift)
- [WebKit proxy leak research](https://mysk.blog/2026/08/04/webkit-proxy-icloud-private-relay-ip-leak/)
