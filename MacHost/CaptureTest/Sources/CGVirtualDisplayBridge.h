//
//  CGVirtualDisplayBridge.h
//  Virtual Display Bridge for Private CoreGraphics API
//

#ifndef CGVirtualDisplayBridge_h
#define CGVirtualDisplayBridge_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Forward declarations for CGVirtualDisplay private API

NS_ASSUME_NONNULL_BEGIN

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, assign) uint32_t vendorID;
@property (nonatomic, assign) uint32_t productID;
@property (nonatomic, assign) uint32_t serialNum;
@property (nonatomic, retain) NSString *name;
@property (nonatomic, assign) CGSize sizeInMillimeters;
@property (nonatomic, assign) uint32_t maxPixelsWide;
@property (nonatomic, assign) uint32_t maxPixelsHigh;
@property (nonatomic, assign) CGPoint redPrimary;
@property (nonatomic, assign) CGPoint greenPrimary;
@property (nonatomic, assign) CGPoint bluePrimary;
@property (nonatomic, assign) CGPoint whitePoint;
@property (nonatomic, retain, nullable) dispatch_queue_t queue;
@property (nonatomic, copy, nullable) void (^terminationHandler)(void);

- (instancetype)init;
@end

@interface CGVirtualDisplayMode : NSObject
@property (nonatomic, readonly) uint32_t width;
@property (nonatomic, readonly) uint32_t height;
@property (nonatomic, readonly) double refreshRate;

- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, assign) uint32_t hiDPI;
@property (nonatomic, retain) NSArray<CGVirtualDisplayMode *> *modes;

- (instancetype)init;
@end

@interface CGVirtualDisplay : NSObject
@property (nonatomic, readonly) uint32_t displayID;
@property (nonatomic, readonly) uint32_t vendorID;
@property (nonatomic, readonly) uint32_t productID;
@property (nonatomic, readonly) uint32_t serialNum;
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) CGSize sizeInMillimeters;
@property (nonatomic, readonly) uint32_t maxPixelsWide;
@property (nonatomic, readonly) uint32_t maxPixelsHigh;
@property (nonatomic, readonly) uint32_t hiDPI;
@property (nonatomic, readonly) NSArray<CGVirtualDisplayMode *> *modes;

- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

NS_ASSUME_NONNULL_END

#endif /* CGVirtualDisplayBridge_h */
