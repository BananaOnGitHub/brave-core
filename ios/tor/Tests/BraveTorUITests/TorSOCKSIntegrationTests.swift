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
      serveScriptedPage: false,
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
    let configuration = try TorWebPolicy.configuration(
      endpoint: endpoint, rules: rules, isolationID: "test-isolation", javaScriptEnabled: false
    )
    let webView = WKWebView(frame: .zero, configuration: configuration)
    // .invalid is reserved. The local stub rejects the SOCKS connection:
    // this test never contacts the public Tor network or an origin server.
    webView.load(URLRequest(url: URL(string: "https://brave-tor-probe.invalid/")!))
    await fulfillment(of: [request], timeout: 15)
    webView.stopLoading()
  }

  func testPageJavaScriptFetchAndRedirectUseUnresolvedSOCKSHostnames() async throws {
    let ready = expectation(description: "Local SOCKS listener is ready")
    let document = expectation(description: "Document hostname reaches SOCKS")
    let fetch = expectation(description: "JavaScript fetch hostname reaches SOCKS")
    let redirect = expectation(description: "Redirect hostname reaches SOCKS")
    let completed = expectation(description: "Page JavaScript reads the fetch response")
    let server = try SOCKSProbeServer(
      serveScriptedPage: true,
      ready: { ready.fulfill() },
      destination: { hostname in
        switch hostname {
        case "brave-tor-probe.invalid": document.fulfill()
        case "brave-tor-fetch.invalid": fetch.fulfill()
        case "brave-tor-redirect.invalid": redirect.fulfill()
        default: XCTFail("Unexpected or resolved SOCKS destination: \(hostname ?? "nil")")
        }
      }
    )
    defer { server.stop() }
    server.start()
    await fulfillment(of: [ready], timeout: 10)
    let port = try XCTUnwrap(server.port)
    let endpoint = try TorEndpoint(listener: "127.0.0.1:\(port)")
    let rules = try await TorWebPolicy.compileRules()
    let configuration = try TorWebPolicy.configuration(
      endpoint: endpoint, rules: rules, isolationID: "script-isolation", javaScriptEnabled: true
    )
    let probe = ScriptResultProbe { value in
      XCTAssertEqual(value, "tor-script-ok")
      completed.fulfill()
    }
    configuration.userContentController.add(probe, name: "scriptResult")
    defer { configuration.userContentController.removeScriptMessageHandler(forName: "scriptResult") }
    let webView = WKWebView(frame: .zero, configuration: configuration)
    defer { webView.stopLoading() }
    // HTTP is intentional: the loopback SOCKS stub is also the origin server.
    // Reserved .invalid hostnames never resolve or contact a public destination.
    webView.load(URLRequest(url: URL(string: "http://brave-tor-probe.invalid/")!))
    await fulfillment(of: [document, fetch, redirect, completed], timeout: 20)
    XCTAssertEqual(webView.title, "script-ran")
  }

  func testDisabledPageJavaScriptDoesNotExecute() async throws {
    let ready = expectation(description: "Local SOCKS listener is ready")
    let document = expectation(description: "Disabled-script document reaches SOCKS")
    let server = try SOCKSProbeServer(
      serveScriptedPage: true,
      ready: { ready.fulfill() },
      destination: { hostname in
        XCTAssertEqual(hostname, "brave-tor-probe.invalid", "Disabled scripts must not fetch")
        if hostname == "brave-tor-probe.invalid" { document.fulfill() }
      }
    )
    defer { server.stop() }
    server.start()
    await fulfillment(of: [ready], timeout: 10)
    let port = try XCTUnwrap(server.port)
    let rules = try await TorWebPolicy.compileRules()
    let endpoint = try TorEndpoint(listener: "127.0.0.1:\(port)")
    let configuration = try TorWebPolicy.configuration(
      endpoint: endpoint, rules: rules, isolationID: "disabled-script", javaScriptEnabled: false
    )
    let finished = expectation(description: "Static page finished loading")
    let probe = PageLoadProbe { finished.fulfill() }
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = probe
    defer { webView.stopLoading() }
    // The navigation callback and title update arrive independently from WebKit.
    let title = keyValueObservingExpectation(
      for: webView, keyPath: "title", expectedValue: "script-off"
    )
    // Use the same scripted HTTP response as the enabled test, through SOCKS.
    webView.load(URLRequest(url: URL(string: "http://brave-tor-probe.invalid/")!))
    await fulfillment(of: [document, finished, title], timeout: 15)
    withExtendedLifetime(probe) {
      XCTAssertEqual(webView.title, "script-off")
    }
  }
}

