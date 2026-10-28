// AppKit core on UIKit: application lifecycle, windows, views, events, screens.
#import "RecompAppKit.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <crt_externs.h>
#import <os/lock.h>

id NSApp;
NSPoint RecompMouseLocation;
NSUInteger RecompPressedButtons;
NSUInteger RecompModifierFlags;

static CGSize gScreenSize;
static CGFloat gScreenScale = 1;
static RecompRootView *gRoot;

CGSize RecompScreenSize(void) {
    if (gScreenSize.width == 0) {
        // Before UIKit is up (static initialisers, main()): ask the screen directly.
        CGRect b = UIScreen.mainScreen.bounds;
        gScreenSize = CGSizeMake(MAX(b.size.width, b.size.height), MIN(b.size.width, b.size.height));
        gScreenScale = UIScreen.mainScreen.scale;
    }
    return gScreenSize;
}

CGFloat RecompScreenScale(void) { RecompScreenSize(); return gScreenScale; }
RecompRootView *RecompRoot(void) { return gRoot; }

void RecompOnMain(dispatch_block_t block) {
    if (NSThread.isMainThread) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

// --- unimplemented selectors ------------------------------------------------
// Messages our AppKit classes do not implement go to a black hole that
// returns zero (nil, NO, NSZeroRect) instead of raising, and are logged once.

__attribute__((naked)) static void RecompZeroIMP(void) {
    __asm__ volatile("mov x0, #0\n mov x1, #0\n movi d0, #0\n movi d1, #0\n movi d2, #0\n movi d3, #0\n ret");
}

@interface RecompBlackHole : NSObject
@end
@implementation RecompBlackHole
+ (BOOL)resolveInstanceMethod:(SEL)sel {
    class_addMethod(self, sel, (IMP)RecompZeroIMP, "v@:");
    return YES;
}
@end

static RecompBlackHole *gHole;
static NSMutableSet *gMissing;
static os_unfair_lock gMissingLock = OS_UNFAIR_LOCK_INIT;

id RecompMissing(id obj, SEL sel, BOOL isClass) {
    Class c = isClass ? (Class)obj : object_getClass(obj);
    NSString *key = [NSString stringWithFormat:@"%c[%s %s]", isClass ? '+' : '-', class_getName(c), sel_getName(sel)];
    os_unfair_lock_lock(&gMissingLock);
    if (!gMissing) gMissing = [NSMutableSet new];
    BOOL first = ![gMissing containsObject:key];
    if (first) [gMissing addObject:key];
    if (!gHole) gHole = [RecompBlackHole new];
    os_unfair_lock_unlock(&gMissingLock);
    if (first) RLOG(@"unimplemented %@ (returns 0)", key);
    return gHole;
}

#define RECOMP_FORWARDING \
    - (id)forwardingTargetForSelector:(SEL)sel { return RecompMissing(self, sel, NO); } \
    + (id)forwardingTargetForSelector:(SEL)sel { return RecompMissing(self, sel, YES); }

// --- NSResponder ----------------------------------------------------------------

@implementation RNSResponder
RECOMP_FORWARDING
- (BOOL)acceptsFirstResponder { return NO; }
- (BOOL)becomeFirstResponder { return YES; }
- (BOOL)resignFirstResponder { return YES; }
- (void)mouseDown:(id)e {} - (void)mouseUp:(id)e {} - (void)mouseDragged:(id)e {} - (void)mouseMoved:(id)e {}
- (void)rightMouseDown:(id)e {} - (void)rightMouseUp:(id)e {} - (void)rightMouseDragged:(id)e {}
- (void)otherMouseDown:(id)e {} - (void)otherMouseUp:(id)e {} - (void)otherMouseDragged:(id)e {}
- (void)mouseEntered:(id)e {} - (void)mouseExited:(id)e {} - (void)scrollWheel:(id)e {}
- (void)keyDown:(id)e {} - (void)keyUp:(id)e {} - (void)flagsChanged:(id)e {}
- (void)cursorUpdate:(id)e {}
- (BOOL)performKeyEquivalent:(id)e { return NO; }
- (void)interpretKeyEvents:(NSArray *)events {}
- (void)doCommandBySelector:(SEL)sel {}
- (id)menu { return nil; }
- (void)setMenu:(id)m {}
- (BOOL)tryToPerform:(SEL)a with:(id)o { return NO; }
- (id)undoManager { return nil; }
@end

// --- NSEvent ----------------------------------------------------------------------

static NSMutableArray *gLocalMonitors;   // of RecompMonitor
static os_unfair_lock gMonitorLock = OS_UNFAIR_LOCK_INIT;

@interface RecompMonitor : NSObject
@property unsigned long long mask;
@property (copy) RNSEvent * (^handler)(RNSEvent *);
@property BOOL global;
@end
@implementation RecompMonitor
@end

@implementation RNSEvent
RECOMP_FORWARDING
+ (RNSEvent *)recompEventWithType:(NSUInteger)type {
    RNSEvent *e = [RNSEvent new];
    e->_type = type;
    e->_timestamp = NSProcessInfo.processInfo.systemUptime;
    e->_modifierFlags = RecompModifierFlags;
    e->_clickCount = 1;
    return e;
}
+ (id)otherEventWithType:(NSUInteger)type location:(NSPoint)loc modifierFlags:(NSUInteger)flags timestamp:(NSTimeInterval)ts
            windowNumber:(NSInteger)wn context:(id)ctx subtype:(short)st data1:(NSInteger)d1 data2:(NSInteger)d2 {
    RNSEvent *e = [self recompEventWithType:type];
    e->_location = loc; e->_modifierFlags = flags; e->_timestamp = ts; e->_windowNumber = wn;
    e->_subtype = st; e->_data1 = d1; e->_data2 = d2;
    return e;
}
+ (id)addLocalMonitorForEventsMatchingMask:(unsigned long long)mask handler:(RNSEvent * (^)(RNSEvent *))handler {
    RecompMonitor *m = [RecompMonitor new];
    m.mask = mask; m.handler = handler;
    os_unfair_lock_lock(&gMonitorLock);
    if (!gLocalMonitors) gLocalMonitors = [NSMutableArray new];
    [gLocalMonitors addObject:m];
    os_unfair_lock_unlock(&gMonitorLock);
    return m;
}
+ (id)addGlobalMonitorForEventsMatchingMask:(unsigned long long)mask handler:(void (^)(RNSEvent *))handler {
    // Global monitors see events sent to other apps; there are none on iOS.
    RecompMonitor *m = [RecompMonitor new];
    m.global = YES;
    return m;
}
+ (void)removeMonitor:(id)monitor {
    os_unfair_lock_lock(&gMonitorLock);
    [gLocalMonitors removeObject:monitor];
    os_unfair_lock_unlock(&gMonitorLock);
}
+ (NSPoint)mouseLocation { return RecompMouseLocation; }
+ (NSUInteger)pressedMouseButtons { return RecompPressedButtons; }
+ (NSUInteger)modifierFlags { return RecompModifierFlags; }
+ (NSTimeInterval)doubleClickInterval { return 0.5; }
+ (NSTimeInterval)keyRepeatDelay { return 0.5; }
+ (NSTimeInterval)keyRepeatInterval { return 0.083; }
+ (BOOL)isMouseCoalescingEnabled { return NO; }
+ (void)setMouseCoalescingEnabled:(BOOL)e {}
+ (BOOL)isSwipeTrackingFromScrollEventsEnabled { return NO; }
- (NSUInteger)type { return _type; }
- (NSUInteger)modifierFlags { return _modifierFlags; }
- (NSTimeInterval)timestamp { return _timestamp; }
- (id)window { return _window; }
- (NSInteger)windowNumber { return _window ? _window.windowNumber : _windowNumber; }
- (NSPoint)locationInWindow { return _location; }
- (unsigned short)keyCode { return (unsigned short)_keyCode; }
- (NSString *)characters { return _characters ?: @""; }
- (NSString *)charactersIgnoringModifiers { return _charactersIgnoringModifiers ?: @""; }
- (NSString *)charactersByApplyingModifiers:(NSUInteger)m { return self.charactersIgnoringModifiers; }
- (BOOL)isARepeat { return _repeat; }
- (NSInteger)buttonNumber { return _buttonNumber; }
- (NSInteger)clickCount { return _clickCount; }
- (CGFloat)deltaX { return _deltaX; }
- (CGFloat)deltaY { return _deltaY; }
- (CGFloat)deltaZ { return 0; }
- (CGFloat)scrollingDeltaX { return _scrollX; }
- (CGFloat)scrollingDeltaY { return _scrollY; }
- (BOOL)hasPreciseScrollingDeltas { return _precise; }
- (NSUInteger)phase { return _phase; }
- (NSUInteger)momentumPhase { return _momentumPhase; }
- (BOOL)isDirectionInvertedFromDevice { return NO; }
- (short)subtype { return (short)_subtype; }
- (NSInteger)data1 { return _data1; }
- (NSInteger)data2 { return _data2; }
- (float)pressure { return RecompPressedButtons ? 1 : 0; }
- (CGFloat)magnification { return 0; }
- (float)rotation { return 0; }
- (NSInteger)eventNumber { return 0; }
- (void *)CGEvent { return NULL; }
- (id)trackingArea { return nil; }
- (NSUInteger)subtypeValue { return _subtype; }
- (NSString *)description {
    return [NSString stringWithFormat:@"<NSEvent type=%lu key=%lu loc=%@ chars=%@>", (unsigned long)_type,
            (unsigned long)_keyCode, NSStringFromCGPoint(_location), _characters];
}
@end

void RecompDispatchEvent(RNSEvent *event) {
    os_unfair_lock_lock(&gMonitorLock);
    NSArray *monitors = [gLocalMonitors copy];
    os_unfair_lock_unlock(&gMonitorLock);
    for (RecompMonitor *m in monitors) {
        if (!(m.mask & (1ULL << event->_type))) continue;
        event = m.handler(event);
        if (!event) return;
    }
    [(RNSApplication *)NSApp sendEvent:event];
}

// --- NSScreen ---------------------------------------------------------------------

@interface RNSScreen : NSObject
@end
@implementation RNSScreen
RECOMP_FORWARDING
+ (NSArray *)screens { return @[[self mainScreen]]; }
+ (instancetype)mainScreen {
    static RNSScreen *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [RNSScreen new]; });
    return s;
}
+ (instancetype)deepestScreen { return [self mainScreen]; }
+ (BOOL)screensHaveSeparateSpaces { return NO; }
- (NSRect)frame { CGSize s = RecompScreenSize(); return CGRectMake(0, 0, s.width, s.height); }
- (NSRect)visibleFrame { return self.frame; }
- (CGFloat)backingScaleFactor { return 1; }
- (NSDictionary *)deviceDescription {
    CGSize s = RecompScreenSize();
    return @{@"NSScreenNumber": @1, @"NSDeviceSize": [NSValue valueWithCGSize:s],
             @"NSDeviceResolution": [NSValue valueWithCGSize:CGSizeMake(72, 72)], @"NSDeviceIsScreen": @"YES",
             @"NSDeviceBitsPerSample": @8, @"NSDeviceColorSpaceName": @"NSCalibratedRGBColorSpace"};
}
- (NSString *)localizedName { return UIDevice.currentDevice.model; }
- (NSInteger)maximumFramesPerSecond { return UIScreen.mainScreen.maximumFramesPerSecond; }
- (CGFloat)maximumExtendedDynamicRangeColorComponentValue { return 1; }
- (CGFloat)maximumPotentialExtendedDynamicRangeColorComponentValue { return UIScreen.mainScreen.potentialEDRHeadroom; }
- (CGFloat)maximumReferenceExtendedDynamicRangeColorComponentValue { return 0; }
- (id)colorSpace { return nil; }
- (NSRect)convertRectToBacking:(NSRect)r { return r; }
- (NSRect)convertRectFromBacking:(NSRect)r { return r; }
- (NSRect)backingAlignedRect:(NSRect)r options:(unsigned long long)o { return CGRectIntegral(r); }
- (UIEdgeInsets)safeAreaInsets { return UIEdgeInsetsZero; }
- (NSInteger)depth { return 0x208; }
@end

