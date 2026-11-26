// ipad-main-display
//
// Background helper: when your iPad is plugged in over USB, start Sidecar
// (Apple's built-in iPad-as-display feature) and make the iPad the MAIN display.
// No clicking, no need to see the Mac's screen.
//
// Build (install.sh does this for you):
//   clang -fobjc-arc -O2 -Wall -framework Foundation -framework CoreGraphics \
//         -framework IOKit -o ipad-main-display ipad-main-display.m
//
// Usage:
//   ipad-main-display [run] [--name "My iPad"] [--any-transport]   run forever (what launchd does)
//   ipad-main-display once  [--name ...]                           connect once, then exit 0
//   ipad-main-display list                                         print Sidecar device names
//   ipad-main-display doctor                                       print diagnostics
//
// Safety properties (see README "Security"):
//   * runs as the logged-in user, refuses to run as root
//   * makes no network connections, spawns no processes, writes no files
//   * only ever asks Sidecar to connect to ONE device: the pinned/only one, never a guess
//   * only acts while an Apple "iPad" is on the USB bus (unless --any-transport)
//   * Sidecar has no public API: it is reached through the Objective-C runtime in
//     Apple's private SidecarCore framework, loaded from its absolute system path.
//     Every call is guarded with respondsToSelector:, so a macOS update that renames
//     something produces a log line (run `doctor`), not a crash.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <unistd.h>
#import <sys/stat.h>

#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

#define APPLE_USB_VENDOR   0x05AC
#define TICK_SECONDS       2
#define CONNECT_TIMEOUT    45
#define REARRANGE_MIN_GAP  30
#define LOG_MAX_BYTES      (512 * 1024)

static NSString *gWantedName = nil;   // optional pin: exact name, or unique substring
static BOOL gRequireUSB = YES;        // only act when an iPad is on the USB bus
static BOOL gExitAfterConnect = NO;   // `once` mode
static id gActivity = nil;            // keeps macOS from App-Napping our timer

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

