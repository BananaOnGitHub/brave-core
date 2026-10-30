// Copyright (c) 2026 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the Mozilla Public
// License, v. 2.0. See https://mozilla.org/MPL/2.0/.
import BraveCore
import BraveStrings
import BraveTor
import BraveTorUI
import FaviconModels
import Foundation
import UIKit
import WebKit

/// A native tab without Chromium's auxiliary network services. All page traffic
/// stays on its immutable loopback proxy, including while Tor reconnects.
@MainActor
public final class TorTabState: NSObject, TabState, WKNavigationDelegate, WKUIDelegate {
  public let id: UUID
  public let profile: any Profile
  public var data = TabDataValues()
  public weak var delegate: TabDelegate?
  public weak var downloadDelegate: TabDownloadDelegate?
  public weak var opener: (any TabState)?
  private let container = UIView()
  private let browserContainer = UIView()
  private let status = UILabel()
  private let session: TorBrowsingSession
  private let keepTabsSeparate: Bool
  private var tabSession: TorTabSession?
  private var creationGeneration = 0
  private var browser: WKWebView?
  private weak var activeLinkPreview: TorLinkPreviewController?
  private var creationTask: Task<Void, Never>?
  private var observations: [NSKeyValueObservation] = []
  private var observers: [AnyTabObserver] = []
  private var deciders: [AnyTabPolicyDecider] = []
  private var pendingRequest: URLRequest?
  private var virtualURL: URL?
  private var initialURL: URL?
  private var proxy: TorWebViewProxy?
  private var registered = false
  private var protectionsUnavailable = false
  public private(set) var previewImage: UIImage?
  public private(set) var faviconImage: UIImage?
  public var onVisualsUpdated: (() -> Void)?
  private var faviconTask: Task<Void, Never>?
  private var visualGeneration = 0
  public private(set) var lastCommittedURL: URL?
  public private(set) var previousCommittedURL: URL?
  public private(set) var contentsMimeType: String?
  public private(set) var lastActiveTime: Date?

  public init(
    id: UUID, profile: any Profile, session: TorBrowsingSession,
    keepTabsSeparate: Bool = true
  ) {
    precondition(profile.isOffTheRecord)
    self.id = id
    self.profile = profile
    self.session = session
    self.keepTabsSeparate = keepTabsSeparate
    self.tabSession = session.openTabSession(keepTabsSeparate: keepTabsSeparate)
    super.init()
    container.backgroundColor = .systemBackground
    status.font = .preferredFont(forTextStyle: .caption1)
    status.textColor = .label
    status.backgroundColor = .secondarySystemBackground
    status.adjustsFontForContentSizeCategory = true
    status.numberOfLines = 0
    status.textAlignment = .center
    status.accessibilityIdentifier = "Tor.connectionStatus"
    let stack = UIStackView(arrangedSubviews: [status, browserContainer])
    stack.axis = .vertical
    stack.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      stack.topAnchor.constraint(equalTo: container.topAnchor),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
  }

  isolated deinit {
    faviconTask?.cancel()
    creationTask?.cancel()
    if let tabSession { session.closeTabSession(tabSession) }
    session.detach(id: id)
    observers.forEach { $0.tabWillBeDestroyed(self) }
  }

  public var view: UIView { container }
  public var isVisible = false {
    didSet {
      if isVisible { lastActiveTime = Date() }
      if !isVisible { refreshPreview() }
      observers.forEach { isVisible ? $0.tabWasShown(self) : $0.tabWasHidden(self) }
    }
  }
  public var webViewProxy: (any WebViewProxy)? { proxy }
  public var isWebViewCreated: Bool { browser != nil }
  public var configuration: WKWebViewConfiguration? { browser?.configuration }
  public var torDataStore: WKWebsiteDataStore? { tabSession?.websiteDataStore }

  public func sharesBrowsingData(with other: TorTabState) -> Bool {
    guard let tabSession, let otherSession = other.tabSession else { return false }
    return tabSession.sharesBrowsingData(with: otherSession)
  }