@MainActor
private final class ScriptResultProbe: NSObject, WKScriptMessageHandler {
  private let result: (String?) -> Void

  init(result: @escaping (String?) -> Void) { self.result = result }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    result(message.body as? String)
  }
}

@MainActor
private final class PageLoadProbe: NSObject, WKNavigationDelegate {
  private let finished: () -> Void

  init(finished: @escaping () -> Void) { self.finished = finished }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    finished()
  }
}

/// NWConnection callbacks and connection storage are confined to queue.
private final class SOCKSProbeServer: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "brave.tor.socks-test")
  private let ready: () -> Void
  private let destination: (String?) -> Void
  private let serveScriptedPage: Bool
  private var connections: [NWConnection] = []

  var port: UInt16? { listener.port?.rawValue }

  init(
    serveScriptedPage: Bool, ready: @escaping () -> Void,
    destination: @escaping (String?) -> Void
  ) throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    listener = try NWListener(using: parameters)
    self.ready = ready
    self.destination = destination
    self.serveScriptedPage = serveScriptedPage
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
          guard let self else { return }
          let hostname = String(data: address.dropLast(2), encoding: .utf8)
          self.destination(hostname)
          if self.serveScriptedPage, let hostname {
            self.send([5, 0, 0, 1, 0, 0, 0, 0, 0, 0], to: connection) { [weak self] in
              self?.readHTTPRequest(connection, hostname: hostname, buffer: Data())
            }
          } else {
            self.send([5, 1, 0, 1, 0, 0, 0, 0, 0, 0], to: connection) {
              connection.cancel()
            }
          }
        }
      }
    }
  }

  private func readHTTPRequest(_ connection: NWConnection, hostname: String, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
      [weak self] data, _, complete, error in
      guard let self, error == nil, let data, !data.isEmpty else {
        connection.cancel()
        return
      }
      let received = buffer + data
      guard received.count <= 8192 else {
        connection.cancel()
        return
      }
      if received.range(of: Data("\r\n\r\n".utf8)) != nil {
        self.respondToHTTP(connection, hostname: hostname)
      } else if !complete {
        self.readHTTPRequest(connection, hostname: hostname, buffer: received)
      } else {
        connection.cancel()
      }
    }
  }

  private func respondToHTTP(_ connection: NWConnection, hostname: String) {
    let status: String
    let headers: String
    let body: String
    switch hostname {
    case "brave-tor-probe.invalid":
      status = "200 OK"
      headers = "Content-Type: text/html; charset=utf-8\r\n"
      body = """
        <!doctype html><title>script-off</title><script>
        document.title = 'script-ran';
        fetch('http://brave-tor-fetch.invalid/start')
          .then(response => response.text())
          .then(body => window.webkit.messageHandlers.scriptResult.postMessage(body))
          .catch(error => window.webkit.messageHandlers.scriptResult.postMessage(String(error)));
        </script>
        """
    case "brave-tor-fetch.invalid":
      status = "302 Found"
      headers = "Location: http://brave-tor-redirect.invalid/result\r\n"
      body = ""
    case "brave-tor-redirect.invalid":
      status = "200 OK"
      headers = "Content-Type: text/plain\r\n"
      body = "tor-script-ok"
    default:
      connection.cancel()
      return
    }
    let response = "HTTP/1.1 \(status)\r\n\(headers)"
      + "Access-Control-Allow-Origin: *\r\nCache-Control: no-store\r\n"
      + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    connection.send(
      content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
      completion: .contentProcessed { error in
        if error != nil { connection.cancel() }
      }
    )
  }
}
#endif
