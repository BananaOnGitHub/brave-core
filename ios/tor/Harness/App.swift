// Copyright (c) 2026 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. See https://mozilla.org/MPL/2.0/.
import BraveTorUI
import SwiftUI
import UIKit

@main
struct BraveTorPrototypeApp: App {
  var body: some Scene {
    WindowGroup {
      TorPrototypeScreen().ignoresSafeArea()
    }
  }
}

private struct TorPrototypeScreen: UIViewControllerRepresentable {
  func makeUIViewController(context: Context) -> UINavigationController {
    UINavigationController(rootViewController: TorBrowserViewController())
  }

  func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}
