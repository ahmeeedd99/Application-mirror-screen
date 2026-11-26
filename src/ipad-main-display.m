// ipad-main-display
//
// Background helper: when your iPad is plugged in over USB, start Sidecar
// (Apple's built-in iPad-as-display feature) and make the iPad the MAIN display.
// No clicking, no need to see the Mac's screen.
//
// Build:
//   clang -fobjc-arc -O2 -Wall -framework Foundation -framework CoreGraphics \
//         -framework IOKit -o ipad-main-display ipad-main-display.m
//
// Usage:
//   ipad-main-display [run] [--name "My iPad"] [--any-transport]   run forever (what launchd does)
//   ipad-main-display once   [--name ...]                          connect once, then exit 0
//   ipad-main-display doctor                                       print diagnostics
//
// Sidecar has no public API, so this talks to Apple's private SidecarCore
// framework through the Objective-C runtime. Every call is checked with
// respondsToSelector:, so if a macOS update renames something we log it
// (run `doctor`) instead of crashing.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

#define APPLE_USB_VENDOR 0x05AC

static NSString *gWantedName = nil;      // optional: only connect to a device whose name contains this
static BOOL gRequireUSB = YES;           // only act when an iPad is on the USB bus
static BOOL gExitAfterConnect = NO;      // `once` mode

// ---------------------------------------------------------------- Sidecar

static id SidecarManager(void) {
    static id mgr = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_LAZY);
        if (!h) { NSLog(@"ERROR: cannot load SidecarCore: %s", dlerror()); return; }
        Class c = NSClassFromString(@"SidecarDisplayManager");
        SEL s = NSSelectorFromString(@"sharedManager");
        if (!c || ![c respondsToSelector:s]) {
            NSLog(@"ERROR: SidecarDisplayManager/sharedManager not found (macOS changed? run `doctor`)");
            return;
        }
        mgr = [c performSelector:s];
    });
    return mgr;
}

static NSArray *SidecarArray(NSString *selName) {
    id m = SidecarManager();
    SEL s = NSSelectorFromString(selName);
    if (!m || ![m respondsToSelector:s]) return @[];
    id r = [m performSelector:s];
    return [r isKindOfClass:[NSArray class]] ? r : @[];
}

static NSString *DeviceName(id d) {
    SEL s = NSSelectorFromString(@"name");
    if (![d respondsToSelector:s]) return [d description];
    id n = [d performSelector:s];
    return [n isKindOfClass:[NSString class]] ? n : [d description];
}