// --- NSView -------------------------------------------------------------------------

// UIView behind an NSView. Its own layer is a plain container; an NSView layer
// set by the game (a CAMetalLayer) is a sublayer kept at the view's bounds.
@interface RecompBackingView : UIView
@property (assign) RNSView *owner;
@end

@implementation RecompBackingView
- (void)layoutSubviews {
    [super layoutSubviews];
    CALayer *l = self.owner.layer;
    if (l && l.superlayer == self.layer) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        l.frame = self.layer.bounds;
        [CATransaction commit];
    }
}
// Touches go to the root view, which turns them into mouse events.
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e { return nil; }
@end

@implementation RNSView {
    NSMutableArray *_subviews;
    RecompBackingView *_ui;
    NSMutableArray *_trackingAreas;
}
@synthesize frame = _frame, bounds = _bounds, layer = _layer, wantsLayer = _wantsLayer;

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super init])) {
        _frame = frame;
        _bounds = CGRectMake(0, 0, frame.size.width, frame.size.height);
        _subviews = [NSMutableArray new];
        _trackingAreas = [NSMutableArray new];
        RecompOnMain(^{
            self->_ui = [[RecompBackingView alloc] initWithFrame:CGRectMake(0, 0, frame.size.width, frame.size.height)];
            self->_ui.owner = self;
            self->_ui.backgroundColor = UIColor.clearColor;
            self->_ui.userInteractionEnabled = NO;
        });
    }
    return self;
}
- (instancetype)init { return [self initWithFrame:CGRectZero]; }
- (instancetype)initWithCoder:(NSCoder *)c { return [self initWithFrame:CGRectZero]; }
- (void)dealloc { UIView *ui = _ui; _ui.owner = nil; RecompOnMain(^{ [ui removeFromSuperview]; }); }
- (UIView *)uiView { return _ui; }

