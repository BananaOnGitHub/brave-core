// Copyright (c) 2026 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the Mozilla Public
// License, v. 2.0. See https://mozilla.org/MPL/2.0/.
#if os(iOS)
import BraveTor
import Network
import UIKit
import WebKit

/// One process-wide runtime with independent ephemeral stores and optional
/// per-tab SOCKS isolation. Route changes preserve all tab content.
@MainActor
public final class TorBrowsingSession: NSObject {
  public static let shared = TorBrowsingSession(runtime: TorRuntime(), automaticallyConnect: true)
  public enum State: Equatable { case waiting, connecting(Int), connected, unavailable }
  public private(set) var state: State = .waiting
  private let runtime: TorRuntime
  private let sharedIsolationID = UUID()
  private let automaticallyConnect: Bool
  private let gate = TorSOCKSGate()
  private let monitor = NWPathMonitor()
  private var policy = TorNetworkPolicy()
  private var appActive = false
  private var clients: [UUID: (State) -> Void] = [:]
  private var sessionTask: Task<Void, Never>?
  private var configurationTask: Task<(TorEndpoint, WKContentRuleList), Error>?
  private var generation = 0
  private var transition: Task<Void, Never>?

  public init(runtime: TorRuntime, automaticallyConnect: Bool) {
    self.runtime = runtime
    self.automaticallyConnect = automaticallyConnect
    super.init()
    appActive = UIApplication.shared.applicationState == .active
    monitor.pathUpdateHandler = { [weak self] path in
      MainActor.assumeIsolated {
        guard let self else { return }
        let changed = self.policy.update(TorNetworkPath(path))
        if changed { self.reconnect() } else { self.connectIfNeeded() }
      }
    }
    monitor.start(queue: .main)
    NotificationCenter.default.addObserver(self, selector: #selector(suspend), name: UIApplication.willResignActiveNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(resume), name: UIApplication.didBecomeActiveNotification, object: nil)
  }

  deinit {
    monitor.cancel()
    sessionTask?.cancel()
    NotificationCenter.default.removeObserver(self)
  }

  public func attach(id: UUID, onChange: @escaping (State) -> Void) {
    clients[id] = onChange
    onChange(state)
    connectIfNeeded()
  }

  public func detach(id: UUID) {
    clients.removeValue(forKey: id)
    if clients.isEmpty { pause() }
  }

  func connectionIsolationID(for tabID: UUID, keepTabsSeparate: Bool) -> UUID {
    keepTabsSeparate ? tabID : sharedIsolationID
  }

  public func configuration(
    isolationID: UUID, keepTabsSeparate: Bool = true
  ) async throws -> WKWebViewConfiguration {
    if configurationTask == nil {
      configurationTask = Task { [gate] in
        let endpoint = try await gate.start()
        return (endpoint, try await TorWebPolicy.compileRules())
      }
    }
    guard let configurationTask else { throw TorError.unavailable }
    let (endpoint, rules) = try await configurationTask.value
    return try TorWebPolicy.configuration(
      endpoint: endpoint, rules: rules,
      isolationID: connectionIsolationID(for: isolationID, keepTabsSeparate: keepTabsSeparate).uuidString,
      javaScriptEnabled: true
    )
  }

  private func publish(_ state: State) {
    self.state = state
    for callback in Array(clients.values) { callback(state) }
  }

  private func pause() {
    generation += 1
    sessionTask?.cancel()
    sessionTask = nil
    gate.forward(to: nil)
    publish(.waiting)
    let previous = transition
    transition = Task { [runtime] in
      await previous?.value
      await runtime.suspend()
    }
  }

  public func reconnect() {
    pause()
    connectIfNeeded()
  }

  @objc private func suspend() { appActive = false; pause() }
  @objc private func resume() { appActive = true; connectIfNeeded() }

  private func connectIfNeeded() {
    guard automaticallyConnect, sessionTask == nil, !clients.isEmpty, appActive, policy.canConnect else { return }
    let expected = generation
    let previous = transition
    publish(.connecting(0))
    sessionTask = Task { [weak self] in
      await previous?.value
      guard let self, expected == generation, !Task.isCancelled else { return }
      do {
        try await runtime.connect()
        while !Task.isCancelled, expected == generation {
          let snapshot = try await runtime.snapshot()
          guard expected == generation, !Task.isCancelled else { return }
          if snapshot.progress == 100, snapshot.circuitEstablished, let endpoint = snapshot.endpoint {
            gate.forward(to: endpoint)
            publish(.connected)
          } else {
            gate.forward(to: nil)
            publish(.connecting(snapshot.progress))
          }
          // Poll the private control socket to detect circuit/control failures.
          try await Task.sleep(nanoseconds: 500_000_000)
        }
      } catch {
        guard expected == generation, !Task.isCancelled else { return }
        gate.forward(to: nil)
        publish(.unavailable)
        await runtime.suspend()
        // Back off a failed runtime while retaining the loopback gate and pages.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard expected == generation, !Task.isCancelled else { return }
        sessionTask = nil
        connectIfNeeded()
      }
    }
  }
}
#endif