  public func createWebView() {
    guard browser == nil, creationTask == nil else { return }
    let tabSession = self.tabSession ?? session.openTabSession(keepTabsSeparate: keepTabsSeparate)
    self.tabSession = tabSession
    creationGeneration += 1
    let generation = creationGeneration
    protectionsUnavailable = false
    if !registered {
      registered = true
      session.attach(id: id) { [weak self] state in self?.connectionChanged(state) }
    }
    creationTask = Task { [weak self, session, tabSession] in
      do {
        let configuration = try await session.configuration(for: tabSession)
        guard let self, !Task.isCancelled, creationGeneration == generation else { return }
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.tintColor = .systemBlue
        browser.navigationDelegate = self
        browser.uiDelegate = self
        browser.allowsBackForwardNavigationGestures = true
        browser.allowsLinkPreview = true
        browser.translatesAutoresizingMaskIntoConstraints = false
        browserContainer.addSubview(browser)
        NSLayoutConstraint.activate([
          browser.leadingAnchor.constraint(equalTo: browserContainer.leadingAnchor),
          browser.trailingAnchor.constraint(equalTo: browserContainer.trailingAnchor),
          browser.topAnchor.constraint(equalTo: browserContainer.topAnchor),
          browser.bottomAnchor.constraint(equalTo: browserContainer.bottomAnchor),
        ])
        self.browser = browser
        proxy = TorWebViewProxy(browser)
        observe(browser)
        browser.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
        observers.forEach { $0.tabDidCreateWebView(self) }
        flushPendingRequest()
      } catch {
        guard let self, !Task.isCancelled, creationGeneration == generation else { return }
        protectionsUnavailable = true
        status.text = Strings.Tor.utcUnavailable
        session.detach(id: id)
        registered = false
        observers.forEach { $0.tabDidStopLoading(self) }
      }
      if self?.creationGeneration == generation { self?.creationTask = nil }
    }
  }

  public func deleteWebView() {
    activeLinkPreview?.close()
    activeLinkPreview = nil
    clearVisuals()
    creationGeneration += 1
    session.detach(id: id)
    registered = false
    creationTask?.cancel()
    creationTask = nil
    observers.forEach { $0.tabWillDeleteWebView(self) }
    observations.removeAll()
    browser?.navigationDelegate = nil
    browser?.uiDelegate = nil
    browser?.stopLoading()
    browser?.removeFromSuperview()
    browser = nil
    proxy = nil
  }

  /// Closing releases browsing data even when another object retains this tab
  /// for undo. Recreating only the web view keeps the original browsing context.
  public func close() {
    deleteWebView()
    if let tabSession { session.closeTabSession(tabSession) }
    tabSession = nil
  }

  private func connectionChanged(_ state: TorBrowsingSession.State) {
    guard !protectionsUnavailable else { return }
    status.text = switch state {
    case .waiting: Strings.Tor.waiting
    case .connecting: Strings.Tor.connecting
    case .connected: Strings.Tor.connected
    case .unavailable: Strings.Tor.unavailable
    }
    if state == .connected { flushPendingRequest() }
  }

  public var visibleURL: URL? {
    let url = virtualURL ?? browser?.url
    return url?.absoluteString == "about:blank" ? nil : url
  }
  public var visibleSecureContentState: SecureContentState {
    guard let browser, let url = lastCommittedURL else { return .unknown }
    return url.scheme == "https" ? (browser.hasOnlySecureContent ? .secure : .mixedContent) : .missingSSL
  }
  public var serverTrust: SecTrust? { browser?.serverTrust }
  public var faviconStatus: FaviconStatus? { nil }
  public var title: String? { browser?.title ?? Strings.Tor.title }
  public var isLoading: Bool {
    !protectionsUnavailable && (creationTask != nil || pendingRequest != nil || browser?.isLoading == true)
  }
  public var estimatedProgress: Double { browser?.estimatedProgress ?? 0 }
  public var canGoBack: Bool { browser?.canGoBack == true }
  public var canGoForward: Bool { browser?.canGoForward == true }
  public var backForwardList: (any BackForwardListProxy)? { browser.map { TorBackForwardList($0.backForwardList) } }
  public var currentInitialURL: URL? { initialURL }
  public var currentUserAgentType: UserAgentType { .mobile }
  // Tor tab URLs and sessions are never written to Brave's session database.
  public var sessionData: Data? { nil }
  public var isRestoring: Bool { false }
  public func restore(using sessionData: Data) throws { throw TabRestorationError.invalidData }

