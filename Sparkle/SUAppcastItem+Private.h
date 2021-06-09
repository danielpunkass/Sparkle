//
//  SUAppcastItem+Private.h
//  Sparkle
//
//  Created by Mayur Pawashe on 4/30/21.
//  Copyright © 2021 Sparkle Project. All rights reserved.
//

#ifndef SUAppcastItem_Private_h
#define SUAppcastItem_Private_h

#if __has_feature(modules)
#if __has_warning("-Watimport-in-framework-header")
#pragma clang diagnostic ignored "-Watimport-in-framework-header"
#endif
@import Foundation;
#else
#import <Foundation/Foundation.h>
#endif

NS_ASSUME_NONNULL_BEGIN

@interface SUAppcastItem (Private) <NSSecureCoding>

// Initializes with data from a dictionary provided by the RSS class.
- (nullable instancetype)initWithDictionary:(NSDictionary *)dict relativeToURL:(NSURL * _Nullable)appcastURL failureReason:(NSString * _Nullable __autoreleasing *_Nullable)error;

@end

NS_ASSUME_NONNULL_END

#endif /* SUAppcastItem_Private_h */
