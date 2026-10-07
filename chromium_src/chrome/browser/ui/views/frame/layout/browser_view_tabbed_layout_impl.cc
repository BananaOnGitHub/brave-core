/* Copyright (c) 2026 The Brave Authors. All rights reserved.
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at https://mozilla.org/MPL/2.0/. */

#include "brave/browser/ui/views/frame/layout/brave_browser_view_tabbed_layout_impl.h"
#include "chrome/browser/ui/views/frame/custom_corners_background.h"
#include "chrome/browser/ui/views/frame/vertical_tab_strip_region_view.h"
#include "ui/gfx/geometry/rect.h"

// Helpers used by the plaster rewrite of the upstream layout to support placing
// the vertical tab strip on either side. They are declared here so the
// substituted upstream code can call them, and are defined below, after the
// upstream source.
namespace brave_vtab_layout {

bool IsStripLeading(const VerticalTabStripRegionView* region_view);
int GetStripTopOffset(bool leading,
                      int top_offset,
                      float trailing_exclusion_height);
gfx::Rect GetStripBounds(const gfx::Rect& client_area,
                         int width,
                         int top_offset,
                         bool leading);
void MirrorVerticalTabsCorners(
    CustomCornersBackground& background,
    CustomCornersBackground::Corners& corners,
    const VerticalTabStripRegionView* region_view,
    bool is_normal_window_without_trailing_exclusion);

}  // namespace brave_vtab_layout

#include <chrome/browser/ui/views/frame/layout/browser_view_tabbed_layout_impl.cc>

// `BrowserViewTabbedLayoutImpl::SeparatorInfo` is a private nested struct
// defined inside the upstream .cc above. Defining the override here keeps the
// struct out of any header while still letting Brave consolidate the old
// `GetTopSeparatorType()` / `ShadowOverlayVisible()` tweaks into a single
// hook.
BrowserViewTabbedLayoutImpl::SeparatorInfo
BraveBrowserViewTabbedLayoutImpl::CalculateSeparatorInfo() const {
  // Suppress every top separator when there is no visible top UI (toolbar and
  // bookmark bar). This fixes a 1px visible separator at the top of the
  // contents view when in browser fullscreen, where the top chrome is hidden.
  if (!delegate().IsToolbarVisible() && !delegate().IsBookmarkBarVisible()) {
    return SeparatorInfo();
  }

  // Upstream considers the side panel's visibility when calculating the
  // separator. When the panel is shown, a shadow is drawn around the contents
  // (including the infobar), which acts as a separator and hides the actual top
  // separator. However, our UI still requires the top separator when the panel
  // is open. To bypass the upstream logic, we temporarily simulate an invisible
  // panel by setting `side_panel_width` to 0 during the calculation, and
  // restore the original width immediately afterward.
  const int cached_side_panel_width =
      layout_data_->horizontal_layout.side_panel_width;
  layout_data_->horizontal_layout.side_panel_width = 0;

  SeparatorInfo info = BrowserViewTabbedLayoutImpl::CalculateSeparatorInfo();

  layout_data_->horizontal_layout.side_panel_width = cached_side_panel_width;

  // Brave manages its own rounded-corners shadow around the contents and side
  // panel via BraveContentsViewUtil. Suppress the upstream shadow overlay (and
  // its accompanying main-area padding) so it doesn't double up.
  info.shadow_box = false;

  const bool rounded =
      delegate().ShouldUseBraveWebViewRoundedCornersForContents();

  // When the upstream choice is "no top-container separator" (either nothing
  // at all, or only a multi-contents separator), Brave promotes that to a
  // full-width top-container separator unless the rounded-corners contents
  // view is in use - in which case the rounded shape provides the visual
  // divider and no separator is wanted.
  if (!info.top_container_separator) {
    info.top_container_separator = !rounded;
    info.multi_contents_separator = false;
  }

#if BUILDFLAG(IS_MAC)
  if (layout_data_->window_state == WindowState::kFullscreenWithToolbar &&
      rounded && !delegate().IsInfobarVisible()) {
    info.top_container_separator = false;
  }
#endif

  return info;
}

bool BraveBrowserViewTabbedLayoutImpl::GetTopContainerSeparatorForTesting()
    const {
  return CalculateSeparatorInfo().top_container_separator;
}

bool BraveBrowserViewTabbedLayoutImpl::GetMultiContentsSeparatorForTesting()
    const {
  return CalculateSeparatorInfo().multi_contents_separator;
}

bool BraveBrowserViewTabbedLayoutImpl::GetShadowBoxForTesting() const {
  return CalculateSeparatorInfo().shadow_box;
}

void BraveBrowserViewTabbedLayoutImpl::SetWindowStateForTesting(
    BrowserViewLayoutDelegate::WindowState window_state) {
  layout_data_ = std::make_unique<TransientLayoutData>(BrowserLayoutParams());
  layout_data_->window_state = window_state;
}

namespace brave_vtab_layout {

bool IsStripLeading(const VerticalTabStripRegionView* region_view) {
  return !region_view || region_view->IsVerticalTabStripLeading();
}

// When the strip is on the trailing side, it doesn't share the top row with the
// leading caption buttons but with the trailing ones instead, so offset it by
// their height.
int GetStripTopOffset(bool leading,
                      int top_offset,
                      float trailing_exclusion_height) {
  return leading ? top_offset : base::ClampCeil(trailing_exclusion_height);
}

gfx::Rect GetStripBounds(const gfx::Rect& client_area,
                         int width,
                         int top_offset,
                         bool leading) {
  return gfx::Rect(leading ? client_area.x() : client_area.right() - width,
                   client_area.y() + top_offset, width,
                   client_area.height() - top_offset);
}

// Mirrors the window and concave corners of the vertical tab strip's own
// background when it is on the trailing side.
void MirrorVerticalTabsCorners(
    CustomCornersBackground& background,
    CustomCornersBackground::Corners& corners,
    const VerticalTabStripRegionView* region_view,
    bool is_normal_window_without_trailing_exclusion) {
  if (IsStripLeading(region_view)) {
    return;
  }
  CustomCornersBackground::Corners mirrored_corners;
  // The top corners are derived from the leading exclusion, which doesn't apply
  // to the strip on the trailing side. The strip only has the window's top
  // corner unless it's pushed down by the trailing caption buttons.
  if (is_normal_window_without_trailing_exclusion) {
    mirrored_corners[CornerOrientation::kTopTrailing] =
        background.GetWindowCorner(/*upper=*/true);
  }
  mirrored_corners[CornerOrientation::kBottomLeading] =
      corners[CornerOrientation::kBottomTrailing];
  mirrored_corners[CornerOrientation::kBottomTrailing] =
      corners[CornerOrientation::kBottomLeading];
  corners = mirrored_corners;
}

}  // namespace brave_vtab_layout