static BOOL NameMatches(NSString *name) {
    if (gWantedName.length == 0) return YES;
    return [name rangeOfString:gWantedName options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static id FindDevice(void) {
    for (id d in SidecarArray(@"devices")) {
        if (NameMatches(DeviceName(d))) return d;
    }
    return nil;
}

static BOOL IsConnected(id device) {
    NSString *n = DeviceName(device);
    for (id d in SidecarArray(@"connectedDevices")) {
        if ([DeviceName(d) isEqualToString:n]) return YES;
    }
    return NO;
}

// ------------------------------------------------------------------- USB

// YES when something named "iPad" made by Apple is on the USB bus.
static BOOL IPadOnUSB(void) {
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(0, IOServiceMatching("IOUSBHostDevice"), &it) != KERN_SUCCESS) return NO;
    BOOL found = NO;
    io_object_t svc;
    while (!found && (svc = IOIteratorNext(it))) {
        id vendor = CFBridgingRelease(IORegistryEntryCreateCFProperty(svc, CFSTR("idVendor"), kCFAllocatorDefault, 0));
        id name = CFBridgingRelease(IORegistryEntryCreateCFProperty(svc, CFSTR("USB Product Name"), kCFAllocatorDefault, 0));
        if (!name) name = CFBridgingRelease(IORegistryEntryCreateCFProperty(svc, CFSTR("kUSBProductString"), kCFAllocatorDefault, 0));
        if ([vendor isKindOfClass:[NSNumber class]] && [vendor intValue] == APPLE_USB_VENDOR &&
            [name isKindOfClass:[NSString class]] &&
            [name rangeOfString:@"iPad" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            found = YES;
        }
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);
    return found;
}

// ------------------------------------------------------------- Displays

static NSArray<NSNumber *> *OnlineDisplays(void) {
    CGDirectDisplayID ids[32];
    uint32_t n = 0;
    if (CGGetOnlineDisplayList(32, ids, &n) != kCGErrorSuccess) return @[];
    NSMutableArray *a = [NSMutableArray array];
    for (uint32_t i = 0; i < n; i++) [a addObject:@(ids[i])];
    return a;
}

static NSSet<NSNumber *> *gBaseline = nil;           // displays that existed before we connected
static CGDirectDisplayID gIPadDisplay = kCGNullDirectDisplay;
static NSDate *gLastArrange = nil;

// Work out which online display is the iPad.
static CGDirectDisplayID FindIPadDisplay(void) {
    NSArray *online = OnlineDisplays();
    if (gIPadDisplay != kCGNullDirectDisplay && [online containsObject:@(gIPadDisplay)]) return gIPadDisplay;
    gIPadDisplay = kCGNullDirectDisplay;

    NSMutableArray *added = [NSMutableArray array], *external = [NSMutableArray array];
    for (NSNumber *n in online) {
        CGDirectDisplayID d = n.unsignedIntValue;
        if (CGDisplayIsBuiltin(d)) continue;
        [external addObject:n];
        if (gBaseline && ![gBaseline containsObject:n]) [added addObject:n];
    }
    if (added.count == 1) gIPadDisplay = [added[0] unsignedIntValue];
    else if (external.count == 1) gIPadDisplay = [external[0] unsignedIntValue];
    return gIPadDisplay;
}

// Make `ipad` the main display (origin 0,0, menu bar + Dock) and park the rest to its right.
static void MakeMain(CGDirectDisplayID ipad) {
    if (CGMainDisplayID() == ipad) return;
    if (gLastArrange && [[NSDate date] timeIntervalSinceDate:gLastArrange] < 10) return;  // don't thrash
    gLastArrange = [NSDate date];

    CGDisplayConfigRef cfg = NULL;
    if (CGBeginDisplayConfiguration(&cfg) != kCGErrorSuccess) { NSLog(@"WARN: CGBeginDisplayConfiguration failed"); return; }
    if (CGDisplayIsInMirrorSet(ipad)) CGConfigureDisplayMirrorOfDisplay(cfg, ipad, kCGNullDirectDisplay);
    CGConfigureDisplayOrigin(cfg, ipad, 0, 0);
    CGFloat x = CGDisplayBounds(ipad).size.width;
    for (NSNumber *n in OnlineDisplays()) {
        CGDirectDisplayID d = n.unsignedIntValue;
        if (d == ipad) continue;
        if (CGDisplayIsInMirrorSet(d) && CGDisplayMirrorsDisplay(d) == ipad) continue;
        CGConfigureDisplayOrigin(cfg, d, (int32_t)x, 0);
        x += CGDisplayBounds(d).size.width;
    }
    CGError e = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
    if (e != kCGErrorSuccess) { CGCancelDisplayConfiguration(cfg); NSLog(@"WARN: could not rearrange displays (error %d)", e); }
    else NSLog(@"iPad display %u is now the main display", ipad);
}

// ----------------------------------------------------------- State loop

static BOOL gConnecting = NO;
static NSDate *gConnectStarted = nil;
static NSDate *gNextAttempt = nil;
static NSTimeInterval gBackoff = 3;
static NSString *gLastStatus = nil;

static void Status(NSString *s) {            // log only when the state changes
    if ([s isEqualToString:gLastStatus]) return;
    gLastStatus = s;
    NSLog(@"%@", s);
}

static void Connect(id device) {
    id m = SidecarManager();
    SEL s = NSSelectorFromString(@"connectToDevice:completion:");
    if (![m respondsToSelector:s]) {
        Status(@"ERROR: connectToDevice:completion: is missing on this macOS. Run `doctor` and send me the output.");
        gNextAttempt = [NSDate dateWithTimeIntervalSinceNow:60];
        return;
    }
    gBaseline = [NSSet setWithArray:OnlineDisplays()];
    gIPadDisplay = kCGNullDirectDisplay;
    gConnecting = YES;
    gConnectStarted = [NSDate date];
    NSLog(@"Connecting to \"%@\" ...", DeviceName(device));
    void (^done)(id) = ^(id error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            gConnecting = NO;
            if (error) {
                NSLog(@"Connect failed: %@ (retrying in %.0fs)", error, gBackoff);
                gNextAttempt = [NSDate dateWithTimeIntervalSinceNow:gBackoff];
                gBackoff = MIN(gBackoff * 2, 30);
            } else {
                NSLog(@"Sidecar connected");
                gBackoff = 3;
            }
        });
    };
    [m performSelector:s withObject:device withObject:done];
}

