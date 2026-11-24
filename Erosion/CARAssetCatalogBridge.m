#import "bridge.h"
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <math.h>
#include <stdint.h>

// Private CoreUI declarations. The implementation is resolved at runtime
// from Apple's CoreUI.framework; no private framework is linked at build time.
@interface NSObject (ErosionCoreUIPrivate)
- (instancetype)initWithURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error;
- (NSArray<NSString *> * _Nullable)allImageNames;
- (void)enumerateNamedLookupsUsingBlock:(void (^)(id lookup))block;
- (id _Nullable)imageWithName:(NSString *)name scaleFactor:(CGFloat)scaleFactor;
- (NSArray * _Nullable)imagesWithName:(NSString *)name;
- (NSString * _Nullable)name;
- (CGImageRef _Nullable)croppedImage;
- (id _Nullable)imageObj;
- (BOOL)isVectorBased;
- (CGImageRef _Nullable)createImageFromPDFRenditionWithScale:(CGFloat)scale;
- (CGPDFDocumentRef _Nullable)pdfDocument;
- (CGImageRef _Nullable)rasterizeImageUsingScaleFactor:(CGFloat)scaleFactor forTargetSize:(CGSize)targetSize;
@end

// Keep CUINamedImage selectors off NSObject's untyped surface. Apple SDKs
// declare other `image` and `scale` selectors with incompatible return types
// (for example CIImage * and short), so the protocol gives Clang the exact
// CoreUI ABI when messaging a bitmap rendition.
@protocol ErosionCUINamedBitmapRendition <NSObject>
- (CGImageRef)image;
- (CGFloat)scale;
@end

static NSString * const ErosionCARCatalogErrorDomain = @"com.erosion.car-catalog";
static void *ErosionCoreUIFrameworkHandle = NULL;
static dispatch_queue_t ErosionCoreUIQueue;
static dispatch_once_t ErosionCoreUIQueueOnce;