- (void)recompSyncUIFrame {
    NSRect f = _frame;
    RNSView *sup = _superview;
    CGFloat parentH = sup ? sup.bounds.size.height : (_window ? _window.frame.size.height : f.size.height);
    BOOL flipped = sup ? [sup isFlipped] : NO;
    CGRect ui = CGRectMake(f.origin.x, flipped ? f.origin.y : parentH - f.origin.y - f.size.height, f.size.width, f.size.height);
    RecompOnMain(^{
        self->_ui.frame = ui;
        [self->_ui setNeedsLayout];
        [self->_ui layoutIfNeeded];
    });
}
- (void)setFrame:(NSRect)frame {
    NSSize old = _frame.size;
    _frame = frame;
    _bounds.size = frame.size;
    [self recompSyncUIFrame];
    if (!CGSizeEqualToSize(old, frame.size)) {
        for (RNSView *v in [_subviews copy]) [v resizeWithOldSuperviewSize:old];
        [self viewDidEndLiveResize];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:@"NSViewFrameDidChangeNotification" object:self];
}
- (void)resizeWithOldSuperviewSize:(NSSize)old {
    NSUInteger m = self.autoresizingMask;
    NSRect f = _frame;
    NSSize now = _superview.bounds.size;
    if (m & 2) f.size.width += now.width - old.width;    // NSViewWidthSizable
    if (m & 16) f.size.height += now.height - old.height; // NSViewHeightSizable
    if (m & (2 | 16)) self.frame = f;
}
- (void)viewDidEndLiveResize {}
- (void)setFrameSize:(NSSize)s { NSRect f = _frame; f.size = s; self.frame = f; }
- (void)setFrameOrigin:(NSPoint)p { NSRect f = _frame; f.origin = p; self.frame = f; }
- (void)setBoundsSize:(NSSize)s { _bounds.size = s; }
- (void)setBoundsOrigin:(NSPoint)p { _bounds.origin = p; }
- (BOOL)isFlipped { return NO; }
- (BOOL)isOpaque { return NO; }
- (NSRect)visibleRect { return _bounds; }
- (NSArray *)subviews { return [_subviews copy]; }
- (void)setSubviews:(NSArray *)subs {
    for (RNSView *v in [_subviews copy]) [v removeFromSuperview];
    for (RNSView *v in subs) [self addSubview:v];
}
- (void)addSubview:(RNSView *)view {
    if (!view || view == self) return;
    [view removeFromSuperview];
    [_subviews addObject:view];
    view.superview = self;
    view.nextResponder = self;
    [view recompSetWindow:_window];
    UIView *child = view.uiView;
    RecompOnMain(^{ [self->_ui addSubview:child]; });
    [view recompSyncUIFrame];
}
- (void)addSubview:(RNSView *)view positioned:(NSInteger)place relativeTo:(RNSView *)other { [self addSubview:view]; }
- (void)removeFromSuperview {
    RNSView *sup = _superview;
    if (!sup) return;
    [sup recompRemoveSubview:self];
    _superview = nil;
    [self recompSetWindow:nil];
    UIView *ui = _ui;
    RecompOnMain(^{ [ui removeFromSuperview]; });
}
- (void)recompRemoveSubview:(RNSView *)v { [_subviews removeObject:v]; }
- (void)recompSetWindow:(RNSWindow *)window {
    if (_window == window) return;
    if ([self respondsToSelector:@selector(viewWillMoveToWindow:)]) [self viewWillMoveToWindow:window];
    _window = window;
    for (RNSView *v in _subviews) [v recompSetWindow:window];
    if ([self respondsToSelector:@selector(viewDidMoveToWindow)]) [self viewDidMoveToWindow];
}
- (void)viewWillMoveToWindow:(id)w {}
- (void)viewDidMoveToWindow {}
- (void)viewWillMoveToSuperview:(id)s {}
- (void)viewDidMoveToSuperview {}
- (BOOL)isDescendantOf:(RNSView *)v { for (RNSView *p = self; p; p = p.superview) if (p == v) return YES; return NO; }
- (id)enclosingScrollView { return nil; }

