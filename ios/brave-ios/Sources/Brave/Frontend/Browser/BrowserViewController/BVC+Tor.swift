// Copyright (c) 2026 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the Mozilla Public
// License, v. 2.0. See https://mozilla.org/MPL/2.0/.
import BraveStrings
import UIKit
import Web

extension BrowserViewController {
  /// Keep auxiliary services out of Tor until their native requests are proxied.
  func presentTorMenu(from sourceView: UIView) {
    let menu = UIAlertController(title: Strings.Tor.title, message: Strings.Tor.limitations, preferredStyle: .actionSheet)
    menu.addAction(UIAlertAction(title: Strings.Tor.newTab, style: .default) { [weak self] _ in
      self?.tabManager.addTabAndSelect(isPrivate: true)
    })
    menu.addAction(UIAlertAction(title: Strings.Tor.reload, style: .default) { [weak self] _ in
      self?.tabManager.selectedTab?.reload()
    })
    menu.addAction(UIAlertAction(title: Strings.cancelButtonTitle, style: .cancel))
    menu.popoverPresentationController?.sourceView = sourceView
    menu.popoverPresentationController?.sourceRect = sourceView.bounds
    present(menu, animated: true)
  }
}
