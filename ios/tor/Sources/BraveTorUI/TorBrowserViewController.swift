// Copyright (c) 2026 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. See https://mozilla.org/MPL/2.0/.
#if os(iOS)
import BraveTor
import Network
import UIKit
import WebKit

/// A separate browsing surface until ordinary Brave tab services are Tor-aware.
@MainActor
public final class TorBrowserViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
  private let runtime: TorRuntime
  private let pathMonitor = NWPathMonitor()
  private let addressField = UITextField()
  private let statusLabel = UILabel()
  private let browserContainer = UIView()
  private let connectButton = UIButton(type: .system)
  private let disconnectButton = UIButton(type: .system)
  private let goButton = UIButton(type: .system)
  private let checkButton = UIButton(type: .system)
  private var webView: WKWebView?
  private var sessionTask: Task<Void, Never>?
  private var suspensionTask: Task<Void, Never>?
  private var generation = 0
  private var browsingAllowed = false
  private var sessionRequested = false
  private var receivedInitialPath = false
  private var appActive = false

  public static var displayName: String { text("Tor prototype") }

  public convenience init() {
    self.init(runtime: TorRuntime())
  }

  public init(runtime: TorRuntime) {
    self.runtime = runtime
    super.init(nibName: nil, bundle: nil)
    title = Self.displayName
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError()
  }

  deinit {
    sessionTask?.cancel()
    pathMonitor.cancel()
    NotificationCenter.default.removeObserver(self)
  }

  public override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    appActive = UIApplication.shared.applicationState == .active

    addressField.borderStyle = .roundedRect
    addressField.placeholder = Self.text("Enter a website address")
    addressField.accessibilityLabel = Self.text("Website address")
    addressField.accessibilityIdentifier = "TorPrototype.address"
    addressField.keyboardType = .URL
    addressField.autocapitalizationType = .none
    addressField.autocorrectionType = .no
    addressField.spellCheckingType = .no
    addressField.smartDashesType = .no
    addressField.smartQuotesType = .no
    addressField.returnKeyType = .go
    addressField.addTarget(self, action: #selector(openAddress), for: .editingDidEndOnExit)
    addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)

    statusLabel.font = .preferredFont(forTextStyle: .subheadline)
    statusLabel.adjustsFontForContentSizeCategory = true
    statusLabel.numberOfLines = 0
    statusLabel.accessibilityIdentifier = "TorPrototype.status"
    statusLabel.text = Self.text("Disconnected")

    configure(connectButton, title: "Connect", action: #selector(connect))
    configure(disconnectButton, title: "Disconnect", action: #selector(disconnectTapped))
    configure(goButton, title: "Go", action: #selector(openAddress))
    configure(checkButton, title: "Check Tor", action: #selector(checkTor))
    goButton.isEnabled = false
    checkButton.isEnabled = false

    let controls = UIStackView(arrangedSubviews: [connectButton, disconnectButton, checkButton])
    controls.spacing = 12
    controls.distribution = .fillEqually
    let address = UIStackView(arrangedSubviews: [addressField, goButton])
    address.spacing = 8
    let explanation = UILabel()
    explanation.text = Self.text("Experimental. JavaScript, media, and downloads are disabled.")
    explanation.font = .preferredFont(forTextStyle: .footnote)
    explanation.adjustsFontForContentSizeCategory = true
    explanation.textColor = .secondaryLabel
    explanation.numberOfLines = 0

    let stack = UIStackView(arrangedSubviews: [
      controls, statusLabel, address, explanation, browserContainer,
    ])
    stack.axis = .vertical
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
    ])

    NotificationCenter.default.addObserver(
      self, selector: #selector(willResignActive),
      name: UIApplication.willResignActiveNotification, object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(didBecomeActive),
      name: UIApplication.didBecomeActiveNotification, object: nil
    )
    pathMonitor.pathUpdateHandler = { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if !self.receivedInitialPath {
          self.receivedInitialPath = true
        } else if self.sessionRequested {
          self.disconnect(message: Self.text("Network changed. Connect again."))
        }
      }
    }
    pathMonitor.start(queue: DispatchQueue(label: "brave.tor.path"))
  }

  public override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    disconnect(message: Self.text("Disconnected"))
  }

  private func configure(_ button: UIButton, title: String, action: Selector) {
    button.setTitle(Self.text(title), for: .normal)
    button.titleLabel?.font = .preferredFont(forTextStyle: .body)
    button.titleLabel?.adjustsFontForContentSizeCategory = true
    button.accessibilityLabel = Self.text(title)
    button.addTarget(self, action: action, for: .touchUpInside)
  }

  @objc private func connect() {
    guard appActive else { return }
    disconnect(message: Self.text("Preparing privacy protections…"))
    sessionRequested = true
    connectButton.isEnabled = false
    let expectedGeneration = generation
    let pendingSuspension = suspensionTask
    let runtime = runtime
    sessionTask = Task { [weak self] in
      do {
        await pendingSuspension?.value
        try Task.checkCancellation()
        let rules = try await TorWebPolicy.compileRules()
        guard let self, !Task.isCancelled, self.generation == expectedGeneration,
          self.appActive else { return }
        try await runtime.connect()
        while !Task.isCancelled {
          let snapshot = try await runtime.snapshot()
          guard self.generation == expectedGeneration, self.appActive else { return }
          if snapshot.progress == 100, snapshot.circuitEstablished,
            let endpoint = snapshot.endpoint {
            if self.webView == nil {
              self.installBrowser(endpoint: endpoint, rules: rules)
            }
            self.browsingAllowed = true
            self.goButton.isEnabled = true
            self.checkButton.isEnabled = true
            self.statusLabel.text = Self.text("Connected through Tor")
          } else {
            self.removeBrowser()
            self.statusLabel.text = String(
              format: Self.text("Connecting to Tor: %ld%%"), snapshot.progress
            )
          }
          // Sample bootstrap/control health without a busy loop. No web
          // navigation is allowed while bootstrap or circuit checks fail.
          try await Task.sleep(nanoseconds: 500_000_000)
        }
      } catch is CancellationError {
        return
      } catch {
        guard let self, self.generation == expectedGeneration else { return }
        self.disconnect(message: Self.text("Connection failed. Connect again to retry."))
      }
    }
  }

  @objc private func disconnectTapped() {
    disconnect(message: Self.text("Disconnected"))
  }

  private func disconnect(message: String) {
    generation += 1
    sessionRequested = false
    let previousSession = sessionTask
    previousSession?.cancel()
    sessionTask = nil
    removeBrowser()
    connectButton.isEnabled = true
    statusLabel.text = message
    let runtime = runtime
    let previousSuspension = suspensionTask
    suspensionTask = Task {
      await previousSuspension?.value
      await previousSession?.value
      await runtime.suspend()
    }
  }

  private func removeBrowser() {
    browsingAllowed = false
    goButton.isEnabled = false
    checkButton.isEnabled = false
    // Never remove the proxy to recover connectivity. Destroy this web view
    // while its data store still has its non-failing-over Tor configuration.
    webView?.stopLoading()
    webView?.navigationDelegate = nil
    webView?.uiDelegate = nil
    webView?.removeFromSuperview()
    webView = nil
  }

  private func installBrowser(endpoint: TorEndpoint, rules: WKContentRuleList) {
    let configuration = TorWebPolicy.configuration(
      endpoint: endpoint, rules: rules, isolationID: UUID().uuidString
    )
    let browser = WKWebView(frame: .zero, configuration: configuration)
    browser.allowsLinkPreview = false
    browser.navigationDelegate = self
    browser.uiDelegate = self
    browser.translatesAutoresizingMaskIntoConstraints = false
    browserContainer.addSubview(browser)
    NSLayoutConstraint.activate([
      browser.leadingAnchor.constraint(equalTo: browserContainer.leadingAnchor),
      browser.trailingAnchor.constraint(equalTo: browserContainer.trailingAnchor),
      browser.topAnchor.constraint(equalTo: browserContainer.topAnchor),
      browser.bottomAnchor.constraint(equalTo: browserContainer.bottomAnchor),
    ])
    webView = browser
  }

  @objc private func openAddress() {
    guard browsingAllowed else { return }
    do {
      let url = try TorDestination.url(from: addressField.text ?? "")
      addressField.resignFirstResponder()
      webView?.load(URLRequest(url: url))
    } catch {
      statusLabel.text = Self.text("Enter an HTTP or HTTPS hostname. Local addresses are blocked.")
    }
  }

  @objc private func checkTor() {
    guard browsingAllowed else { return }
    addressField.text = "https://check.torproject.org/"
    openAddress()
  }

  @objc private func willResignActive() {
    appActive = false
    disconnect(message: Self.text("Browsing paused. Connect again when ready."))
  }

  @objc private func didBecomeActive() {
    appActive = true
  }

  public func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    preferences: WKWebpagePreferences,
    decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
  ) {
    preferences.allowsContentJavaScript = false
    preferences.isLockdownModeEnabled = true
    guard browsingAllowed, !navigationAction.shouldPerformDownload,
      let url = navigationAction.request.url, TorDestination.isAllowed(url)
    else {
      decisionHandler(.cancel, preferences)
      return
    }
    decisionHandler(.allow, preferences)
  }

  public func webView(
    _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
  ) {
    let mime = navigationResponse.response.mimeType?.lowercased() ?? ""
    let isMedia = mime.hasPrefix("audio/") || mime.hasPrefix("video/")
    decisionHandler(
      browsingAllowed && navigationResponse.canShowMIMEType && !isMedia ? .allow : .cancel
    )
  }

  public func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    // Target-blank links stay in the already protected browsing surface.
    if browsingAllowed, let url = navigationAction.request.url, TorDestination.isAllowed(url) {
      webView.load(navigationAction.request)
    }
    return nil
  }

  public func webView(
    _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
    decisionHandler: @escaping (WKPermissionDecision) -> Void
  ) {
    decisionHandler(.deny)
  }

  public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    addressField.text = webView.url?.absoluteString
  }

  public func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    statusLabel.text = Self.text("Page could not load through Tor.")
  }

  public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    disconnect(message: Self.text("Page process stopped. Connect again."))
  }

  private static func text(_ key: String) -> String {
    NSLocalizedString(key, bundle: .module, comment: "Tor prototype")
  }
}
#endif