- (CALayer *)makeBackingLayer { return [CALayer layer]; }
- (void)setWantsLayer:(BOOL)w {
    _wantsLayer = w;
    if (w && !_layer) self.layer = [self makeBackingLayer];
}
- (BOOL)wantsUpdateLayer { return NO; }
- (void)setLayer:(CALayer *)layer {
    CALayer *old = _layer;
    _layer = layer;
    RecompOnMain(^{
        if (old != layer) [old removeFromSuperlayer];
        if (layer) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [self->_ui.layer addSublayer:layer];
            layer.frame = self->_ui.layer.bounds;
            [CATransaction commit];
        }
    });
}
- (void)setNeedsDisplay:(BOOL)n {}
- (void)setNeedsDisplayInRect:(NSRect)r {}
- (BOOL)needsDisplay { return NO; }
- (void)display {}
- (void)displayIfNeeded {}
- (void)setNeedsLayout:(BOOL)n {}
- (void)layout {}
- (void)layoutSubtreeIfNeeded {}
- (void)drawRect:(NSRect)r {}
- (void)updateLayer {}
- (void)setLayerContentsRedrawPolicy:(NSInteger)p {}
- (NSInteger)layerContentsRedrawPolicy { return 0; }
- (void)setLayerContentsPlacement:(NSInteger)p {}
- (void)setCanDrawConcurrently:(BOOL)b {}
- (void)setCanDrawSubviewsIntoLayer:(BOOL)b {}
- (void)setPostsFrameChangedNotifications:(BOOL)b {}
- (void)setPostsBoundsChangedNotifications:(BOOL)b {}
- (BOOL)autoresizesSubviews { return YES; }
- (void)setAutoresizesSubviews:(BOOL)b {}
- (void)setTranslatesAutoresizingMaskIntoConstraints:(BOOL)b {}
- (void)setHidden:(BOOL)h { _hidden = h; RecompOnMain(^{ self->_ui.hidden = h; }); }
- (void)setAlphaValue:(CGFloat)a { RecompOnMain(^{ self->_ui.alpha = a; }); }
- (CGFloat)alphaValue { return 1; }
- (void)setAcceptsTouchEvents:(BOOL)b {}
- (void)setWantsRestingTouches:(BOOL)b {}
- (void)setAllowedTouchTypes:(NSUInteger)t {}
- (NSUInteger)allowedTouchTypes { return 0; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (BOOL)acceptsFirstMouse:(id)e { return YES; }
- (id)inputContext { return nil; }
- (NSArray *)trackingAreas { return [_trackingAreas copy]; }
- (void)addTrackingArea:(id)a { if (a) [_trackingAreas addObject:a]; }
- (void)removeTrackingArea:(id)a { [_trackingAreas removeObject:a]; }
- (void)updateTrackingAreas {}
- (void)addCursorRect:(NSRect)r cursor:(id)c {}
- (void)resetCursorRects {}
- (void)discardCursorRects {}
- (void)registerForDraggedTypes:(NSArray *)t {}
- (void)unregisterDraggedTypes {}
- (BOOL)inLiveResize { return NO; }
- (BOOL)preservesContentDuringLiveResize { return NO; }

// Geometry. Views keep AppKit coordinates; conversions walk up to the window.
- (NSPoint)recompToWindow:(NSPoint)p {
    for (RNSView *v = self; v; v = v.superview) {
        p.x += v.frame.origin.x - v.bounds.origin.x;
        p.y += v.frame.origin.y - v.bounds.origin.y;
    }
    return p;
}
- (NSPoint)recompFromWindow:(NSPoint)p {
    NSPoint o = [self recompToWindow:CGPointZero];
    return CGPointMake(p.x - o.x, p.y - o.y);
}
- (NSPoint)convertPoint:(NSPoint)p toView:(RNSView *)v {
    NSPoint w = [self recompToWindow:p];
    return v ? [v recompFromWindow:w] : w;
}
- (NSPoint)convertPoint:(NSPoint)p fromView:(RNSView *)v {
    NSPoint w = v ? [v recompToWindow:p] : p;
    return [self recompFromWindow:w];
}
- (NSRect)convertRect:(NSRect)r toView:(RNSView *)v { r.origin = [self convertPoint:r.origin toView:v]; return r; }
- (NSRect)convertRect:(NSRect)r fromView:(RNSView *)v { r.origin = [self convertPoint:r.origin fromView:v]; return r; }
- (NSSize)convertSize:(NSSize)s toView:(id)v { return s; }
- (NSSize)convertSize:(NSSize)s fromView:(id)v { return s; }
- (NSRect)convertRectToBacking:(NSRect)r { return r; }
- (NSRect)convertRectFromBacking:(NSRect)r { return r; }
- (NSSize)convertSizeToBacking:(NSSize)s { return s; }
- (NSSize)convertSizeFromBacking:(NSSize)s { return s; }
- (NSPoint)convertPointToBacking:(NSPoint)p { return p; }
- (NSPoint)convertPointFromBacking:(NSPoint)p { return p; }
- (NSRect)backingAlignedRect:(NSRect)r options:(unsigned long long)o { return CGRectIntegral(r); }
- (RNSView *)hitTest:(NSPoint)p {
    if (_hidden) return nil;
    NSPoint local = _superview ? [self convertPoint:p fromView:_superview] : p;
    if (!CGRectContainsPoint(_bounds, local)) return nil;
    for (RNSView *v in [_subviews reverseObjectEnumerator]) {
        RNSView *hit = [v hitTest:local];
        if (hit) return hit;
    }
    return self;
}
@end

// --- NSWindow ----------------------------------------------------------------------

static NSInteger gNextWindowNumber = 1;

// Holds a window's content on screen: bounds in window points, scaled to
// fit the device's screen (aspect-fit, centred) when the window is a different size.
@interface RecompWindowView : UIView
@property (assign) RNSWindow *owner;
@end
@implementation RecompWindowView
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e { return nil; }
@end

@implementation RNSWindow {
    RecompWindowView *_frameView;
    NSString *_title;
    BOOL _key, _main, _ignoresMouse, _opaque;
    CGFloat _alpha;
    NSSize _minSize, _maxSize;
    NSUInteger _collection;
    id _backgroundColor;
}
@synthesize frame = _frame, contentView = _contentView, windowNumber = _windowNumber, visible = _visible, styleMask = _styleMask;

+ (NSRect)contentRectForFrameRect:(NSRect)r styleMask:(NSUInteger)m { return r; }
+ (NSRect)frameRectForContentRect:(NSRect)r styleMask:(NSUInteger)m { return r; }
+ (NSInteger)windowNumberAtPoint:(NSPoint)p belowWindowWithWindowNumber:(NSInteger)n {
    for (RNSWindow *w in [[(RNSApplication *)NSApp recompWindows] reverseObjectEnumerator])
        if (w.isVisible && w.windowNumber != n && CGRectContainsPoint(w.frame, p)) return w.windowNumber;
    return 0;
}
+ (NSArray *)windowNumbersWithOptions:(NSUInteger)o {
    NSMutableArray *a = [NSMutableArray new];
    for (RNSWindow *w in [(RNSApplication *)NSApp recompWindows]) if (w.isVisible) [a addObject:@(w.windowNumber)];
    return a;
}
+ (BOOL)allowsAutomaticWindowTabbing { return NO; }
+ (void)setAllowsAutomaticWindowTabbing:(BOOL)b {}

- (instancetype)initWithContentRect:(NSRect)rect styleMask:(NSUInteger)style backing:(NSUInteger)backing defer:(BOOL)defer {
    if ((self = [super init])) {
        _frame = rect;
        _styleMask = style;
        _alpha = 1;
        _windowNumber = gNextWindowNumber++;
        RecompOnMain(^{
            self->_frameView = [[RecompWindowView alloc] initWithFrame:CGRectMake(0, 0, rect.size.width, rect.size.height)];
            self->_frameView.owner = self;
            self->_frameView.backgroundColor = UIColor.blackColor;
            self->_frameView.hidden = YES;
        });
        self.contentView = [[RNSView alloc] initWithFrame:CGRectMake(0, 0, rect.size.width, rect.size.height)];
        [[(RNSApplication *)NSApp recompWindows] addObject:self];
    }
    return self;
}
- (instancetype)initWithContentRect:(NSRect)rect styleMask:(NSUInteger)style backing:(NSUInteger)b defer:(BOOL)d screen:(id)s {
    return [self initWithContentRect:rect styleMask:style backing:b defer:d];
}
- (UIView *)recompFrameView { return _frameView; }

- (void)setContentView:(RNSView *)view {
    if (_contentView == view) return;
    RNSView *old = _contentView;
    [old recompSetWindow:nil];
    UIView *oldUI = old.uiView;
    _contentView = view;
    if (!view) { RecompOnMain(^{ [oldUI removeFromSuperview]; }); return; }
    [view removeFromSuperview];
    view.nextResponder = self;
    if (!_firstResponder || _firstResponder == old) _firstResponder = view;
    view.frame = CGRectMake(0, 0, _frame.size.width, _frame.size.height);
    [view recompSetWindow:self];
    UIView *ui = view.uiView;
    RecompOnMain(^{
        [oldUI removeFromSuperview];
        ui.frame = self->_frameView.bounds;
        [self->_frameView addSubview:ui];
    });
}

// Places the frame view in the root view: aspect-fit, centred.
- (void)recompLayout {
    NSRect f = _frame;
    BOOL show = _visible;
    RecompOnMain(^{
        RecompRootView *root = RecompRoot();
        if (!root || !self->_frameView) return;
        if (show && self->_frameView.superview != root) {
            [root addSubview:self->_frameView];
            RecompRaiseTouchPad();
        }
        CGSize screen = root.bounds.size;
        CGFloat s = MIN(screen.width / MAX(f.size.width, 1), screen.height / MAX(f.size.height, 1));
        self->_frameView.transform = CGAffineTransformIdentity;
        self->_frameView.bounds = CGRectMake(0, 0, f.size.width, f.size.height);
        self->_frameView.center = CGPointMake(screen.width / 2, screen.height / 2);
        self->_frameView.transform = CGAffineTransformMakeScale(s, s);
        self->_frameView.hidden = !show;
        self->_frameView.alpha = self->_alpha;
    });
}

- (void)recompPost:(NSString *)name selector:(SEL)sel {
    NSNotification *n = [NSNotification notificationWithName:name object:self];
    id d = self.delegate;
    if ([d respondsToSelector:sel]) ((void (*)(id, SEL, id))objc_msgSend)(d, sel, n);
    [[NSNotificationCenter defaultCenter] postNotification:n];
}

- (void)setFrame:(NSRect)frame display:(BOOL)display {
    BOOL resized = !CGSizeEqualToSize(frame.size, _frame.size);
    BOOL moved = !CGPointEqualToPoint(frame.origin, _frame.origin);
    _frame = frame;
    if (resized) _contentView.frame = CGRectMake(0, 0, frame.size.width, frame.size.height);
    [self recompLayout];
    if (moved) [self recompPost:@"NSWindowDidMoveNotification" selector:@selector(windowDidMove:)];
    if (resized) [self recompPost:@"NSWindowDidResizeNotification" selector:@selector(windowDidResize:)];
}
- (void)setFrame:(NSRect)frame display:(BOOL)d animate:(BOOL)a { [self setFrame:frame display:d]; }
- (void)setFrame:(NSRect)frame { [self setFrame:frame display:YES]; }
- (void)setFrameOrigin:(NSPoint)p { [self setFrame:CGRectMake(p.x, p.y, _frame.size.width, _frame.size.height) display:YES]; }
- (void)setFrameTopLeftPoint:(NSPoint)p { [self setFrameOrigin:CGPointMake(p.x, p.y - _frame.size.height)]; }
- (void)setContentSize:(NSSize)s { [self setFrame:CGRectMake(_frame.origin.x, _frame.origin.y, s.width, s.height) display:YES]; }
- (void)center {
    CGSize s = RecompScreenSize();
    [self setFrameOrigin:CGPointMake((s.width - _frame.size.width) / 2, (s.height - _frame.size.height) / 2)];
}
- (NSRect)contentRectForFrameRect:(NSRect)r { return r; }
- (NSRect)frameRectForContentRect:(NSRect)r { return r; }
- (NSRect)constrainFrameRect:(NSRect)r toScreen:(id)s { return r; }
- (NSRect)convertRectToScreen:(NSRect)r { r.origin.x += _frame.origin.x; r.origin.y += _frame.origin.y; return r; }
- (NSRect)convertRectFromScreen:(NSRect)r { r.origin.x -= _frame.origin.x; r.origin.y -= _frame.origin.y; return r; }
- (NSPoint)convertPointToScreen:(NSPoint)p { return CGPointMake(p.x + _frame.origin.x, p.y + _frame.origin.y); }
- (NSPoint)convertPointFromScreen:(NSPoint)p { return CGPointMake(p.x - _frame.origin.x, p.y - _frame.origin.y); }
- (NSPoint)convertBaseToScreen:(NSPoint)p { return [self convertPointToScreen:p]; }
- (NSPoint)convertScreenToBase:(NSPoint)p { return [self convertPointFromScreen:p]; }
- (NSRect)convertRectToBacking:(NSRect)r { return r; }
- (NSRect)convertRectFromBacking:(NSRect)r { return r; }
- (NSPoint)mouseLocationOutsideOfEventStream { return [self convertPointFromScreen:RecompMouseLocation]; }
- (CGFloat)backingScaleFactor { return 1; }
- (id)screen { return [RNSScreen mainScreen]; }
- (id)deepestScreen { return [RNSScreen mainScreen]; }

- (void)recompShow:(BOOL)key {
    BOOL was = _visible;
    _visible = YES;
    [self recompLayout];
    RecompOnMain(^{
        [self->_frameView.superview bringSubviewToFront:self->_frameView];
        RecompRaiseTouchPad();
    });
    if (key) [self makeKeyWindow];
    if (!was) [[NSNotificationCenter defaultCenter] postNotificationName:@"NSWindowDidChangeOcclusionStateNotification" object:self];
}
- (void)makeKeyAndOrderFront:(id)s { [self recompShow:YES]; [self makeMainWindow]; }
- (void)orderFront:(id)s { [self recompShow:NO]; }
- (void)orderFrontRegardless { [self recompShow:NO]; }
- (void)orderBack:(id)s { [self recompShow:NO]; RecompOnMain(^{ [self->_frameView.superview sendSubviewToBack:self->_frameView]; }); }
- (void)orderWindow:(NSInteger)place relativeTo:(NSInteger)other { if (place) [self recompShow:NO]; else [self orderOut:nil]; }
- (void)orderFrontAndMakeMain:(BOOL)main andKey:(BOOL)key { [self recompShow:key]; if (main) [self makeMainWindow]; }
- (void)orderOut:(id)s {
    _visible = NO;
    if (_key) [self resignKeyWindow];
    [self recompLayout];
}
- (void)makeKeyWindow {
    if (_key) return;
    for (RNSWindow *w in [(RNSApplication *)NSApp recompWindows]) if (w != self && [w isKeyWindow]) [w resignKeyWindow];
    _key = YES;
    [self recompPost:@"NSWindowDidBecomeKeyNotification" selector:@selector(windowDidBecomeKey:)];
}
- (void)resignKeyWindow {
    if (!_key) return;
    _key = NO;
    [self recompPost:@"NSWindowDidResignKeyNotification" selector:@selector(windowDidResignKey:)];
}
- (void)makeMainWindow {
    if (_main) return;
    for (RNSWindow *w in [(RNSApplication *)NSApp recompWindows]) if (w != self && [w isMainWindow]) [w resignMainWindow];
    _main = YES;
    [self recompPost:@"NSWindowDidBecomeMainNotification" selector:@selector(windowDidBecomeMain:)];
}
- (void)resignMainWindow {
    if (!_main) return;
    _main = NO;
    [self recompPost:@"NSWindowDidResignMainNotification" selector:@selector(windowDidResignMain:)];
}
- (BOOL)isKeyWindow { return _key; }
- (BOOL)isMainWindow { return _main; }
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
- (BOOL)isOnActiveSpace { return YES; }
- (BOOL)isMiniaturized { return NO; }
- (BOOL)isZoomed { return NO; }
- (BOOL)inLiveResize { return NO; }
- (void)registerForDraggedTypes:(NSArray *)t {}
- (void)unregisterDraggedTypes {}
- (BOOL)isSheet { return NO; }
- (BOOL)isFloatingPanel { return NO; }
- (BOOL)isModalPanel { return NO; }
- (NSUInteger)occlusionState { return _visible ? 2 : 0; } // NSWindowOcclusionStateVisible
- (void)miniaturize:(id)s {}
- (void)deminiaturize:(id)s {}
- (void)performMiniaturize:(id)s {}
- (void)zoom:(id)s {}
- (void)performZoom:(id)s {}
- (void)toggleFullScreen:(id)s {
    // Every window is already full screen on iOS; report the transition.
    [self recompPost:@"NSWindowWillEnterFullScreenNotification" selector:@selector(windowWillEnterFullScreen:)];
    [self recompPost:@"NSWindowDidEnterFullScreenNotification" selector:@selector(windowDidEnterFullScreen:)];
}
- (void)close {
    [self recompPost:@"NSWindowWillCloseNotification" selector:@selector(windowWillClose:)];
    [self orderOut:nil];
    UIView *fv = _frameView;
    RecompOnMain(^{ [fv removeFromSuperview]; });
    [[(RNSApplication *)NSApp recompWindows] removeObject:self];
}
- (void)performClose:(id)s {
    id d = self.delegate;
    if ([d respondsToSelector:@selector(windowShouldClose:)] && !((BOOL (*)(id, SEL, id))objc_msgSend)(d, @selector(windowShouldClose:), self)) return;
    [self close];
}
- (BOOL)makeFirstResponder:(RNSResponder *)r {
    if (r == _firstResponder) return YES;
    [_firstResponder resignFirstResponder];
    _firstResponder = r ?: (RNSResponder *)self;
    [r becomeFirstResponder];
    return YES;
}
- (void)sendEvent:(RNSEvent *)e {
    RNSResponder *target = _firstResponder ?: _contentView;
    switch (e->_type) {
        case 10: [target keyDown:e]; break;
        case 11: [target keyUp:e]; break;
        case 12: [target flagsChanged:e]; break;
        default: {
            RNSView *hit = [_contentView hitTest:e->_location] ?: _contentView;
            switch (e->_type) {
                case 1: [hit mouseDown:e]; break;
                case 2: [hit mouseUp:e]; break;
                case 3: [hit rightMouseDown:e]; break;
                case 4: [hit rightMouseUp:e]; break;
                case 5: [hit mouseMoved:e]; break;
                case 6: [hit mouseDragged:e]; break;
                case 7: [hit rightMouseDragged:e]; break;
                case 22: [hit scrollWheel:e]; break;
                case 25: [hit otherMouseDown:e]; break;
                case 26: [hit otherMouseUp:e]; break;
                case 27: [hit otherMouseDragged:e]; break;
            }
        }
    }
}
- (void)setTitle:(NSString *)t { _title = [t copy]; }
- (NSString *)title { return _title ?: @""; }
- (void)setTitleVisibility:(NSInteger)v {}
- (void)setTitlebarAppearsTransparent:(BOOL)b {}
- (void)setRepresentedFilename:(NSString *)f {}
- (void)setMiniwindowTitle:(NSString *)t {}
- (void)setAlphaValue:(CGFloat)a { _alpha = a; [self recompLayout]; }
- (CGFloat)alphaValue { return _alpha; }
- (void)setOpaque:(BOOL)o { _opaque = o; }
- (BOOL)isOpaque { return _opaque; }
- (void)setBackgroundColor:(id)c { _backgroundColor = c; }
- (id)backgroundColor { return _backgroundColor; }
- (void)setHasShadow:(BOOL)b {}
- (BOOL)hasShadow { return NO; }
- (void)invalidateShadow {}
- (void)setIgnoresMouseEvents:(BOOL)b { _ignoresMouse = b; }
- (BOOL)ignoresMouseEvents { return _ignoresMouse; }
- (void)setAcceptsMouseMovedEvents:(BOOL)b {}
- (BOOL)acceptsMouseMovedEvents { return YES; }
- (void)setCollectionBehavior:(NSUInteger)c { _collection = c; }
- (NSUInteger)collectionBehavior { return _collection; }
- (void)setMinSize:(NSSize)s { _minSize = s; }
- (void)setMaxSize:(NSSize)s { _maxSize = s; }
- (NSSize)minSize { return _minSize; }
- (NSSize)maxSize { return _maxSize; }
- (void)setContentMinSize:(NSSize)s {}
- (void)setContentMaxSize:(NSSize)s {}
- (void)setContentAspectRatio:(NSSize)s {}
- (void)setMovable:(BOOL)b {}
- (void)setMovableByWindowBackground:(BOOL)b {}
- (void)setReleasedWhenClosed:(BOOL)b {}
- (void)setRestorable:(BOOL)b {}
- (void)disableSnapshotRestoration {}
- (void)setHidesOnDeactivate:(BOOL)b {}
- (BOOL)hidesOnDeactivate { return NO; }
- (void)setCanHide:(BOOL)b {}
- (void)setDisplaysWhenScreenProfileChanges:(BOOL)b {}
- (void)setColorSpace:(id)c {}
- (void)setPreventsApplicationTerminationWhenModal:(BOOL)b {}
- (void)setAnimationBehavior:(NSInteger)b {}
- (void)setTabbingMode:(NSInteger)m {}
- (void)setStyleMask:(NSUInteger)m { _styleMask = m; }
- (id)standardWindowButton:(NSInteger)b { return nil; }
- (void)display {}
- (void)displayIfNeeded {}
- (void)update {}
- (void)setViewsNeedDisplay:(BOOL)b {}
- (void)enableCursorRects {}
- (void)disableCursorRects {}
- (void)invalidateCursorRectsForView:(id)v {}
- (void)resetCursorRects {}
- (NSArray *)childWindows { return @[]; }
- (id)parentWindow { return nil; }
- (void)addChildWindow:(id)w ordered:(NSInteger)o {}
- (void)removeChildWindow:(id)w {}
- (id)windowController { return nil; }
- (id)attachedSheet { return nil; }
- (id)sheetParent { return nil; }
- (id)fieldEditor:(BOOL)c forObject:(id)o { return nil; }
- (id)graphicsContext { return nil; }
- (id)tabbingIdentifier { return @""; }
- (void)setTabbingIdentifier:(id)t {}
- (CGFloat)titlebarHeight { return 0; }
- (id)dockTile { return nil; }
- (id)nextEventMatchingMask:(unsigned long long)m { return nil; }
- (id)nextEventMatchingMask:(unsigned long long)m untilDate:(id)d inMode:(id)mode dequeue:(BOOL)dq { return nil; }
- (id)currentEvent { return nil; }
- (NSString *)description { return [NSString stringWithFormat:@"<NSWindow %ld %@>", (long)_windowNumber, NSStringFromCGRect(_frame)]; }
@end

// --- NSApplication -------------------------------------------------------------------

@interface RecompAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation RNSApplication {
    NSMutableArray *_queue;
    NSUInteger _presentation;
    id _mainMenu, _windowsMenu;
    BOOL _running;
}
+ (instancetype)sharedApplication {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ NSApp = [self new]; });
    return NSApp;
}
- (instancetype)init {
    if ((self = [super init])) {
        _recompWindows = [NSMutableArray new];
        _queue = [NSMutableArray new];
    }
    return self;
}
- (void)run {
    _running = YES;
    RLOG(@"NSApp run -> UIApplicationMain");
    UIApplicationMain(*_NSGetArgc(), *_NSGetArgv(), nil, NSStringFromClass([RecompAppDelegate class]));
}
- (void)finishLaunching {}
- (BOOL)isRunning { return _running; }
- (void)stop:(id)s {}
- (void)terminate:(id)s {
    id d = self.delegate;
    if ([d respondsToSelector:@selector(applicationShouldTerminate:)]) {
        NSUInteger reply = ((NSUInteger (*)(id, SEL, id))objc_msgSend)(d, @selector(applicationShouldTerminate:), self);
        if (reply == 0) return; // NSTerminateCancel
        if (reply == 2) return; // NSTerminateLater: replyToApplicationShouldTerminate: follows
    }
    [self recompExit];
}
- (void)replyToApplicationShouldTerminate:(BOOL)yes { if (yes) [self recompExit]; }
- (void)recompExit {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"NSApplicationWillTerminateNotification" object:self];
    id d = self.delegate;
    if ([d respondsToSelector:@selector(applicationWillTerminate:)])
        ((void (*)(id, SEL, id))objc_msgSend)(d, @selector(applicationWillTerminate:), [NSNotification notificationWithName:@"NSApplicationWillTerminateNotification" object:self]);
    RLOG(@"terminate");
    exit(0);
}
- (void)sendEvent:(RNSEvent *)e {
    RNSWindow *w = e->_window;
    if (!w && (e->_type == 10 || e->_type == 11 || e->_type == 12)) w = self.keyWindow;
    [w sendEvent:e];
}
- (void)postEvent:(RNSEvent *)e atStart:(BOOL)start {
    @synchronized (_queue) {
        if (start) [_queue insertObject:e atIndex:0]; else [_queue addObject:e];
    }
    // Wake the main run loop so a waiting nextEventMatchingMask: returns.
    CFRunLoopWakeUp(CFRunLoopGetMain());
}
- (id)nextEventMatchingMask:(unsigned long long)mask untilDate:(NSDate *)date inMode:(NSString *)mode dequeue:(BOOL)dq {
    do {
        @synchronized (_queue) {
            for (RNSEvent *e in _queue) {
                if (mask & (1ULL << e->_type)) {
                    if (dq) [_queue removeObject:e];
                    return e;
                }
            }
        }
        if (!date || date.timeIntervalSinceNow <= 0) return nil;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, MIN(date.timeIntervalSinceNow, 0.01), true);
    } while (1);
}
- (void)discardEventsMatchingMask:(unsigned long long)m beforeEvent:(id)e {}
- (id)currentEvent { return nil; }
- (NSArray *)windows { return [_recompWindows copy]; }
- (NSArray *)orderedWindows { return [_recompWindows reverseObjectEnumerator].allObjects; }
- (id)keyWindow { for (RNSWindow *w in _recompWindows) if (w.isKeyWindow) return w; return nil; }
- (id)mainWindow { for (RNSWindow *w in _recompWindows) if (w.isMainWindow) return w; return nil; }
- (id)windowWithWindowNumber:(NSInteger)n { for (RNSWindow *w in _recompWindows) if (w.windowNumber == n) return w; return nil; }
- (id)modalWindow { return nil; }
- (BOOL)isActive { return UIApplication.sharedApplication.applicationState == UIApplicationStateActive; }
- (BOOL)isHidden { return NO; }
- (void)activateIgnoringOtherApps:(BOOL)b {}
- (void)activate {}
- (void)deactivate {}
- (void)hide:(id)s {}
- (void)unhide:(id)s {}
- (void)unhideWithoutActivation {}
- (void)hideOtherApplications:(id)s {}
- (void)unhideAllApplications:(id)s {}
- (void)setPresentationOptions:(NSUInteger)o { _presentation = o; }
- (NSUInteger)presentationOptions { return _presentation; }
- (NSUInteger)currentSystemPresentationOptions { return _presentation; }
- (BOOL)setActivationPolicy:(NSInteger)p { return YES; }
- (NSInteger)activationPolicy { return 0; }
- (void)setMainMenu:(id)m { _mainMenu = m; }
- (id)mainMenu { return _mainMenu; }
- (void)setWindowsMenu:(id)m { _windowsMenu = m; }
- (id)windowsMenu { return _windowsMenu; }
- (void)setServicesMenu:(id)m {}
- (void)setHelpMenu:(id)m {}
- (void)addWindowsItem:(id)w title:(id)t filename:(BOOL)f {}
- (void)changeWindowsItem:(id)w title:(id)t filename:(BOOL)f {}
- (void)removeWindowsItem:(id)w {}
- (void)orderFrontStandardAboutPanel:(id)s {}
- (void)setApplicationIconImage:(id)i {}
- (id)applicationIconImage { return nil; }
- (NSInteger)requestUserAttention:(NSInteger)t { return 0; }
- (void)cancelUserAttentionRequest:(NSInteger)r {}
- (void)setWindowsNeedUpdate:(BOOL)b {}
- (void)updateWindows {}
- (NSInteger)userInterfaceLayoutDirection { return 0; }
- (id)effectiveAppearance { return nil; }
- (void)setAppearance:(id)a {}
- (NSInteger)runModalForWindow:(id)w { return 0; }
- (void)stopModal {}
- (void)stopModalWithCode:(NSInteger)c {}
- (void)abortModal {}
- (id)beginModalSessionForWindow:(id)w { return nil; }
- (void)endModalSession:(id)s {}
- (BOOL)sendAction:(SEL)a to:(id)t from:(id)s { return NO; }
- (id)targetForAction:(SEL)a { return nil; }
- (void)registerServicesMenuSendTypes:(id)s returnTypes:(id)r {}
- (void)setAutomaticCustomizeTouchBarMenuItemEnabled:(BOOL)b {}
- (BOOL)isFullKeyboardAccessEnabled { return NO; }
- (id)dockTile { return nil; }
@end