  public func loadRequest(_ request: URLRequest) {
    guard let url = request.url else { return }
    if url.absoluteString == "about://newtab" {
      pendingRequest = nil
      initialURL = nil
      deleteWebView()
      virtualURL = url
      createWebView()
      observers.forEach { $0.tabDidUpdateURL(self) }
      return
    }
    guard TorDestination.isAllowed(url) else { return }
    pendingRequest = request
    virtualURL = url
    initialURL = url
    observers.forEach { $0.tabDidUpdateURL(self) }
    createWebView()
    flushPendingRequest()
  }

  private func flushPendingRequest() {
    guard session.state == .connected, let browser, let request = pendingRequest else { return }
    pendingRequest = nil
    browser.load(request)
  }

  public func setVirtualURL(_ url: URL?) { virtualURL = url }
  public func reload() {
    if browser == nil { createWebView(); return }
    if let browser, browser.url != nil { browser.reload() } else { flushPendingRequest() }
  }
  public func reloadWithUserAgentType(_ userAgentType: UserAgentType) { reload() }
  public func stopLoading() { pendingRequest = nil; browser?.stopLoading() }
  public func goBack() { browser?.goBack() }
  public func goForward() { browser?.goForward() }
  public func goToBackForwardListItem(_ item: any BackForwardListItemProxy) {
    if let item = item as? TorBackForwardList.Item { browser?.go(to: item.item) }
  }
  public var canTakeSnapshot: Bool {
    guard let browser else { return false }
    return !browser.bounds.isEmpty && !protectionsUnavailable
  }

  public func takeSnapshot(rect: CGRect, handler: @escaping (UIImage?) -> Void) {
    guard canTakeSnapshot, let browser else { handler(nil); return }
    let bounds = browser.bounds
    let region = rect.isNull ? bounds : bounds.intersection(rect)
    guard !region.isNull, !region.isEmpty else { handler(nil); return }
    let generation = visualGeneration
    let configuration = WKSnapshotConfiguration()
    configuration.rect = region
    let scale = max(browser.traitCollection.displayScale, 1)
    configuration.snapshotWidth = NSNumber(value: Double(min(region.width, 400 / scale)))
    configuration.afterScreenUpdates = true
    browser.takeSnapshot(with: configuration) { [weak self, weak browser] image, _ in
      guard let self, let browser, self.browser === browser,
        visualGeneration == generation else { handler(nil); return }
      handler(image)
    }
  }

  public func refreshPreview() {
    // Capture only rendered pages. Retain the last good image while suspended;
    // the tab grid must never trigger a reload or a separate network request.
    guard browser?.window != nil else { return }
    takeSnapshot(rect: .null) { [weak self] image in
      guard let self, let image else { return }
      previewImage = image
      onVisualsUpdated?()
    }
  }

  private func clearVisuals() {
    visualGeneration += 1
    faviconTask?.cancel()
    faviconTask = nil
    previewImage = nil
    faviconImage = nil
    onVisualsUpdated?()
  }

  private func loadFavicon() {
    guard let browser, let url = browser.url, TorDestination.isAllowed(url),
      session.state == .connected else { return }
    let generation = visualGeneration
    faviconTask?.cancel()
    faviconTask = Task { [weak self, weak browser] in
      guard let browser else { return }
      let result = try? await browser.callAsyncJavaScript(Self.faviconScript,
        arguments: [:], in: nil, contentWorld: .defaultClient)
      guard let self, !Task.isCancelled, self.browser === browser,
        visualGeneration == generation, browser.url == url,
        let encoded = result as? String, encoded.utf8.count <= 90_000,
        let data = Data(base64Encoded: encoded), let image = UIImage(data: data)
      else { return }
      faviconImage = image
      observers.forEach { $0.tabDidUpdateFaviconStatus(self) }
      onVisualsUpdated?()
    }
  }

