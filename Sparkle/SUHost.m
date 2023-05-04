//
//  SUHost.m
//  Sparkle
//
//  Copyright 2008 Andy Matuschak. All rights reserved.
//

#import "SUHost.h"

#import "SUConstants.h"
#include <sys/mount.h> // For statfs for isRunningOnReadOnlyVolume
#import "SULog.h"
#import "SUSignatures.h"


#include "AppKitPrevention.h"

NS_ASSUME_NONNULL_BEGIN

// This class should not rely on AppKit and should also be process independent
// For example, it should not have code that tests writabilty to somewhere on disk,
// as that may depend on the privileges of the process owner. Or code that depends on
// if the process is sandboxed or not; eg: finding the user's caches directory. Or code that depends
// on compilation flags and if other files exist relative to the host bundle.

@implementation SUHost
{
    NSString *_defaultsDomain;
    
    BOOL _usesStandardUserDefaults;
    BOOL _isMainBundle;
}

@synthesize bundle = _bundle;

- (instancetype)initWithBundle:(NSBundle *)aBundle
{
	if ((self = [super init]))
	{
        NSParameterAssert(aBundle);
        _bundle = aBundle;
        if (_bundle.bundleIdentifier == nil) {
            SULog(SULogLevelError, @"Error: the bundle being updated at %@ has no %@! This will cause preference read/write to not work properly.", _bundle, kCFBundleIdentifierKey);
        }
        
        _isMainBundle = [aBundle isEqualTo:[NSBundle mainBundle]];

        _defaultsDomain = [self objectForInfoDictionaryKey:SUDefaultsDomainKey];
        if (_defaultsDomain == nil) {
            _defaultsDomain = [_bundle bundleIdentifier];
        }

        // If we're using the main bundle's defaults we'll use the standard user defaults mechanism, otherwise we have to get CF-y.
        NSString *mainBundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        _usesStandardUserDefaults = _defaultsDomain == nil || [_defaultsDomain isEqualToString:mainBundleIdentifier];
    }
    return self;
}

- (NSString *)description { return [NSString stringWithFormat:@"%@ <%@>", [self class], [self bundlePath]]; }

- (NSString *)bundlePath
{
    return _bundle.bundlePath;
}

- (NSString * _Nonnull)name
{
    NSString *name;

    // Allow host bundle to provide a custom name
    name = [self objectForInfoDictionaryKey:@"SUBundleName"];
    if (name && name.length > 0) return name;

    name = [self objectForInfoDictionaryKey:@"CFBundleDisplayName"];
	if (name && name.length > 0) return name;

    name = [self objectForInfoDictionaryKey:(__bridge NSString *)kCFBundleNameKey];
	if (name && name.length > 0) return name;

    return [[[NSFileManager defaultManager] displayNameAtPath:[self bundlePath]] stringByDeletingPathExtension];
}

- (BOOL)validVersion
{
    return [self isValidVersion:[self _version]];
}

- (BOOL)isValidVersion:(NSString * _Nullable)version SPU_OBJC_DIRECT
{
    return (version != nil && version.length != 0);
}

- (NSString * _Nullable)_version SPU_OBJC_DIRECT
{
    NSString *version = [self objectForInfoDictionaryKey:(__bridge NSString *)kCFBundleVersionKey];
    return ([self isValidVersion:version] ? version : nil);
}

- (NSString * _Nonnull)version
{
    NSString *version = [self _version];
    if (version == nil) {
        SULog(SULogLevelError, @"This host (%@) has no %@! This attribute is required.", [self bundlePath], (__bridge NSString *)kCFBundleVersionKey);
        // Instead of abort()-ing, return an empty string to satisfy the _Nonnull contract.
        return @"";
    }
    return version;
}