static void Tick(void) {
    if (gConnecting) {
        if ([[NSDate date] timeIntervalSinceDate:gConnectStarted] > 45) {
            NSLog(@"Connect attempt hung for 45s, giving up on it");
            gConnecting = NO;
            gNextAttempt = [NSDate dateWithTimeIntervalSinceNow:gBackoff];
        }
        return;
    }
    if (!SidecarManager()) { Status(@"ERROR: Sidecar not available, exiting so launchd restarts me"); exit(1); }

    if (gRequireUSB && !IPadOnUSB()) {
        gIPadDisplay = kCGNullDirectDisplay;
        gBackoff = 3;
        Status(@"Waiting for an iPad on USB");
        return;
    }

    id dev = FindDevice();
    if (!dev) {
        Status(@"iPad is plugged in but Sidecar does not list it yet. Unlock the iPad, tap Trust, and use the same Apple ID on both.");
        return;
    }

    if (IsConnected(dev)) {
        Status([NSString stringWithFormat:@"Connected to \"%@\"", DeviceName(dev)]);
        CGDirectDisplayID ipad = FindIPadDisplay();
        if (ipad != kCGNullDirectDisplay) {
            MakeMain(ipad);
            if (gExitAfterConnect && CGMainDisplayID() == ipad) exit(0);
        }
        return;
    }

    if (gNextAttempt && [gNextAttempt timeIntervalSinceNow] > 0) return;
    Status([NSString stringWithFormat:@"Found \"%@\"", DeviceName(dev)]);
    Connect(dev);
}

// --------------------------------------------------------------- Doctor

static void Doctor(void) {
    printf("== SidecarCore ==\n");
    id m = SidecarManager();
    printf("manager: %s\n", m ? [[m description] UTF8String] : "NOT AVAILABLE");
    if (m) {
        unsigned n = 0;
        Method *ms = class_copyMethodList([m class], &n);
        printf("methods (%u):\n", n);
        for (unsigned i = 0; i < n; i++) printf("  %s\n", sel_getName(method_getName(ms[i])));
        free(ms);
        for (id d in SidecarArray(@"devices")) printf("device: %s\n", [DeviceName(d) UTF8String]);
        for (id d in SidecarArray(@"connectedDevices")) printf("connected: %s\n", [DeviceName(d) UTF8String]);
    }
    printf("\n== USB ==\niPad on USB: %s\n", IPadOnUSB() ? "yes" : "no");
    printf("\n== Displays ==\n");
    for (NSNumber *n in OnlineDisplays()) {
        CGDirectDisplayID d = n.unsignedIntValue;
        CGRect b = CGDisplayBounds(d);
        printf("id %u builtin=%d main=%d bounds=%.0fx%.0f@(%.0f,%.0f)\n", d, CGDisplayIsBuiltin(d),
               CGMainDisplayID() == d, b.size.width, b.size.height, b.origin.x, b.origin.y);
    }
}

// ----------------------------------------------------------------- main

int main(int argc, const char **argv) {
    @autoreleasepool {
        BOOL doctor = NO;
        for (int i = 1; i < argc; i++) {
            NSString *a = @(argv[i]);
            if ([a isEqualToString:@"doctor"]) doctor = YES;
            else if ([a isEqualToString:@"once"]) gExitAfterConnect = YES;
            else if ([a isEqualToString:@"--any-transport"]) gRequireUSB = NO;
            else if ([a isEqualToString:@"--name"] && i + 1 < argc) gWantedName = @(argv[++i]);
        }
        if (doctor) { Doctor(); return 0; }

        NSLog(@"ipad-main-display started (usb-only=%d, name=%@)", gRequireUSB, gWantedName ?: @"any");
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
        dispatch_source_set_event_handler(timer, ^{ Tick(); });
        dispatch_resume(timer);
        if (gExitAfterConnect) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                NSLog(@"Timed out waiting for the iPad"); exit(1);
            });
        }
        dispatch_main();
    }
}