  // Same-origin candidates avoid cross-origin canvas/CORS workarounds. All
  // fetches use this web view's ephemeral store and fail-closed SOCKS route.
  static let faviconScript = """
    const candidates = Array.from(document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"]'))
      .map(link => link.href).filter(value => !/\\.svg(?:[?#]|$)/i.test(value)).slice(0, 2);
    candidates.push(new URL('/favicon.ico', location.href).href);
    const urls = [...new Set(candidates)].filter(value => {
      try {
        const url = new URL(value);
        return ['http:', 'https:'].includes(url.protocol) && url.origin === location.origin
          && !url.username && !url.password;
      } catch { return false; }
    }).slice(0, 3);
    for (const url of urls) {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 3000);
      let blobURL;
      try {
        const response = await fetch(url, {signal: controller.signal, credentials: 'same-origin',
          redirect: 'error', cache: 'no-store'});
        if (!response.ok || !response.body) continue;
        const reader = response.body.getReader();
        const chunks = [];
        let length = 0;
        while (true) {
          const chunk = await reader.read();
          if (chunk.done) break;
          length += chunk.value.byteLength;
          if (length > 262144) { await reader.cancel(); throw new Error('icon too large'); }
          chunks.push(chunk.value);
        }
        const type = (response.headers.get('content-type') || '').split(';')[0];
        if (!['image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/x-icon',
          'image/vnd.microsoft.icon', 'image/avif', 'application/octet-stream', ''].includes(type)) continue;
        blobURL = URL.createObjectURL(new Blob(chunks, {type: type || 'image/x-icon'}));
        const image = new Image();
        await new Promise((resolve, reject) => {
          const timeout = setTimeout(() => reject(new Error('icon decode timeout')), 3000);
          image.onload = () => { clearTimeout(timeout); resolve(); };
          image.onerror = () => { clearTimeout(timeout); reject(new Error('invalid icon')); };
          image.src = blobURL;
        });
        const canvas = document.createElement('canvas');
        canvas.width = canvas.height = 64;
        canvas.getContext('2d').drawImage(image, 0, 0, 64, 64);
        return canvas.toDataURL('image/png').split(',')[1];
      } catch {} finally {
        clearTimeout(timer);
        if (blobURL) URL.revokeObjectURL(blobURL);
      }
    }
    return null;
    """
  public func createFullPagePDF() async throws -> Data? { nil }
  public func downloadCurrentPage(to fileURL: URL) async throws { throw URLError(.unsupportedURL) }
  public func suggestedFilenameForCurrentPage(contentDisposition: String?) -> String { "document" }
  public var isFindNavigatorVisible: Bool { browser?.findInteraction?.isFindNavigatorVisible == true }
  public func presentFindInteraction(with text: String) {
    browser?.isFindInteractionEnabled = true
    browser?.findInteraction?.presentFindNavigator(showingReplace: false)
  }
  public func dismissFindInteraction() { browser?.findInteraction?.dismissFindNavigator() }
  public func evaluateJavaScriptUnsafe(_ javascript: String) {}
  public func loadHTMLString(_ htmlString: String, baseURL: URL?) {}
  public func evaluateJavaScript(functionName: String, args: [Any], frame: WKFrameInfo?, contentWorld: WKContentWorld, escapeArgs: Bool, asFunction: Bool) async throws -> Any? {
    try await browser?.evaluateJavaScript(functionName: functionName, args: args, frame: frame, contentWorld: contentWorld, escapeArgs: escapeArgs, asFunction: asFunction)
  }
  public func callAsyncJavaScript(_ functionBody: String, arguments: [String: Any], in frame: WKFrameInfo?, contentWorld: WKContentWorld) async throws -> Any? {
    try await browser?.callAsyncJavaScript(functionBody, arguments: arguments, in: frame, contentWorld: contentWorld)
  }
  public var dataForDisplayedPDF: Data? { nil }
  public var sampledPageTopColor: UIColor? { nil }
  public var viewScale: CGFloat {
    get { browser?.pageZoom ?? 1 }
    set { browser?.pageZoom = newValue }
  }
  public func clearBackForwardList() {}
  public func pauseAllMediaPlayback() { browser?.pauseAllMediaPlayback(completionHandler: nil) }
  public func requestMediaPlaybackState() async -> MediaPlaybackState { .none }
  public func updateScripts() {}

  public func addObserver(_ observer: some TabObserver) {
    if !observers.contains(where: { $0.id == ObjectIdentifier(observer) }) { observers.append(.init(observer)) }
  }
  public func removeObserver(_ observer: some TabObserver) { observers.removeAll { $0.id == ObjectIdentifier(observer) } }
  public func addPolicyDecider(_ policyDecider: some TabPolicyDecider) { deciders.append(.init(policyDecider)) }
  public func removePolicyDecider(_ policyDecider: some TabPolicyDecider) { deciders.removeAll { $0.id == ObjectIdentifier(policyDecider) } }

