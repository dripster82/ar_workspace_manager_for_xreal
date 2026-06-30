#pragma once
// Declarations for the private CGVirtualDisplay API in CoreGraphics.
// Selectors/properties match the runtime classes as used by DeskPad/BetterDisplay.
// Private API — personal-use app only.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface CGVirtualDisplayMode : NSObject
@property(readonly, nonatomic) unsigned int width;
@property(readonly, nonatomic) unsigned int height;
@property(readonly, nonatomic) double refreshRate;
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic) unsigned int hiDPI;
@property(retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
- (instancetype)init;
@end

@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@property(retain, nonatomic) dispatch_queue_t queue;
@property(copy, nonatomic) void (^terminationHandler)(id sender, CGVirtualDisplay *display);
- (instancetype)init;
@end

@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

// Live system-cursor scaling via the private SkyLight/CoreGraphics CGSSetCursorScale API
// (resolved at runtime with dlsym). Scales the actual hardware cursor, so ScreenCaptureKit
// captures the enlarged cursor straight into the glasses. 1.0 = normal; accessibility max ≈ 4.0.
float VRDGetCursorScale(void);
void VRDSetCursorScale(float scale);

// Run `block`, catching any Objective-C NSException it raises (e.g. AVAudioEngine's installTap/start,
// which raise instead of returning errors, so Swift's do/catch can't stop them). Returns YES on
// success; on an exception returns NO and sets *reason to the exception's reason/name.
BOOL VRDRunCatchingNSException(void (^block)(void), NSString * _Nullable * _Nullable reason);

NS_ASSUME_NONNULL_END