static dispatch_queue_t ErosionGetCoreUIQueue(void) {
    dispatch_once(&ErosionCoreUIQueueOnce, ^{
        ErosionCoreUIQueue = dispatch_queue_create("com.erosion.car-catalog.coreui", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(ErosionCoreUIQueue, &ErosionCoreUIQueueOnce, &ErosionCoreUIQueueOnce, NULL);
    });
    return ErosionCoreUIQueue;
}

static BOOL ErosionIsOnCoreUIQueue(void) {
    return dispatch_get_specific(&ErosionCoreUIQueueOnce) == &ErosionCoreUIQueueOnce;
}

@interface ErosionCARCatalog ()
@property (nonatomic, copy, readwrite) NSArray<NSString *> *assetNames;
@property (nonatomic, strong, readwrite, nullable) NSError *openError;
@property (nonatomic, strong) dispatch_queue_t coreUIQueue;
@property (nonatomic, strong, nullable) id coreCatalog;
@property (nonatomic, copy) NSDictionary<NSString *, NSArray *> *renditionsByName;
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *imageCache;
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *thumbnailCache;
@end

@implementation ErosionCARCatalog

- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (!self) return nil;

    _assetNames = @[];
    _renditionsByName = @{};
    _coreUIQueue = ErosionGetCoreUIQueue();
    _imageCache = [[NSCache alloc] init];
    _imageCache.countLimit = 6;
    _imageCache.totalCostLimit = 96 * 1024 * 1024;
    _thumbnailCache = [[NSCache alloc] init];
    _thumbnailCache.countLimit = 96;
    _thumbnailCache.totalCostLimit = 32 * 1024 * 1024;

    dispatch_sync(_coreUIQueue, ^{
        @autoreleasepool {
            if (ErosionCoreUIFrameworkHandle == NULL) {
                ErosionCoreUIFrameworkHandle = dlopen(
                    "/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI",
                    RTLD_NOW | RTLD_LOCAL
                );
            }
            if (ErosionCoreUIFrameworkHandle == NULL) {
                self.openError = [NSError errorWithDomain:ErosionCARCatalogErrorDomain
                                                      code:1
                                                  userInfo:@{NSLocalizedDescriptionKey: @"Apple CoreUI is unavailable on this iOS version."}];
                return;
            }

            Class catalogClass = NSClassFromString(@"CUICatalog");
            Class namedImageClass = NSClassFromString(@"CUINamedImage");
            Class namedVectorClass = NSClassFromString(@"CUINamedVectorImage");
            if (catalogClass == Nil || namedImageClass == Nil) {
                self.openError = [NSError errorWithDomain:ErosionCARCatalogErrorDomain
                                                      code:2
                                                  userInfo:@{NSLocalizedDescriptionKey: @"CoreUI could not load its image catalog classes."}];
                return;
            }

            NSError *catalogError = nil;
            id openedCatalog = [[catalogClass alloc] initWithURL:url error:&catalogError];
            if (openedCatalog == nil) {
                self.openError = catalogError ?: [NSError errorWithDomain:ErosionCARCatalogErrorDomain
                                                                       code:3
                                                                   userInfo:@{NSLocalizedDescriptionKey: @"CoreUI could not open this asset catalog."}];
                return;
            }
            self.coreCatalog = openedCatalog;

            // Enumerate actual image renditions rather than asking CoreUI to
            // resolve every name for the current device traits. This includes
            // the real bitmap/vector objects and their scale variants.
            NSMutableDictionary<NSString *, NSMutableArray *> *lookups = [[NSMutableDictionary alloc] init];
            [openedCatalog enumerateNamedLookupsUsingBlock:^(id lookup) {
                BOOL isBitmapImage = [lookup isKindOfClass:namedImageClass];
                BOOL isVectorImage = (namedVectorClass != Nil && [lookup isKindOfClass:namedVectorClass]);
                if (!isBitmapImage && !isVectorImage) return;

                NSString *name = [lookup name];
                if (![name isKindOfClass:[NSString class]] || name.length == 0) return;
                NSMutableArray *items = lookups[name];
                if (items == nil) {
                    items = [[NSMutableArray alloc] init];
                    lookups[name] = items;
                }
                [items addObject:lookup];
            }];

            // Keep names stable and only show entries for which CoreUI gave us
            // an image rendition. Non-image objects such as colors/data are
            // intentionally not presented as broken image tiles.
            NSArray<NSString *> *sortedNames = [[lookups allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
                return [left localizedStandardCompare:right];
            }];
            if (sortedNames.count == 0) {
                NSArray *rawNames = [openedCatalog allImageNames];
                self.openError = [NSError errorWithDomain:ErosionCARCatalogErrorDomain
                                                      code:4
                                                  userInfo:@{NSLocalizedDescriptionKey: rawNames.count > 0 ? @"CoreUI listed image names but did not expose image renditions for them." : @"No image renditions were found in this catalog."}];
                return;
            }

            NSMutableDictionary<NSString *, NSArray *> *immutableLookups = [[NSMutableDictionary alloc] initWithCapacity:lookups.count];
            [lookups enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSMutableArray *value, BOOL *stop) {
                immutableLookups[key] = [value copy];
            }];
            self.renditionsByName = [immutableLookups copy];
            self.assetNames = sortedNames;
        }
    });

    return self;
}

- (UIImage *)imageNamed:(NSString *)name {
    if (name.length == 0 || self.coreCatalog == nil) return nil;
    UIImage *cached = [self.imageCache objectForKey:name];
    if (cached != nil) return cached;

    __block UIImage *result = nil;
    dispatch_block_t work = ^{
        @autoreleasepool {
            UIImage *secondCheck = [self.imageCache objectForKey:name];
            if (secondCheck != nil) {
                result = secondCheck;
                return;
            }
            result = [self resolveImageNamedOnCoreUIQueue:name maximumPixelSize:4096];
            if (result != nil) {
                [self.imageCache setObject:result forKey:name cost:[self imageCost:result]];
            }
        }
    };
    if (ErosionIsOnCoreUIQueue()) work();
    else dispatch_sync(self.coreUIQueue, work);
    return result;
}

- (UIImage *)thumbnailNamed:(NSString *)name maximumPixelSize:(NSInteger)maximumPixelSize {
    if (name.length == 0 || self.coreCatalog == nil) return nil;
    NSInteger safeSize = MAX(32, MIN(maximumPixelSize, 512));
    NSString *cacheKey = [NSString stringWithFormat:@"%ld:%@", (long)safeSize, name];
    UIImage *cached = [self.thumbnailCache objectForKey:cacheKey];
    if (cached != nil) return cached;

    __block UIImage *result = nil;
    dispatch_block_t work = ^{
        @autoreleasepool {
            UIImage *secondCheck = [self.thumbnailCache objectForKey:cacheKey];
            if (secondCheck != nil) {
                result = secondCheck;
                return;
            }
            UIImage *source = [self resolveImageNamedOnCoreUIQueue:name maximumPixelSize:(NSUInteger)safeSize];
            result = [self thumbnailFromImage:source maximumPixelSize:(size_t)safeSize];
            if (result != nil) {
                [self.thumbnailCache setObject:result forKey:cacheKey cost:[self imageCost:result]];
            }
        }
    };
    if (ErosionIsOnCoreUIQueue()) work();
    else dispatch_sync(self.coreUIQueue, work);
    return result;
}