// Pick exactly one device, or none. Never guess between several.
// `why` receives a human-readable reason when nothing is returned.
static id FindDevice(NSString **why) {
    NSArray *devs = SidecarArray(@"devices");
    if (devs.count == 0) { *why = @"Sidecar lists no devices yet"; return nil; }

    if (gWantedName.length == 0) {
        if (devs.count == 1) return devs[0];
        *why = [NSString stringWithFormat:@"%lu Sidecar devices are available and none is pinned. Re-run ./install.sh \"<iPad name>\" so I know which one to use.",
                (unsigned long)devs.count];
        return nil;
    }
    for (id d in devs) {
        if ([DeviceName(d) caseInsensitiveCompare:gWantedName] == NSOrderedSame) return d;
    }
    NSMutableArray *partial = [NSMutableArray array];
    for (id d in devs) {
        if ([DeviceName(d) rangeOfString:gWantedName options:NSCaseInsensitiveSearch].location != NSNotFound) [partial addObject:d];
    }
    if (partial.count == 1) return partial[0];
    *why = partial.count == 0
        ? [NSString stringWithFormat:@"no Sidecar device is named \"%@\" (yet)", gWantedName]
        : [NSString stringWithFormat:@"\"%@\" matches %lu devices; use a more exact name", gWantedName, (unsigned long)partial.count];
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

// YES when an Apple device whose USB product name contains "iPad" is on the bus.
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

static NSSet<NSNumber *> *gBaseline = nil;     // displays that existed before we connected
static CGDirectDisplayID gIPadDisplay = kCGNullDirectDisplay;
static NSDate *gLastArrange = nil;

// Work out which online display is the iPad.
static CGDirectDisplayID FindIPadDisplay(void) {
    NSArray *online = OnlineDisplays();
    if (gIPadDisplay != kCGNullDirectDisplay && [online containsObject:@(gIPadDisplay)]) return gIPadDisplay;
    gIPadDisplay = kCGNullDirectDisplay;

    NSMutableArray *added = [NSMutableArray array], *external = [NSMutableArray array];
    for (NSNumber *n in online) {
        if (CGDisplayIsBuiltin(n.unsignedIntValue)) continue;
        [external addObject:n];
        if (gBaseline && ![gBaseline containsObject:n]) [added addObject:n];
    }
    if (added.count == 1) gIPadDisplay = [added[0] unsignedIntValue];
    else if (external.count == 1) gIPadDisplay = [external[0] unsignedIntValue];
    return gIPadDisplay;
}

// One attempt to put `ipad` at the origin (= main display). Other displays are parked either
// diagonally at the iPad's corner (so the mouse cannot slide onto a dead panel) or, as a
// fallback, simply to its right.
static BOOL ApplyArrangement(CGDirectDisplayID ipad, BOOL cornerPark) {
    CGDisplayConfigRef cfg = NULL;
    if (CGBeginDisplayConfiguration(&cfg) != kCGErrorSuccess) return NO;
    if (CGDisplayIsInMirrorSet(ipad)) CGConfigureDisplayMirrorOfDisplay(cfg, ipad, kCGNullDirectDisplay);
    CGConfigureDisplayOrigin(cfg, ipad, 0, 0);

    CGRect ib = CGDisplayBounds(ipad);
    int32_t x = (int32_t)ib.size.width;
    int32_t y = cornerPark ? (int32_t)ib.size.height : 0;
    for (NSNumber *n in OnlineDisplays()) {
        CGDirectDisplayID d = n.unsignedIntValue;
        if (d == ipad) continue;
        CGConfigureDisplayOrigin(cfg, d, x, y);
        x += (int32_t)CGDisplayBounds(d).size.width;
    }
    CGError e = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
    if (e != kCGErrorSuccess) { CGCancelDisplayConfiguration(cfg); return NO; }
    return CGMainDisplayID() == ipad;
}

static void MakeMain(CGDirectDisplayID ipad) {
    if (CGMainDisplayID() == ipad) return;
    if (gLastArrange && [[NSDate date] timeIntervalSinceDate:gLastArrange] < REARRANGE_MIN_GAP) return;
    gLastArrange = [NSDate date];
    if (ApplyArrangement(ipad, YES) || ApplyArrangement(ipad, NO)) NSLog(@"iPad display %u is now the main display", ipad);
    else NSLog(@"WARN: could not make display %u the main display; will retry", ipad);
}

// ----------------------------------------------------------- State loop

static BOOL gConnecting = NO;
static NSDate *gConnectStarted = nil;
static NSDate *gNextAttempt = nil;
static NSTimeInterval gBackoff = 3;
static NSString *gLastStatus = nil;
static unsigned gTicks = 0;

static void Status(NSString *s) {            // log only when the state changes
    if ([s isEqualToString:gLastStatus]) return;
    gLastStatus = s;
    NSLog(@"%@", s);
}

// launchd opens our log file; keep it from growing forever.
static void TrimLog(void) {
    struct stat st;
    if (fstat(STDERR_FILENO, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > LOG_MAX_BYTES) {
        if (ftruncate(STDERR_FILENO, 0) == 0) NSLog(@"(log trimmed)");
    }
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
    if (++gTicks % 300 == 0) TrimLog();

    if (gConnecting) {
        if ([[NSDate date] timeIntervalSinceDate:gConnectStarted] > CONNECT_TIMEOUT) {
            NSLog(@"Connect attempt hung for %ds, giving up on it", CONNECT_TIMEOUT);
            gConnecting = NO;
            gNextAttempt = [NSDate dateWithTimeIntervalSinceNow:gBackoff];
        }
        return;
    }
    if (!SidecarManager()) { NSLog(@"ERROR: Sidecar not available; exiting so launchd restarts me"); exit(1); }

    if (gRequireUSB && !IPadOnUSB()) {
        gIPadDisplay = kCGNullDirectDisplay;
        gBackoff = 3;
        gNextAttempt = nil;
        Status(@"Waiting for an iPad on USB");
        return;
    }

    NSString *why = nil;
    id dev = FindDevice(&why);
    if (!dev) {
        Status([NSString stringWithFormat:@"iPad is plugged in but I cannot pick a Sidecar device: %@. (Unlock the iPad, tap Trust, same Apple ID on both.)", why]);
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

// ------------------------------------------------------- list / doctor

static void ListDevices(void) {
    for (id d in SidecarArray(@"devices")) printf("%s\n", [DeviceName(d) UTF8String]);
}

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
        printf("id %u builtin=%d main=%d bounds=%.0fx%.0f@(%.0f,%.0f)\n", d, CGDisplayIsBuiltin(d) ? 1 : 0,
               CGMainDisplayID() == d ? 1 : 0, b.size.width, b.size.height, b.origin.x, b.origin.y);
    }
}

// ----------------------------------------------------------------- main

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (geteuid() == 0) { fprintf(stderr, "Refusing to run as root. Run as your normal user.\n"); return 1; }

        BOOL doctor = NO, list = NO;
        for (int i = 1; i < argc; i++) {
            NSString *a = @(argv[i]);
            if ([a isEqualToString:@"doctor"]) doctor = YES;
            else if ([a isEqualToString:@"list"]) list = YES;
            else if ([a isEqualToString:@"once"]) gExitAfterConnect = YES;
            else if ([a isEqualToString:@"run"]) { /* default */ }
            else if ([a isEqualToString:@"--any-transport"]) gRequireUSB = NO;
            else if ([a isEqualToString:@"--name"] && i + 1 < argc) gWantedName = @(argv[++i]);
            else { fprintf(stderr, "Unknown argument: %s\n", argv[i]); return 2; }
        }
        if (doctor) { Doctor(); return 0; }
        if (list) { ListDevices(); return 0; }

        NSLog(@"ipad-main-display started (usb-only=%d, name=%@)", gRequireUSB, gWantedName ?: @"(not pinned)");
        TrimLog();
        gActivity = [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
                                                                    reason:@"Watching for iPad"];
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, TICK_SECONDS * NSEC_PER_SEC, NSEC_PER_SEC / 4);
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
