// Copyright (c) 2026 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the Mozilla Public
// License, v. 2.0. See https://mozilla.org/MPL/2.0/.
import BraveStrings
import BraveTor
import DesignSystem
import Preferences
import SwiftUI
import UIKit

@MainActor
struct TorSettingsView: View {
  @ObservedObject private var enabled = Preferences.Privacy.torEnabled
  @ObservedObject private var onionOnly = Preferences.Privacy.onlyOnionInTor
  @ObservedObject private var separate = Preferences.Privacy.keepTorTabsSeparate
  @ObservedObject private var savedBridges = Preferences.Privacy.torBridgeConfiguration
  @State private var draft = TorBridgeConfiguration.decode(Preferences.Privacy.torBridgeConfiguration.value)
  @State private var bridgeText = ""
  @State private var showCaptcha = false
  @State private var invalidBridges = false

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $enabled.value) {
          Text(Strings.Tor.enabled)
        }
        Link(Strings.Tor.learnMore, destination: URL(string: "https://support.brave.com/hc/en-us/articles/360018121491")!)
      } footer: {
        Text(Strings.Tor.enabledDescription)
      }
      Section {
        Toggle(Strings.Tor.onionOnly, isOn: $onionOnly.value)
      } footer: {
        Text(Strings.Tor.onionOnlyDescription)
      }
      Section {
        Toggle(Strings.Tor.keepTabsSeparate, isOn: $separate.value)
          .disabled(!enabled.value)
          .accessibilityIdentifier("Tor.keepTabsSeparate")
      } footer: {
        Text(Strings.Tor.keepTabsSeparateFooter)
      }
      Section {
        Toggle(Strings.Tor.useBridges, isOn: $draft.useBridges)
        if draft.useBridges {
          Picker(Strings.Tor.bridgeSource, selection: $draft.source) {
            Text(Strings.Tor.builtIn).tag(TorBridgeSource.builtIn)
            Text(Strings.Tor.requestBridge).tag(TorBridgeSource.request)
            Text(Strings.Tor.provideBridge).tag(TorBridgeSource.provide)
          }
          .pickerStyle(.inline)
          switch draft.source {
          case .builtIn:
            Picker(Strings.Tor.builtInType, selection: $draft.builtIn) {
              ForEach(TorBuiltInBridge.allCases, id: \.self) { kind in
                Text(verbatim: kind.title).tag(kind)
              }
            }
            .pickerStyle(.menu)
          case .request:
            if !draft.requested.isEmpty {
              Text(draft.requested.joined(separator: "\n"))
                .font(.footnote.monospaced())
                .textSelection(.enabled)
            }
            Button(Strings.Tor.newBridge) { showCaptcha = true }
            Text(Strings.Tor.bridgeRequestDescription)
              .font(.footnote).foregroundStyle(.secondary)
          case .provide:
            Text(Strings.Tor.provideDescription).font(.footnote).foregroundStyle(.secondary)
            TextEditor(text: $bridgeText)
              .font(.footnote.monospaced())
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .frame(minHeight: 120)
              .accessibilityLabel(Strings.Tor.provideBridge)
              .onChange(of: bridgeText) { _, text in
                draft.provided = TorBridgeLine.lines(from: text)
              }
          }
        }
        if invalidBridges {
          Text(Strings.Tor.bridgeInvalid).foregroundStyle(.red).font(.footnote)
        }
        Button(Strings.Tor.applyBridges) {
          do {
            _ = try draft.bridgeLines()
            savedBridges.value = draft.encoded
            invalidBridges = false
          } catch { invalidBridges = true }
        }
        .disabled(draft == TorBridgeConfiguration.decode(savedBridges.value))
        Link(Strings.Tor.learnMore, destination: URL(string: "https://support.torproject.org/tor-browser/circumvention/getting-bridges/")!)
      } header: {
        Text(Strings.Tor.useBridges)
      } footer: {
        Text(Strings.Tor.bridgesDescription + "\n\n" + Strings.Tor.bridgeApplyDescription)
      }
      .disabled(!enabled.value)
    }
    .tint(Color(braveSystemName: .primitivePrimary40))
    .navigationTitle(Strings.Tor.settings)
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { bridgeText = draft.provided.joined(separator: "\n") }
    .onChange(of: enabled.value) { _, value in if !value { showCaptcha = false } }
    .sheet(isPresented: $showCaptcha) {
      TorBridgeCaptchaView { lines in
        draft.requested = lines
        draft.source = .request
        invalidBridges = false
      }
    }
  }
}

@MainActor
private struct TorBridgeCaptchaView: View {
  var onBridges: ([String]) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var challenge: TorBridgeChallenge?
  @State private var image: UIImage?
  @State private var solution = ""
  @State private var busy = false
  @State private var failed = false
  @State private var task: Task<Void, Never>?
  private let client = TorMoatClient()

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(Strings.Tor.bridgeRequestDescription)
          if busy { ProgressView() }
          if let image {
            Image(uiImage: image).resizable().scaledToFit()
              .frame(maxHeight: 160)
              .accessibilityLabel(Strings.Tor.captchaPrompt)
          }
          TextField(Strings.Tor.captchaSolution, text: $solution)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .disabled(busy || challenge == nil)
          Button(Strings.Tor.captchaRefresh) {
            task?.cancel()
            task = Task { await refresh() }
          }.disabled(busy)
          Button(Strings.Tor.captchaSubmit) {
            task?.cancel()
            task = Task { await submit() }
          }.disabled(busy || solution.isEmpty || challenge == nil)
          if failed {
            Text(Strings.Tor.captchaError).font(.footnote).foregroundStyle(.secondary)
          }
        } footer: {
          Text(Strings.Tor.captchaPrompt)
        }
      }
      .navigationTitle(Strings.Tor.captchaTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(Strings.cancelButtonTitle) { dismiss() }
        }
      }
      .onAppear { task = Task { await refresh() } }
      .onDisappear { task?.cancel() }
    }
  }

  private func refresh() async {
    busy = true
    failed = false
    image = nil
    challenge = nil
    solution = ""
    defer { busy = false }
    do {
      let value = try await client.challenge()
      try Task.checkCancellation()
      guard let decoded = UIImage(data: value.image),
        decoded.size.width <= 4096, decoded.size.height <= 4096 else {
        throw TorBridgeError.invalidResponse
      }
      challenge = value
      image = decoded
    } catch {
      if !Task.isCancelled { failed = true }
    }
  }

  private func submit() async {
    guard let challenge else { return }
    busy = true
    failed = false
    defer { busy = false }
    do {
      let lines = try await client.bridges(challenge: challenge, solution: solution)
      try Task.checkCancellation()
      onBridges(lines)
      dismiss()
    } catch {
      guard !Task.isCancelled else { return }
      await refresh()
      failed = true
    }
  }
}
