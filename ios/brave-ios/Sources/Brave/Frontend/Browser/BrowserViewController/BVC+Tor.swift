// Copyright (c) 2026 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the Mozilla Public
// License, v. 2.0. See https://mozilla.org/MPL/2.0/.
import BraveStrings
import BraveTorUI
import BrowserMenu
import Preferences
import SwiftUI
import UIKit
import Web

extension BrowserViewController {
  func presentTorMenu(from sourceView: UIView) {
    presentBrowserMenu(from: sourceView, activities: [], tab: tabManager.selectedTab,
                       pageURL: tabManager.selectedTab?.visibleURL)
  }

  func observeTorMenuStatus() {
    guard torMenuCancellable == nil else { return }
    torMenuCancellable = TorBrowsingSession.shared.statePublisher.sink { [weak self] state in
      guard let self else { return }
      switch state {
      case .waiting, .connected:
        self.torMenuAttemptActive = false
        self.torMenuPopupTask?.cancel()
        self.torMenuPopupTask = nil
      case .unavailable:
        break
      case .connecting:
        guard !self.torMenuAttemptActive else { return }
        self.torMenuAttemptActive = true
        self.torMenuPopupTask = Task { [weak self] in
          // Only prompt for a slow attempt; progress updates must not restart this delay.
          do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
          guard let self, !Task.isCancelled,
            !Preferences.Privacy.disableTorAutomaticPopup.value,
            self.tabManager.selectedTab?.isTor == true,
            self.viewIfLoaded?.window != nil,
            self.currentScene?.activationState == .foregroundActive,
            self.presentedViewController == nil
          else { return }
          guard case .connecting = TorBrowsingSession.shared.state else { return }
          self.presentTorMenu(from: self.toolbar?.menuButton ?? self.topToolbar.menuButton)
        }
      }
    }
  }
}

@MainActor
struct TorMenuStatusView: View {
  @State private var state = TorBrowsingSession.shared.state
  @State private var stage = TorBrowsingSession.shared.bootstrapSummary
  @ObservedObject private var disablePopup = Preferences.Privacy.disableTorAutomaticPopup

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(Strings.Tor.connectionStatus).font(.headline)
      HStack(spacing: 12) {
        statusGlyph.frame(width: 44, height: 44).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(statusText).font(.subheadline)
          if case .connecting(let progress) = state {
            Text("\(progress)/100%").font(.caption.monospacedDigit())
          }
        }
      }
      Button(Strings.Tor.reloadConnection) { TorBrowsingSession.shared.reconnect() }
      Toggle(Strings.Tor.disableAutomaticPopup, isOn: $disablePopup.value)
        .font(.subheadline)
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    .onReceive(TorBrowsingSession.shared.statePublisher) {
      state = $0
      stage = TorBrowsingSession.shared.bootstrapSummary
    }
  }

  @ViewBuilder private var statusGlyph: some View {
    switch state {
    case .connected:
      Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
    case .unavailable:
      Image(systemName: "xmark.circle.fill").font(.largeTitle).foregroundStyle(.red)
    case .waiting:
      ProgressView()
    case .connecting(let progress):
      ZStack {
        Circle().stroke(.secondary.opacity(0.2), lineWidth: 4)
        Circle().trim(from: 0, to: CGFloat(progress) / 100)
          .stroke(.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
          .rotationEffect(.degrees(-90))
        ProgressView().controlSize(.mini)
      }
    }
  }

  private var statusText: String {
    switch state {
    case .connected: Strings.Tor.connected
    case .unavailable: Strings.Tor.unavailable
    case .waiting: Strings.Tor.waiting
    // Desktop's private NTP likewise displays Tor's bootstrap message as its subtitle.
    case .connecting: stage.isEmpty ? Strings.Tor.connecting : stage
    }
  }
}
