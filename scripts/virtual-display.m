// Review screenshots only (scripts/screenshots.sh, `hidpi_display`): GitHub's hosted macOS runner has one 1x display
// with no HiDPI mode, so the Mac windows were captured at 1x. This keeps a 1440x900 pt HiDPI (2x) virtual display alive
// until it is killed, so the Mac review frames are the window at its native 2x. CoreGraphics' virtual display classes
// are not in the public headers; their interfaces are declared here. Never part of an app target.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) dispatch_queue_t queue;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@property(copy, nonatomic) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(readonly, nonatomic) unsigned int displayID;
@end

int main(void) {
    @autoreleasepool {
        CGVirtualDisplayDescriptor *descriptor = [[CGVirtualDisplayDescriptor alloc] init];
        descriptor.queue = dispatch_get_main_queue();
        descriptor.name = @"Review 2x";
        descriptor.maxPixelsWide = 2880;
        descriptor.maxPixelsHigh = 1800;
        descriptor.sizeInMillimeters = CGSizeMake(331, 207);
        descriptor.vendorID = 0x1234;
        descriptor.productID = 0x5678;
        descriptor.serialNum = 1;
        descriptor.terminationHandler = ^(id display, id error) { exit(1); };

        CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
        if (display == nil || display.displayID == 0) {
            fprintf(stderr, "virtual display: not created\n");
            return 1;
        }
        CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
        settings.hiDPI = 1;
        settings.modes = @[ [[CGVirtualDisplayMode alloc] initWithWidth:1440 height:900 refreshRate:60] ];
        if (![display applySettings:settings]) {
            fprintf(stderr, "virtual display: settings refused\n");
            return 1;
        }
        printf("%u\n", display.displayID);
        fflush(stdout);
        dispatch_main();
    }
}
