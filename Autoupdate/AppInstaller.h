//
//  AppInstaller.h
//  Sparkle
//
//  Created by Mayur Pawashe on 3/7/16.
//  Copyright © 2016 Sparkle Project. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "SUUnarchiverProtocol.h"

NS_ASSUME_NONNULL_BEGIN

@interface AppInstaller : NSObject

- (instancetype)initWithHostBundleIdentifier:(NSString *)hostBundleIdentifier homeDirectory:(NSString *)homeDirectory userName:(NSString *)userName;

- (void)start;

- (void)cleanupAndExitWithStatus:(int)status error:(NSError * _Nullable)error __attribute__((noreturn));

@end

NS_ASSUME_NONNULL_END