  private func observe(_ browser: WKWebView) {
    observations = [
      browser.observe(\.url) { [weak self] browser, _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          guard self.virtualURL?.absoluteString != "about://newtab" else { return }
          if browser.url?.absoluteString == "about:blank" {
            // Keep a queued destination visible while its blank document loads.
            if self.virtualURL == nil { self.virtualURL = URL(string: "about://newtab") }
          } else {
            self.virtualURL = nil
          }
          self.observers.forEach { $0.tabDidUpdateURL(self) }
        }
      },
      browser.observe(\.title) { [weak self] _, _ in
        MainActor.assumeIsolated { guard let self else { return }; self.observers.forEach { $0.tabDidChangeTitle(self) } }
      },
      browser.observe(\.estimatedProgress) { [weak self] _, _ in
        MainActor.assumeIsolated { guard let self else { return }; self.observers.forEach { $0.tabDidChangeLoadProgress(self) } }
      },
      browser.observe(\.isLoading) { [weak self] browser, _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.observers.forEach { browser.isLoading ? $0.tabDidStartLoading(self) : $0.tabDidStopLoading(self) }
        }
      },
      browser.observe(\.canGoBack) { [weak self] _, _ in
        MainActor.assumeIsolated { guard let self else { return }; self.observers.forEach { $0.tabDidChangeBackForwardState(self) } }
      },
      browser.observe(\.canGoForward) { [weak self] _, _ in
        MainActor.assumeIsolated { guard let self else { return }; self.observers.forEach { $0.tabDidChangeBackForwardState(self) } }
      },
    ]
  }

  public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
    TorWebPolicy.applyPagePreferences(preferences, javaScriptEnabled: true)
    guard !action.shouldPerformDownload, let url = action.request.url else { return (.cancel, preferences) }
    if url.absoluteString == "about:blank" || (url.absoluteString == "about:srcdoc" && action.targetFrame?.isMainFrame == false) {
      return (.allow, preferences)
    }
    guard TorDestination.isAllowed(url) else { return (.cancel, preferences) }
    let info = WebRequestInfo(
      navigationType: WebNavigationType(rawValue: action.navigationType.rawValue) ?? .other,
      isMainFrame: action.targetFrame?.isMainFrame ?? true,
      isNewWindow: action.targetFrame == nil, isUserInitiated: action.navigationType == .linkActivated,
      isCrossOriginFrame: !action.sourceFrame.isMainFrame, isCrossOriginWindow: false,
      hasUserTappedRecently: action.navigationType == .linkActivated
    )
    for decider in deciders {
      if await decider.tab(self, shouldAllowRequest: action.request, requestInfo: info) == .cancel { return (.cancel, preferences) }
    }
    return (.allow, preferences)
  }
  public func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
    let mime = response.response.mimeType?.lowercased() ?? ""
    guard response.canShowMIMEType, !mime.hasPrefix("audio/"), !mime.hasPrefix("video/") else { return .cancel }
    for decider in deciders {
      if await decider.tab(self, shouldAllowResponse: response.response, responseInfo: .init(isForMainFrame: response.isForMainFrame)) == .cancel { return .cancel }
    }
    if response.isForMainFrame { contentsMimeType = mime }
    return .allow
  }
  public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { observers.forEach { $0.tabDidStartNavigation(self) } }
  public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    guard webView.url?.absoluteString != "about:blank" else { return }
    clearVisuals()
    previousCommittedURL = lastCommittedURL
    lastCommittedURL = webView.url
    observers.forEach { $0.tabDidCommitNavigation(self); $0.tabDidChangeVisibleSecurityState(self) }
  }
  public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    observers.forEach { $0.tabDidFinishNavigation(self) }
    refreshPreview()
    loadFavicon()
  }
  public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { observers.forEach { $0.tab(self, didFailNavigationWithError: error) } }
  public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { observers.forEach { $0.tabRenderProcessDidTerminate(self) } }
  public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    guard action.navigationType == .linkActivated, let url = action.request.url, TorDestination.isAllowed(url) else { return nil }
    if let tab = delegate?.tab(self, createTabForOpeningURL: url, inBackground: false), tab is TorTabState { tab.loadRequest(action.request) }
    return nil
  }
  public func makeLinkPreview(for url: URL) -> UIViewController? {
    guard tabSession != nil, TorDestination.isAllowed(url) else { return nil }
    activeLinkPreview?.close()
    let controller = TorLinkPreviewController(
      url: url, tab: TorTabState(
        id: UUID(), profile: profile, session: session, keepTabsSeparate: keepTabsSeparate
      )
    )
    activeLinkPreview = controller
    return controller
  }

  public func webView(
    _ webView: WKWebView,
    contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
    completionHandler: @escaping @MainActor @Sendable (UIContextMenuConfiguration?) -> Void
  ) {
    // Use the Objective-C delegate entry point; the async import has a different label.
    // A non-nil empty configuration prevents WebKit's unproxied default link preview.
    let empty = UIContextMenuConfiguration(
      identifier: nil, previewProvider: { nil }, actionProvider: { _ in UIMenu(children: []) }
    )
    guard let url = elementInfo.linkURL, TorDestination.isAllowed(url), let delegate else {
      completionHandler(empty)
      return
    }
    Task { [weak self, weak webView] in
      guard let self, let webView, self.browser === webView, self.tabSession != nil else {
        completionHandler(empty)
        return
      }
      let configuration = await delegate.tab(self, contextMenuConfigurationForLinkURL: url)
      guard self.browser === webView, self.tabSession != nil else {
        completionHandler(empty)
        return
      }
      completionHandler(configuration ?? empty)
    }
  }

  public func webView(_ webView: WKWebView, contextMenuForElement elementInfo: WKContextMenuElementInfo, willCommitWithAnimator animator: any UIContextMenuInteractionCommitAnimating) {
    guard let url = elementInfo.linkURL, TorDestination.isAllowed(url) else { return }
    delegate?.tab(self, contextMenuWithLinkURL: url, willCommitWithAnimator: animator)
  }

  public func webView(_ webView: WKWebView, contextMenuDidEndForElement elementInfo: WKContextMenuElementInfo) {
    activeLinkPreview?.close()
    activeLinkPreview = nil
  }
  public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision { .deny }
}