- (NSString * _Nonnull)displayVersion
{
    NSString *shortVersionString = [self objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (shortVersionString)
        return shortVersionString;
    else
        return [self version]; // Fall back on the normal version string.
}

- (BOOL)isRunningOnReadOnlyVolume
{
    struct statfs statfs_info;
    statfs(_bundle.bundlePath.fileSystemRepresentation, &statfs_info);
    return (statfs_info.f_flags & MNT_RDONLY) != 0;
}

- (BOOL)isRunningTranslocated
{
    NSString *path = _bundle.bundlePath;
    return [path rangeOfString:@"/AppTranslocation/"].location != NSNotFound;
}

- (NSString *_Nullable)publicEDKey SPU_OBJC_DIRECT
{
    return [self objectForInfoDictionaryKey:SUPublicEDKeyKey];
}

- (NSString *_Nullable)publicDSAKey SPU_OBJC_DIRECT
{
    // Maybe the key is just a string in the Info.plist.
    NSString *key = [self objectForInfoDictionaryKey:SUPublicDSAKeyKey];
	if (key) {
        return key;
    }

    // More likely, we've got a reference to a Resources file by filename:
    NSString *keyFilename = [self publicDSAKeyFileKey];
	if (!keyFilename) {
        return nil;
    }

    NSString *keyPath = [_bundle pathForResource:keyFilename ofType:nil];
    if (!keyPath) {
        return nil;
    }
    NSError *error = nil;
    key = [NSString stringWithContentsOfFile:keyPath encoding:NSASCIIStringEncoding error:&error];
    if (error) {
        SULog(SULogLevelError, @"Error loading %@: %@", keyPath, error);
    }
    return key;
}

- (SUPublicKeys *)publicKeys
{
    return [[SUPublicKeys alloc] initWithEd:[self publicEDKey]
                                        dsa:[self publicDSAKey]];
}

- (NSString * _Nullable)publicDSAKeyFileKey
{
    return [self objectForInfoDictionaryKey:SUPublicDSAKeyFileKey];
}

// WKWebView has a bug where it won't work in loading local HTML content in sandboxed apps that do not have an outgoing network entitlement
// FB6993802: https://twitter.com/sindresorhus/status/1160577243929878528 | https://github.com/feedback-assistant/reports/issues/1
// If the developer is using the downloader XPC service, they are very most likely are a) sandboxed b) do not use outgoing network entitlement.
// In this case, fall back to legacy WebKit view.
// (In theory it is possible for a non-sandboxed app or sandboxed app with outgoing network entitlement to use the XPC service, it's just pretty unlikely. And falling back to a legacy web view would not be too harmful in those cases).
- (BOOL)requiresLegacyWebView
{
    static BOOL sRequiresLegacyWebView = NO;
    static dispatch_once_t sEntitlementsCheckToken = 0;

    dispatch_once(&sEntitlementsCheckToken, ^{
        // If we run into any error at all, we just assume we don't have entitlements
        NSDictionary* entitlements = nil;
        SecCodeRef appCodeRef = NULL;
        OSStatus securityErr = SecCodeCopySelf(kSecCSDefaultFlags, &appCodeRef);
        if (securityErr == errSecSuccess) {
            CFDictionaryRef codeSignInfo;
            if (SecCodeCopySigningInformation(appCodeRef, kSecCSRequirementInformation, &codeSignInfo) == errSecSuccess) {
                entitlements = (__bridge NSDictionary*)CFDictionaryGetValue(codeSignInfo, kSecCodeInfoEntitlementsDict);
                CFRelease(codeSignInfo);
            }
            CFRelease(appCodeRef);
        }

        NSNumber* sandboxedValue = [entitlements objectForKey:@"com.apple.security.app-sandbox"];
        BOOL isSandboxed = [sandboxedValue isKindOfClass:[NSNumber class]] ? [sandboxedValue boolValue] : NO;
        NSNumber* networkAccessValue = [entitlements objectForKey:@"com.apple.security.network.client"];
        BOOL hasNetworkAccess = [networkAccessValue isKindOfClass:[NSNumber class]] ? [networkAccessValue boolValue] : NO;
        sRequiresLegacyWebView = isSandboxed && (hasNetworkAccess == NO);
    });

    return sRequiresLegacyWebView;
}

- (nullable id)objectForInfoDictionaryKey:(NSString *)key
{
    if (_isMainBundle) {
        // Common fast path - if we're updating the main bundle, that means our updater and host bundle's lifetime is the same
        // If the bundle happens to be updated or change, that means our updater process needs to be terminated first to do it safely
        // Thus we can rely on the cached Info dictionary
        return [_bundle objectForInfoDictionaryKey:key];
    } else {
        // Slow path - if we're updating another bundle, we should read in the most up to date Info dictionary because
        // the bundle can be replaced externally or even by us.
        // This is the easiest way to read the Info dictionary values *correctly* despite some performance loss.
        // A mutable method to reload the Info dictionary at certain points and have it cached at other points is challenging to do correctly.
        CFDictionaryRef cfInfoDictionary = CFBundleCopyInfoDictionaryInDirectory((CFURLRef)_bundle.bundleURL);
        NSDictionary *infoDictionary = CFBridgingRelease(cfInfoDictionary);
        
        return [infoDictionary objectForKey:key];
    }
}

- (BOOL)boolForInfoDictionaryKey:(NSString *)key
{
    return [(NSNumber *)[self objectForInfoDictionaryKey:key] boolValue];
}

- (nullable id)objectForUserDefaultsKey:(NSString *)defaultName
{
    if (!defaultName || _defaultsDomain == nil) {
        return nil;
    }

    // Under Tiger, CFPreferencesCopyAppValue doesn't get values from NSRegistrationDomain, so anything
    // passed into -[NSUserDefaults registerDefaults:] is ignored.  The following line falls
    // back to using NSUserDefaults, but only if the host bundle is the main bundle.
    if (_usesStandardUserDefaults) {
        return [[NSUserDefaults standardUserDefaults] objectForKey:defaultName];
    }

    CFPropertyListRef obj = CFPreferencesCopyAppValue((__bridge CFStringRef)defaultName, (__bridge CFStringRef)_defaultsDomain);
    return CFBridgingRelease(obj);
}

// Note this handles nil being passed for defaultName, in which case the user default will be removed
- (void)setObject:(nullable id)value forUserDefaultsKey:(NSString *)defaultName
{
	if (_usesStandardUserDefaults)
	{
        [[NSUserDefaults standardUserDefaults] setObject:value forKey:defaultName];
	}
	else
	{
        CFPreferencesSetValue((__bridge CFStringRef)defaultName, (__bridge CFPropertyListRef)(value), (__bridge CFStringRef)_defaultsDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFPreferencesSynchronize((__bridge CFStringRef)_defaultsDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    }
}

- (BOOL)boolForUserDefaultsKey:(NSString *)defaultName
{
    if (_usesStandardUserDefaults) {
        return [[NSUserDefaults standardUserDefaults] boolForKey:defaultName];
    }

    BOOL value;
    CFPropertyListRef plr = CFPreferencesCopyAppValue((__bridge CFStringRef)defaultName, (__bridge CFStringRef)_defaultsDomain);
    if (plr == NULL) {
        value = NO;
	}
	else
	{
        value = CFBooleanGetValue((CFBooleanRef)plr) ? YES : NO;
        CFRelease(plr);
    }
    return value;
}

- (void)setBool:(BOOL)value forUserDefaultsKey:(NSString *)defaultName
{
	if (_usesStandardUserDefaults)
	{
        [[NSUserDefaults standardUserDefaults] setBool:value forKey:defaultName];
	}
	else
	{
        CFPreferencesSetValue((__bridge CFStringRef)defaultName, (__bridge CFBooleanRef) @(value), (__bridge CFStringRef)_defaultsDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFPreferencesSynchronize((__bridge CFStringRef)_defaultsDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    }
}

- (nullable id)objectForKey:(NSString *)key {
    return [self objectForUserDefaultsKey:key] ? [self objectForUserDefaultsKey:key] : [self objectForInfoDictionaryKey:key];
}

- (BOOL)boolForKey:(NSString *)key {
    return [self objectForUserDefaultsKey:key] ? [self boolForUserDefaultsKey:key] : [self boolForInfoDictionaryKey:key];
}

@end

NS_ASSUME_NONNULL_END
