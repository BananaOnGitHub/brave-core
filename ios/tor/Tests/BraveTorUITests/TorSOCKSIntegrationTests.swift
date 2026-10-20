// Copyright (c) 2026 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the Mozilla Public
// License, v. 2.0. See https://mozilla.org/MPL/2.0/.
#if os(iOS)
import BraveTor
import Foundation
import Network
import WebKit
import XCTest
@testable import BraveTorUI

@MainActor
final class TorSOCKSIntegrationTests: XCTestCase {
  func testWebKitPassesDestinationHostnameToSOCKS() async throws {
    let ready = expectation(description: "Local SOCKS listener is ready")
    let request = expectation(description: "SOCKS receives the unresolved hostname")
    let server = try SOCKSProbeServer(
      ready: { ready.fulfill() },
      destination: { hostname in
        XCTAssertEqual(hostname, "brave-tor-probe.invalid")
        request.fulfill()
      }
    )
    defer { server.stop() }
    server.start()
    await fulfillment(of: [ready], timeout: 10)
    let port = try XCTUnwrap(server.port)
    let endpoint = try TorEndpoint(listener: "127.0.0.1:\(port)")
    let rules = try await TorWebPolicy.compileRules()
    let configuration = TorWebPolicy.configuration(
      endpoint: endpoint, rules: rules, isolationID: "test-isolation"
    )
    let webView = WKWebView(frame: .zero, configuration: configuration)
    // .invalid is reserved. The local stub rejects the SOCKS connection:
    // this test never contacts the public Tor network or an origin server.
    webView.load(URLRequest(url: URL(string: "http://brave-tor-probe.invalid/")!))
    await fulfillment(of: [request], timeout: 15)
    webView.stopLoading()
  }
}

/// NWConnection callbacks and connection storage are confined to queue.
private final class SOCKSProbeServer: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "brave.tor.socks-test")
  private let ready: () -> Void
  private let destination: (String?) -> Void
  private var connections: [NWConnection] = []

  var port: UInt16? { listener.port?.rawValue }

  init(ready: @escaping () -> Void, destination: @escaping (String?) -> Void) throws {
    listener = try NWListener(using: .tcp, on: .any)
    self.ready = ready
    self.destination = destination
  }

  func start() {
    listener.stateUpdateHandler = { [weak self] state in
      if case .ready = state { self?.ready() }
    }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { return }
      self.connections.append(connection)
      connection.start(queue: self.queue)
      self.greeting(connection)
    }
    listener.start(queue: queue)
  }

  func stop() {
    listener.cancel()
    queue.async { [weak self] in
      self?.connections.forEach { $0.cancel() }
      self?.connections.removeAll()
    }
  }

  private func read(
    _ connection: NWConnection, count: Int, completion: @escaping (Data) -> Void
  ) {
    connection.receive(minimumIncompleteLength: count, maximumLength: count) {
      data, _, _, error in
      guard error == nil, let data, data.count == count else {
        connection.cancel()
        return
      }
      completion(data)
    }
  }

  private func send(
    _ data: [UInt8], to connection: NWConnection, completion: @escaping () -> Void
  ) {
    connection.send(content: Data(data), completion: .contentProcessed { error in
      if error == nil { completion() } else { connection.cancel() }
    })
  }

  private func greeting(_ connection: NWConnection) {
    read(connection, count: 2) { [weak self] header in
      guard let self, header[0] == 5, header[1] > 0 else {
        connection.cancel()
        return
      }
      self.read(connection, count: Int(header[1])) { [weak self] methods in
        guard let self else { return }
        if methods.contains(2) {
          self.send([5, 2], to: connection) { [weak self] in
            self?.authenticate(connection)
          }
        } else if methods.contains(0) {
          self.send([5, 0], to: connection) { [weak self] in
            self?.connectRequest(connection)
          }
        } else {
          connection.cancel()
        }
      }
    }
  }

  private func authenticate(_ connection: NWConnection) {
    read(connection, count: 2) { [weak self] header in
      guard let self, header[0] == 1, header[1] > 0 else {
        connection.cancel()
        return
      }
      self.read(connection, count: Int(header[1]) + 1) { [weak self] userAndLength in
        guard let self, let length = userAndLength.last, length > 0 else {
          connection.cancel()
          return
        }
        self.read(connection, count: Int(length)) { [weak self] _ in
          self?.send([1, 0], to: connection) { [weak self] in
            self?.connectRequest(connection)
          }
        }
      }
    }
  }

  private func connectRequest(_ connection: NWConnection) {
    read(connection, count: 4) { [weak self] header in
      guard let self else { return }
      guard header[0] == 5, header[1] == 1, header[3] == 3 else {
        self.destination(nil)
        connection.cancel()
        return
      }
      self.read(connection, count: 1) { [weak self] length in
        guard let self, length[0] > 0 else {
          connection.cancel()
          return
        }
        self.read(connection, count: Int(length[0]) + 2) { [weak self] address in
          self?.destination(String(data: address.dropLast(2), encoding: .utf8))
          self?.send([5, 1, 0, 1, 0, 0, 0, 0, 0, 0], to: connection) {
            connection.cancel()
          }
        }
      }
    }
  }
}
#endif
