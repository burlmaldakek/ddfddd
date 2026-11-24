//
//  bridge.h
//  Erosion
//
//  Created by lunginspector on 8/14/26.
//

#ifndef bridge_h
#define bridge_h

#import "Exploits/bad_query.h"
#import "Exploits/worse_query.h"
#import "Exploits/pathleak.h"
#import "Experimental/Airlift/airlift.h"
#import "Experimental/Airlift/GrappaHelper.h"
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>

// Private Security task APIs used by the original Worse Query App Group lookup.
typedef struct CF_BRIDGED_TYPE(id) __SecTask *SecTaskRef;

SecTaskRef _Nullable SecTaskCreateFromSelf(CFAllocatorRef _Nullable allocator) CF_RETURNS_RETAINED;

CFTypeRef _Nullable SecTaskCopyValueForEntitlement(
    SecTaskRef _Nonnull task,
    CFStringRef _Nonnull entitlement,
    CFErrorRef _Nullable * _Nullable error
) CF_RETURNS_RETAINED;

/// Objective-C bridge for CoreUI asset catalogs. The private CoreUI selectors
/// are invoked with their native Objective-C / Core Graphics return types.
@interface ErosionCARCatalog : NSObject
@property (nonatomic, copy, readonly) NSArray<NSString *> *assetNames;
@property (nonatomic, strong, readonly, nullable) NSError *openError;
- (instancetype)initWithURL:(NSURL *)url;
- (nullable UIImage *)imageNamed:(NSString *)name;
- (nullable UIImage *)thumbnailNamed:(NSString *)name maximumPixelSize:(NSInteger)maximumPixelSize;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (bool)openApplicationWithBundleID:(NSString*)bundleID;
@end

#endif /* bridge_h */
