// Copyright (c) 2026 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the Mozilla Public
// License, v. 2.0. See https://mozilla.org/MPL/2.0/.
#import "TorWebKit.h"

// WebKit's native override applies to Date, Intl, frames, and worker processes.
// SPI is required for this sideload build; never fall back to JS monkey-patches.
@interface NSObject (BraveTorProcessConfiguration)
@property(nonatomic, copy) NSString *timeZoneOverride;
@end

@interface WKProcessPool (BraveTorConfiguration)
- (instancetype)_initWithConfiguration:(id)configuration;
@end

WKProcessPool *BraveTorUTCProcessPool(void) {
  return BraveTorProcessPoolForTimeZone(@"UTC");
}

WKProcessPool *BraveTorProcessPoolForTimeZone(NSString *timeZone) {
  Class configurationClass = NSClassFromString(@"_WKProcessPoolConfiguration");
  if (!configurationClass ||
      ![configurationClass instancesRespondToSelector:@selector(setTimeZoneOverride:)] ||
      ![WKProcessPool instancesRespondToSelector:@selector(_initWithConfiguration:)]) {
    return nil;
  }
  NSObject *configuration = [[configurationClass alloc] init];
  configuration.timeZoneOverride = timeZone;
  WKProcessPool *pool = [[WKProcessPool alloc] _initWithConfiguration:configuration];
#if !__has_feature(objc_arc)
  [configuration release];
  return [pool autorelease];
#else
  return pool;
#endif
}
