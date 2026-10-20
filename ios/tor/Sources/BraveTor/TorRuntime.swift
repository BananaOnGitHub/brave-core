// Copyright (c) 2026 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the Mozilla Public
// License, v. 2.0. See https://mozilla.org/MPL/2.0/.
import Darwin
import EmbeddedTor
import Foundation

public struct TorSnapshot: Sendable {
  public let progress: Int
  public let endpoint: TorEndpoint?
  public let circuitEstablished: Bool
}

/// Owns one embedded C Tor instance. Calls are serialized away from the UI actor.
public actor TorRuntime {
  private var host: OpaquePointer?
  private var channel: TorControlChannel?
  private var networkEnabled = false
  private let dataDirectory: URL?

  public init(dataDirectory: URL? = nil) {
    self.dataDirectory = dataDirectory
  }

  deinit {
    brave_tor_host_release(host)
  }

  /// Starts offline. No relay connections are permitted until connect().
  public func prepare() throws {
    if channel == nil {
      let directory = try dataDirectory ?? FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      ).appendingPathComponent("EmbeddedTor", isDirectory: true)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      var protectedDirectory = directory
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try protectedDirectory.setResourceValues(values)
      #if os(iOS)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: directory.path
      )
      #endif

      let arguments = [
        "tor", "--ignore-missing-torrc", "-f", "/dev/null", "--defaults-torrc", "/dev/null",
        "--ClientOnly", "1", "--DataDirectory", directory.path,
        "--SocksPort", "127.0.0.1:auto IsolateSOCKSAuth",
        "--ControlPort", "0", "--DisableNetwork", "1",
        "--AvoidDiskWrites", "1", "--SafeLogging", "1",
        "--SafeSocks", "1", "--ClientRejectInternalAddresses", "1",
        "--Log", "err file /dev/null",
      ]
      let strings = arguments.map { strdup($0) }
      defer { strings.forEach { free($0) } }
      guard strings.allSatisfy({ $0 != nil }) else { throw TorError.unavailable }
      let argv = strings.map { UnsafePointer<CChar>($0!) }
      var descriptor: Int32 = -1
      host = argv.withUnsafeBufferPointer {
        brave_tor_host_start(Int32(argv.count), $0.baseAddress!, &descriptor)
      }
      guard host != nil, descriptor >= 0 else { throw TorError.unavailable }
      channel = TorControlChannel(descriptor: descriptor)
    }
    guard let channel else { throw TorError.unavailable }
    _ = try channel.command("GETINFO version")
  }

  public func connect() throws {
    try prepare()
    guard let channel else { throw TorError.unavailable }
    _ = try channel.command("SETCONF DisableNetwork=0")
    networkEnabled = true
  }

  public func suspend() {
    networkEnabled = false
    guard let channel else { return }
    do {
      _ = try channel.command("SETCONF DisableNetwork=1")
    } catch {
      // A broken control channel must not leave an unmanageable Tor instance.
      self.channel = nil
      brave_tor_host_release(host)
      host = nil
    }
  }

  public func snapshot() throws -> TorSnapshot {
    guard networkEnabled, let channel else {
      return TorSnapshot(progress: 0, endpoint: nil, circuitEstablished: false)
    }
    let reply = try channel.command(
      "GETINFO status/bootstrap-phase status/circuit-established net/listeners/socks"
    )
    let phase = reply.value(for: "status/bootstrap-phase") ?? ""
    let progress = phase.split(separator: " ").first(where: {
      $0.hasPrefix("PROGRESS=")
    }).flatMap { Int($0.dropFirst("PROGRESS=".count)) } ?? 0
    let listener = reply.value(for: "net/listeners/socks") ?? ""
    let endpoint = listener.isEmpty ? nil : try TorEndpoint(listener: listener)
    return TorSnapshot(
      progress: min(100, max(0, progress)),
      endpoint: endpoint,
      circuitEstablished: reply.value(for: "status/circuit-established") == "1"
    )
  }

  func networkIsDisabled() throws -> Bool {
    try prepare()
    guard let channel else { throw TorError.unavailable }
    return try channel.command("GETCONF DisableNetwork").value(for: "DisableNetwork") == "1"
  }

  /// Used by offline validation to prove the embedded control connection works.
  public func version() throws -> String {
    _ = try prepare()
    guard let channel, let version = try channel.command("GETINFO version").value(for: "version")
    else {
      throw TorError.malformedReply
    }
    return version
  }
}

private final class TorControlChannel {
  private let descriptor: Int32
  private var buffer = Data()

  init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  // Only fixed commands authored in TorRuntime reach this private method.
  func command(_ command: String) throws -> TorReply {
    guard !command.contains("\r"), !command.contains("\n") else {
      throw TorError.rejectedCommand
    }
    let deadline = Date().addingTimeInterval(5)
    let payload = Array((command + "\r\n").utf8)
    try payload.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        try wait(for: Int16(POLLOUT), until: deadline)
        let sent = Darwin.send(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
        if sent < 0 && errno == EINTR { continue }
        guard sent > 0 else { throw TorError.controlClosed }
        offset += sent
      }
    }
    var parser = TorReplyParser()
    while true {
      let line = try readLine(until: deadline)
      if let reply = try parser.consume(line) {
        guard reply.code == 250 else { throw TorError.rejectedCommand }
        return reply
      }
    }
  }

  private func wait(for events: Int16, until deadline: Date) throws {
    while true {
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { throw TorError.controlTimeout }
      var descriptor = pollfd(fd: self.descriptor, events: events, revents: 0)
      let result = Darwin.poll(&descriptor, 1, Int32(min(5_000, max(1, remaining * 1_000))))
      if result < 0 && errno == EINTR { continue }
      guard result > 0 else {
        throw result == 0 ? TorError.controlTimeout : TorError.controlClosed
      }
      if descriptor.revents & events != 0 { return }
      throw TorError.controlClosed
    }
  }

  private func readLine(until deadline: Date) throws -> String {
    while true {
      if let end = buffer.range(of: Data([13, 10])) {
        guard let line = String(data: buffer[..<end.lowerBound], encoding: .utf8) else {
          throw TorError.malformedReply
        }
        buffer.removeSubrange(..<end.upperBound)
        return line
      }
      guard buffer.count < 65_536 else { throw TorError.malformedReply }
      try wait(for: Int16(POLLIN), until: deadline)
      var chunk = [UInt8](repeating: 0, count: 4_096)
      let count = Darwin.recv(descriptor, &chunk, chunk.count, 0)
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { throw TorError.controlClosed }
      buffer.append(contentsOf: chunk.prefix(count))
    }
  }
}
