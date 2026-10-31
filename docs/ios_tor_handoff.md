# Brave iOS Private with Tor — session handoff

User requested a pause because they are out of credits. Resume fixing and validating this integration next session. Do not claim it is installable or validated yet.

## Repository and current work

- Repository: https://github.com/BananaOnGitHub/brave-core
- Branch: `feature/ios-private-with-tor`
- Draft PR: https://github.com/BananaOnGitHub/brave-core/pull/2
- Implementation HEAD before this handoff: `4a370e2572bf1a45a381e43a307b7ca05a995582`.
- Base: validated prototype branch `prototype/ios-embedded-tor`, commit `59a354ae5f20b10a34cb90615a7d3a23bd5c5187`.
- All implementation changes are committed and pushed. The working directory was a partial source tree, not a git checkout. Reconstruct from the branch if scratch files are gone.
- Previous local source path: `/workspace/scratch/0e8ea0d031ba/integration-work`.
- Read root AGENTS.md and .claude/CLAUDE.md. Do not delete caches, SDKs, build output, or machine state outside the repository working tree to make space.
- Do not spawn subagents unless the user explicitly asks.

## User requirements

Integrate the successful embedded Tor prototype into actual Brave on a new branch:
1. Third bottom tab-grid group named **Private with Tor**, reusing private tab layout with multiple tabs and normal Brave toolbars.
2. JavaScript enabled. Default-off applied only to the standalone prototype.
3. Standardize all default JS timezone information to UTC, including Date, Intl, frames and workers.
4. Preserve the WebKit page/session/DOM/form state across network changes; pause forwarding and automatically reconnect. Start Tor automatically when a Tor tab opens.
5. DNS leak prevention is a priority. No OS VPN/Orbot requirement; never fall back to direct networking.
6. Output direct IPA artifacts, without an outer ZIP.

User tested old standalone prototype: Tor checker recognizes exit; BrowserLeaks/CreepJS block most identifiers; WebRTC is blocked. European DNS checker results are consistent with exit-side DNS but do not certify containment. User device: iPhone 16 Pro, iOS 27.0.1, ESign installation.

## Current implementation

- `ios/tor/Sources/BraveTorUI/TorBrowsingSession.swift`: shared embedded runtime, path monitoring, automatic retry, pause on background/route changes; keeps views alive. Injectable `automaticallyConnect:false` for offline tests.
- `TorSOCKSGate.swift`: stable numeric 127.0.0.1 proxy; forwards opaque SOCKS bytes only to ready embedded Tor; queues new sockets during suspension and closes broken active transports. No hostname resolution or direct connection path.
- `TorWebPolicy.swift`: public throwing configuration; independent nonpersistent store/credentials for each tab, no proxy failover, JS on for integrated mode, Lockdown, ping/media blocking and native interaction restrictions.
- `ios/tor/Sources/TorWebKit/`: Objective-C checked WebKit SPI `_WKProcessPoolConfiguration.timeZoneOverride` and `WKProcessPool._initWithConfiguration:`. Mandatory UTC; refuses view creation if unavailable. This is a sideload integration using SPI, not an App Store compatibility claim. Avoid JS monkey-patches.
- `ios/brave-ios/Sources/Web/WebKit/TorTabState.swift`: actual TabState adapter around independent WKWebView, own ephemeral store, native status label; no session persistence, snapshots, native downloads/media/auxiliary services. Queues explicit top-level requests while reconnecting. Same web view survives session reconnect.
- TabManager, PrivateBrowsingManager, TabGridViewModel and TabGridView implement separate regular/private/Tor groups, memory-only Tor tabs, child-tab inheritance, group-specific reorder/close and separate selected indices.
- Tor parents always create Tor children, even if the current global group changed.
- Native BVC observers skip ordinary helpers, scripts, metadata, rewards/history side effects, sharing, previews, Screen Time URL recording. Search UI suppresses suggestions, favorite tiles, voice, playlist/AI results and decentralized address resolution.
- Unsafe auxiliary actions (bookmark-all, shredding, cross-window conversion) are gated for Tor.
- New Strings.Tor entries and docs/ios_tor_integration.md explain behavior/limits.
- Existing Tor framework v409.14.1 is pinned by checksum. Static copied framework bundle is removed only after dynamic-dependency/resource checks, before validation. Actual Client Xcode target has the cleanup phase.
- Full app links embedded Tor/OpenSSL alongside BraveCore; compatibility is still unverified until actual full linking.