- (UIImage *)resolveImageNamedOnCoreUIQueue:(NSString *)name maximumPixelSize:(NSUInteger)maximumPixelSize {
    NSArray *renditions = self.renditionsByName[name];
    if (renditions.count == 0) return nil;

    UIImage *bestImage = nil;
    unsigned long long bestArea = 0;
    for (id rendition in renditions) {
        UIImage *candidate = [self uiImageFromRendition:rendition maximumPixelSize:maximumPixelSize];
        if (candidate == nil) continue;

        CGImageRef cgImage = candidate.CGImage;
        unsigned long long area = cgImage != NULL
            ? (unsigned long long)CGImageGetWidth(cgImage) * (unsigned long long)CGImageGetHeight(cgImage)
            : (unsigned long long)MAX(1.0, candidate.size.width * candidate.scale) * (unsigned long long)MAX(1.0, candidate.size.height * candidate.scale);
        if (area > bestArea) {
            bestArea = area;
            bestImage = candidate;
        }
    }
    return bestImage;
}

- (UIImage *)uiImageFromRendition:(id)rendition maximumPixelSize:(NSUInteger)maximumPixelSize {
    if (rendition == nil) return nil;
    if ([rendition isKindOfClass:[UIImage class]]) return (UIImage *)rendition;

    // CUINamedImage (including its bitmap subclasses) exposes a CGImageRef
    // and CGFloat scale. Do not send these selectors to CUINamedVectorImage:
    // its image-related API is different and must use the vector/PDF path below.
    CGImageRef cgImage = NULL;
    CGFloat imageScale = 1.0;
    Class namedImageClass = NSClassFromString(@"CUINamedImage");
    BOOL isBitmapRendition = namedImageClass != Nil && [rendition isKindOfClass:namedImageClass];
    if (isBitmapRendition) {
        id<ErosionCUINamedBitmapRendition> bitmapRendition = (id<ErosionCUINamedBitmapRendition>)rendition;
        if ([rendition respondsToSelector:@selector(image)]) {
            cgImage = [bitmapRendition image];
        }
        if (cgImage == NULL && [rendition respondsToSelector:@selector(croppedImage)]) {
            cgImage = [rendition croppedImage];
        }

        if ([rendition respondsToSelector:@selector(scale)]) {
            CGFloat renditionScale = [bitmapRendition scale];
            if (isfinite(renditionScale) && renditionScale > 0.0 && renditionScale <= 8.0) {
                imageScale = renditionScale;
            }
        }
    }

    // Vector/PDF-backed renditions need an explicit rasterization request;
    // their inherited -image can legitimately be NULL.
    if (cgImage == NULL && [rendition respondsToSelector:@selector(rasterizeImageUsingScaleFactor:forTargetSize:)]) {
        CGSize targetSize = [self targetSizeForVectorRendition:rendition maximumPixelSize:maximumPixelSize];
        cgImage = [rendition rasterizeImageUsingScaleFactor:3.0 forTargetSize:targetSize];
        imageScale = 1.0;
    }
    if (cgImage == NULL && [rendition respondsToSelector:@selector(createImageFromPDFRenditionWithScale:)]) {
        CGFloat rasterScale = MIN(3.0, MAX(1.0, (CGFloat)maximumPixelSize / 1024.0));
        cgImage = [rendition createImageFromPDFRenditionWithScale:rasterScale];
        imageScale = 1.0;
    }

    // UIKit's object wrapper is a fallback for renditions whose CoreUI
    // CGImage getter is unavailable on a particular iOS build.
    if (cgImage == NULL) {
        SEL imageObjectSelector = NSSelectorFromString(@"imageObj");
        if ([rendition respondsToSelector:imageObjectSelector]) {
            id imageObject = [rendition imageObj];
            if ([imageObject isKindOfClass:[UIImage class]]) return (UIImage *)imageObject;
        }
    }

    if (cgImage == NULL) return nil;
    return [UIImage imageWithCGImage:cgImage scale:imageScale orientation:UIImageOrientationUp];
}