extension TabState {
  public var isTor: Bool { self is TorTabState }
}

@MainActor
private final class TorWebViewProxy: WebViewProxy {
  private weak var browser: WKWebView?
  init(_ browser: WKWebView) { self.browser = browser }
  var scrollView: UIScrollView? { browser?.scrollView }
  var bounds: CGRect { browser?.bounds ?? .zero }
  var frame: CGRect { browser?.frame ?? .zero }
  var isKeyboardVisible: Bool { false }
  var obscuredInsets: UIEdgeInsets {
    get { browser?.scrollView.contentInset ?? .zero }
    set { browser?.scrollView.contentInset = newValue }
  }
  func setMinimumViewportInset(_ minInset: UIEdgeInsets, maximumViewportInset: UIEdgeInsets) { obscuredInsets = minInset }
  func becomeFirstResponder() -> Bool { browser?.becomeFirstResponder() ?? false }
}

private struct TorBackForwardList: BackForwardListProxy {
  let list: WKBackForwardList
  init(_ list: WKBackForwardList) { self.list = list }
  var backList: [any BackForwardListItemProxy] { list.backList.map(Item.init) }
  var forwardList: [any BackForwardListItemProxy] { list.forwardList.map(Item.init) }
  var currentItem: (any BackForwardListItemProxy)? { list.currentItem.map(Item.init) }
  var backItem: (any BackForwardListItemProxy)? { list.backItem.map(Item.init) }
  var forwardItem: (any BackForwardListItemProxy)? { list.forwardItem.map(Item.init) }
  struct Item: BackForwardListItemProxy {
    let item: WKBackForwardListItem
    var url: URL { item.url }
    var title: String? { item.title }
  }
}

@MainActor
final class TorLinkPreviewController: UIViewController {
  let previewTab: TorTabState
  private let url: URL

  init(url: URL, tab: TorTabState) {
    self.url = url
    self.previewTab = tab
    super.init(nibName: nil, bundle: nil)
    preferredContentSize = CGSize(width: 390, height: 500)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    previewTab.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(previewTab.view)
    NSLayoutConstraint.activate([
      previewTab.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      previewTab.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      previewTab.view.topAnchor.constraint(equalTo: view.topAnchor),
      previewTab.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    previewTab.loadRequest(URLRequest(url: url))
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    close()
  }

  func close() { previewTab.close() }

  isolated deinit { previewTab.close() }
}