## CI — immediate next action

Latest run: https://github.com/BananaOnGitHub/brave-core/actions/runs/39526980192
Latest native job: 118983831130.

Status at pause (raw normalized snapshot):
```json
{"jobs":[{"id":118983831130,"name":"native / validate","status":"in_progress","conclusion":null,"run_id":39526980192,"logs_url":null,"steps":[{"name":"Set up job","status":"completed","conclusion":"success","number":1},{"name":"Run actions/checkout@11d5960a326750d5838078e36cf38b85af677262","status":"completed","conclusion":"success","number":2},{"name":"Identify simulator SDK cache","status":"completed","conclusion":"success","number":3},{"name":"Restore compiler SDK modules","status":"completed","conclusion":"success","number":4},{"name":"Test embedded runtime and protocol without the Tor network","status":"completed","conclusion":"success","number":5},{"name":"Parse Brave tab integration sources","status":"completed","conclusion":"success","number":6},{"name":"Generate lightweight device harness","status":"completed","conclusion":"success","number":7},{"name":"Boot iOS simulator","status":"in_progress","conclusion":null,"number":8},{"name":"Test native WebKit protections","status":"pending","conclusion":null,"number":9},{"name":"Save compiler SDK modules","status":"pending","conclusion":null,"number":10},{"name":"Summarize native test results","status":"pending","conclusion":null,"number":11},{"name":"Save native test diagnostics","status":"pending","conclusion":null,"number":12},{"name":"Archive and validate unsigned Release device app","status":"pending","conclusion":null,"number":13},{"name":"Upload IPA directly","status":"pending","conclusion":null,"number":14},{"name":"Upload package report separately","status":"pending","conclusion":null,"number":15},{"name":"Link direct downloads","status":"pending","conclusion":null,"number":16},{"name":"Post Run actions/checkout@11d5960a326750d5838078e36cf38b85af677262","status":"pending","conclusion":null,"number":32}]}]}
```

Inspect this run next. GitHub job logs are generally unavailable (404 BlobNotFound) until job/post-cleanup completes; they may take another minute to become readable. Avoid repeatedly polling in seconds.

Workflow `.github/workflows/ios-tor-brave.yml` calls reusable native workflow, then initializes Chromium and builds actual ARM64 BraveCore + Client archive. It uploads **BravePrivateTor-unsigned.ipa** directly. Separate bundle prefix com.banana.brave.tor avoids replacing App Store Brave.
The native workflow's **BraveTorPrototype-unsigned.ipa** is ONLY a standalone harness, not the actual integrated Brave app.

Native runs so far:
- 39522118089 / job118968165553: Swift explicit-self errors in session/gate callbacks; fixed.
- 39523497394 / job118972999426: missing handling for throwing UTC configuration in prototype controller; fixed with throws + try inside existing catch.
- 39524936698 / job118977241974: Xcode static contract target lacked transitive SwiftPM Clang module maps; fixed explicit generated TorWebKit/EmbeddedTor module-map flags and header paths in Harness/project.yml.
- 39525832426 / job118980129288: missing TabDownloadDelegate in contract harness; fixed by compiling the real protocol and supplying a minimal disabled Download identity stub.
- Current 39526980192 includes all those fixes.

The last errors were harness build setup, not yet runtime timezone test failures. No native UTC/DOM assertions have passed yet. Expect and fix any further compile/test failures; do not drop security assertions to make CI green.

## Tests and build configuration