// --- UIKit host -------------------------------------------------------------------------

static void RecompSendToDelegate(SEL sel, NSString *name) {
    NSNotification *n = [NSNotification notificationWithName:name object:NSApp];
    id d = [(RNSApplication *)NSApp delegate];
    if ([d respondsToSelector:sel]) ((void (*)(id, SEL, id))objc_msgSend)(d, sel, n);
    [[NSNotificationCenter defaultCenter] postNotification:n];
}

@implementation RecompAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    CGRect b = UIScreen.mainScreen.bounds;
    gScreenSize = CGSizeMake(MAX(b.size.width, b.size.height), MIN(b.size.width, b.size.height));
    gScreenScale = UIScreen.mainScreen.scale;
    self.window = [[UIWindow alloc] initWithFrame:b];
    self.window.backgroundColor = UIColor.blackColor;
    self.window.rootViewController = [RecompViewController new];
    [self.window makeKeyAndVisible];
    // Games are often played with a controller, without touches: keep the
    // screen awake, as iOS games do.
    app.idleTimerDisabled = YES;
    gRoot = (RecompRootView *)self.window.rootViewController.view;
    RLOG(@"launched: screen %@ scale %.0f", NSStringFromCGSize(gScreenSize), gScreenScale);
    RecompSendToDelegate(@selector(applicationWillFinishLaunching:), @"NSApplicationWillFinishLaunchingNotification");
    RecompSendToDelegate(@selector(applicationDidFinishLaunching:), @"NSApplicationDidFinishLaunchingNotification");
    return YES;
}
- (void)applicationDidBecomeActive:(UIApplication *)app {
    RecompSendToDelegate(@selector(applicationDidBecomeActive:), @"NSApplicationDidBecomeActiveNotification");
}
- (void)applicationWillResignActive:(UIApplication *)app {
    RecompSendToDelegate(@selector(applicationWillResignActive:), @"NSApplicationWillResignActiveNotification");
}
- (void)applicationDidEnterBackground:(UIApplication *)app {
    RecompSendToDelegate(@selector(applicationDidHide:), @"NSApplicationDidHideNotification");
}
- (void)applicationWillEnterForeground:(UIApplication *)app {
    RecompSendToDelegate(@selector(applicationDidUnhide:), @"NSApplicationDidUnhideNotification");
}
- (void)applicationWillTerminate:(UIApplication *)app {
    RecompSendToDelegate(@selector(applicationWillTerminate:), @"NSApplicationWillTerminateNotification");
}
@end