- (CGSize)targetSizeForVectorRendition:(id)rendition maximumPixelSize:(NSUInteger)maximumPixelSize {
    CGFloat maximumPoints = MAX(1.0, (CGFloat)maximumPixelSize / 3.0);
    CGSize naturalSize = CGSizeZero;
    if ([rendition respondsToSelector:@selector(pdfDocument)]) {
        CGPDFDocumentRef document = [rendition pdfDocument];
        if (document != NULL && CGPDFDocumentGetNumberOfPages(document) > 0) {
            CGPDFPageRef page = CGPDFDocumentGetPage(document, 1);
            if (page != NULL) {
                CGRect bounds = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);
                if (CGRectIsNull(bounds) || CGRectIsEmpty(bounds)) bounds = CGPDFPageGetBoxRect(page, kCGPDFCropBox);
                if (!CGRectIsNull(bounds) && !CGRectIsEmpty(bounds)) {
                    naturalSize = CGSizeMake(fabs(bounds.size.width), fabs(bounds.size.height));
                }
            }
        }
    }
    if (naturalSize.width <= 0 || naturalSize.height <= 0) {
        naturalSize = CGSizeMake(maximumPoints, maximumPoints);
    }
    CGFloat longestSide = MAX(naturalSize.width, naturalSize.height);
    CGFloat fit = MIN(1.0, maximumPoints / MAX(1.0, longestSide));
    return CGSizeMake(MAX(1.0, naturalSize.width * fit), MAX(1.0, naturalSize.height * fit));
}

- (UIImage *)thumbnailFromImage:(UIImage *)image maximumPixelSize:(size_t)maximumPixelSize {
    CGImageRef source = image.CGImage;
    if (source == NULL) return image;

    size_t sourceWidth = CGImageGetWidth(source);
    size_t sourceHeight = CGImageGetHeight(source);
    size_t longestSide = MAX(sourceWidth, sourceHeight);
    if (longestSide == 0) return nil;

    CGFloat factor = MIN(1.0, (CGFloat)maximumPixelSize / (CGFloat)longestSide);
    size_t targetWidth = MAX((size_t)1, (size_t)llround((CGFloat)sourceWidth * factor));
    size_t targetHeight = MAX((size_t)1, (size_t)llround((CGFloat)sourceHeight * factor));

    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (colorSpace == NULL) colorSpace = CGColorSpaceCreateDeviceRGB();
    if (colorSpace == NULL) return nil;

    CGContextRef context = CGBitmapContextCreate(
        NULL,
        targetWidth,
        targetHeight,
        8,
        0,
        colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    CGColorSpaceRelease(colorSpace);
    if (context == NULL) return nil;

    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextSetShouldAntialias(context, true);
    CGContextDrawImage(context, CGRectMake(0, 0, targetWidth, targetHeight), source);
    CGImageRef thumbnailCGImage = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (thumbnailCGImage == NULL) return nil;

    UIImage *thumbnail = [UIImage imageWithCGImage:thumbnailCGImage scale:1.0 orientation:UIImageOrientationUp];
    CGImageRelease(thumbnailCGImage);
    return thumbnail;
}

- (NSUInteger)imageCost:(UIImage *)image {
    CGImageRef cgImage = image.CGImage;
    if (cgImage == NULL) return 1;
    size_t rowBytes = CGImageGetBytesPerRow(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    if (height != 0 && rowBytes > NSUIntegerMax / height) return NSUIntegerMax;
    return MAX((NSUInteger)1, rowBytes * height);
}

- (void)dealloc {
    // Release CoreUI catalog and rendition lookups on their serial queue.
    // Keeping the lookup array alive alongside the catalog also avoids
    // invalidating storage-backed objects while async thumbnail work is queued.
    id catalogToRelease = _coreCatalog;
    NSDictionary *renditionsToRelease = _renditionsByName;
    _coreCatalog = nil;
    _renditionsByName = @{};

    dispatch_queue_t queueToKeepAlive = _coreUIQueue;
    if (catalogToRelease != nil || renditionsToRelease.count > 0) {
        dispatch_block_t releaseWork = ^{
            (void)catalogToRelease;
            (void)renditionsToRelease;
        };
        if (queueToKeepAlive != nil && !ErosionIsOnCoreUIQueue()) {
            dispatch_async(queueToKeepAlive, releaseWork);
        } else {
            releaseWork();
        }
    }
}

@end