Passed repeatedly:
- 7 macOS route-policy tests.
- 4 Tor protocol/destination tests.
- 1 actual embedded Tor startup test with networking disabled.
- 4 Python static-bundle safety tests.
- 3 Python BraveCore cache-key invalidation tests.
- Swift syntax checks on the initial integration sources.

New native tests:
- TorTimeZoneTests: Chicago control pool stays Chicago; protected view Date/Intl/local-date construction, summer/winter offsets, child frame and blob worker all UTC.
- TorSOCKSGateTests: traffic waits while closed, resumes only via loopback upstream, and stable endpoint reopens after pause.
- TorTabStateTests: compile actual adapter against actual Brave tab protocols, separate private stores, proxy failover false, same web view/DOM/form marker retained after reconnect and queued .invalid request. Runtime networking disabled in this test.

Harness/generate_tab_contracts.py omits only unrelated Chromium TabStateFactory from real TabState.swift. Actual TabDelegate, TabDownloadDelegate, TabObserver, TabPolicyDecider and SafeJavaScript are compiled. Profile, strings, favicon module and disabled Download are minimal test doubles. ContractSupport string escaping intentionally traps if tests grow beyond argument-free JS. This does not replace full Brave compilation.

Added three regression tests to existing ClientTests/TabManagerTests.swift: group separation/reorder/persistence, three-way grid switching, and pending-authentication bypass prevention. These require the full app workspace and have NOT run. Current native workflow only syntax-checks this test file, plus relevant BVC/toolbar sources.

Native workflow uses xcode-27 and exact Xcode_27.app, iOS simulator matching SDK. New compiler SDK cache (within checkout) is keyed by exact Xcode/SDK and runner arch. Native tests have 15-min step timeout and bounded individual test execution. Result summarization has 1-min timeout; diagnostics upload has 5-min timeout.

Full workflow:
- checkout into src/brave, pnpm init --target_os=ios --target_arch=arm64 --no-history.
- Disables unneeded clangd and coverage-tools checkout via projects_chrome_custom_vars in .env.
- Builds Release ARM64 device BraveCore with remoteexec=false, GN symbol_level:0 and ninja j:4.
- Caches BraveCore/NalaAssets/PartitionAllocSupport xcframeworks plus args.xcconfig, keyed by all backend git tree entries, exact Xcode/SDK, and full build recipe. Swift-only changes reuse core.
- Bootstraps Swift resources, generates TorCIRelease scheme with documented --only_update_symlink preaction flag to avoid rebuilding already prepared core.
- Archives actual Client.app unsigned; package_ipa.py validates/packages direct IPA.
- Logs are always uploaded.

A previous full init was canceled when a newer commit arrived; it reached Chromium sync without failure. Runner measured 145Gi total, 83Gi used, ~37Gi free. Disk may be a real blocker for Chromium + outputs; wait for evidence, and do not remove preinstalled SDK/cache state outside checkout. No matching public prebuilt BraveCore was found. No paid larger runner has been authorized.

## Remaining verification / next steps

1. Inspect current native job result and logs; fix compile errors, then confirm actual UTC, gate, and retained-DOM assertions.
2. Check minimum deployment targets in Brave package / Client project against Tor package iOS18 requirement. A read of this was interrupted at pause; it has not been verified.
3. Let full BraveCore + app workflow run after native passes. It may take hours. Do not keep pushing cosmetic changes while it downloads/builds, because workflow concurrency cancels obsolete runs.
4. Resolve actual init/disk/compiler/linker/package failures. Verify static Tor cleanup in sandboxed Client phase and Tor/OpenSSL/BraveCore linking.
5. Run actual ClientTests when a simulator BraveCore workspace is available; current full workflow builds device frameworks only.
6. Obtain actual full-app IPA before claiming the integration is installable. Validate on-device group switching, tab creation/reorder/close, UTC with non-UTC phone timezone, route/background transitions retaining forms, and traffic/DNS/IPv6/WebRTC probes.
7. Update PR body with actual validation and remaining limitations, without overstating privacy or Tor Browser equivalence.

User paused voluntarily; save work and stop monitoring now.
