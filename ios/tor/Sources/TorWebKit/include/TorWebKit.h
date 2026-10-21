// Copyright (c) 2026 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the Mozilla Public
// License, v. 2.0. See https://mozilla.org/MPL/2.0/.
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN
/// Returns nil when the native timezone override is unavailable.
FOUNDATION_EXPORT WKProcessPool * _Nullable BraveTorUTCProcessPool(void);
/// Exposed for an independent non-UTC control in native WebKit tests.
FOUNDATION_EXPORT WKProcessPool * _Nullable BraveTorProcessPoolForTimeZone(NSString *timeZone);
NS_ASSUME_NONNULL_END
