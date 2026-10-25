// UIKit input -> NSEvents: a pointer (trackpad, mouse) becomes mouse events,
// hardware keys become key events. Touches go to the on-screen gamepad
// (RecompTouchPad.m), which sits above everything else.
#import "RecompAppKit.h"
#import <GameController/GameController.h>

static BOOL gCursorHidden, gLocked;
static __weak RecompViewController *gController;

void RecompSetCursorHidden(BOOL hidden) { gCursorHidden = hidden; }
BOOL RecompPointerLocked(void) { return gLocked; }
void RecompSetPointerLocked(BOOL locked) {
    if (gLocked == locked) return;
    gLocked = locked;
    RecompOnMain(^{ [gController setNeedsUpdateOfPrefersPointerLocked]; });
}

// NSEventType values used here.
enum { kLDown = 1, kLUp = 2, kRDown = 3, kRUp = 4, kMoved = 5, kLDrag = 6, kRDrag = 7,
       kKeyDown = 10, kKeyUp = 11, kFlags = 12, kScroll = 22 };

static RNSWindow *WindowAt(CGPoint rootPoint, NSPoint *outLoc) {
    RecompRootView *root = RecompRoot();
    for (UIView *v in root.subviews.reverseObjectEnumerator) {
        if (v.hidden || ![v respondsToSelector:@selector(owner)]) continue;
        RNSWindow *w = [(id<RecompOwned>)v owner];
        if (![w isKindOfClass:[RNSWindow class]] || !w.isVisible || [w ignoresMouseEvents]) continue;
        CGPoint p = [v convertPoint:rootPoint fromView:root];
        if (CGRectContainsPoint(v.bounds, p) || v == root.subviews.lastObject) {
            *outLoc = CGPointMake(p.x, v.bounds.size.height - p.y);
            return w;
        }
    }
    return nil;
}

static void SendMouse(NSUInteger type, CGPoint rootPoint, CGFloat dx, CGFloat dy) {
    NSPoint loc = CGPointZero;
    RNSWindow *w = WindowAt(rootPoint, &loc);
    RNSEvent *e = [RNSEvent recompEventWithType:type];
    if (w) {
        e->_window = w;
        e->_location = loc;
        RecompMouseLocation = CGPointMake(w.frame.origin.x + loc.x, w.frame.origin.y + loc.y);
    } else {
        CGSize s = RecompScreenSize();
        RecompMouseLocation = CGPointMake(rootPoint.x, s.height - rootPoint.y);
        e->_location = RecompMouseLocation;
    }
    e->_deltaX = dx;
    e->_deltaY = dy;
    e->_buttonNumber = (type == kRDown || type == kRUp || type == kRDrag) ? 1 : 0;
    RecompDispatchEvent(e);
}

@implementation RecompRootView {
    UITouch *_touch;
    CGPoint _last;
    BOOL _right;
}
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = NO;
        self.backgroundColor = UIColor.blackColor;
        [self addGestureRecognizer:[[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(hover:)]];
        UIPanGestureRecognizer *scroll = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(scroll:)];
        scroll.allowedScrollTypesMask = UIScrollTypeMaskAll;
        scroll.allowedTouchTypes = @[];
        [self addGestureRecognizer:scroll];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    for (UIView *v in self.subviews)
        if ([v respondsToSelector:@selector(owner)]) [[(id<RecompOwned>)v owner] recompLayout];
}
- (void)hover:(UIHoverGestureRecognizer *)g {
    if (_touch || gLocked) return;
    CGPoint p = [g locationInView:self];
    SendMouse(kMoved, p, p.x - _last.x, p.y - _last.y);
    _last = p;
}
- (void)scroll:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self];
    [g setTranslation:CGPointZero inView:self];
    NSPoint loc = CGPointZero;
    CGPoint p = [g locationInView:self];
    RNSWindow *w = WindowAt(p, &loc);
    RNSEvent *e = [RNSEvent recompEventWithType:kScroll];
    e->_window = w;
    e->_location = loc;
    e->_scrollX = t.x;
    e->_scrollY = t.y;
    e->_deltaX = t.x / 10;
    e->_deltaY = t.y / 10;
    e->_precise = YES;
    e->_phase = g.state == UIGestureRecognizerStateBegan ? 1 : g.state == UIGestureRecognizerStateEnded ? 8 : 4;
    RecompDispatchEvent(e);
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_touch) return;
    _touch = touches.anyObject;
    CGPoint p = [_touch locationInView:self];
    _right = (event.buttonMask & UIEventButtonMaskSecondary) != 0;
    SendMouse(kMoved, p, p.x - _last.x, p.y - _last.y);
    RecompPressedButtons |= _right ? 2 : 1;
    SendMouse(_right ? kRDown : kLDown, p, 0, 0);
    _last = p;
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (![touches containsObject:_touch]) return;
    CGPoint p = [_touch locationInView:self];
    SendMouse(_right ? kRDrag : kLDrag, p, p.x - _last.x, p.y - _last.y);
    _last = p;
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (![touches containsObject:_touch]) return;
    CGPoint p = [_touch locationInView:self];
    RecompPressedButtons &= ~(NSUInteger)(_right ? 2 : 1);
    SendMouse(_right ? kRUp : kLUp, p, 0, 0);
    _touch = nil;
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self touchesEnded:touches withEvent:event]; }
@end

// --- keyboard ---------------------------------------------------------------------

// Device-independent and device-dependent (NX_DEVICE*) modifier bits per key.
static NSUInteger ModifierBits(uint16_t mac) {
    switch (mac) {
        case 0x38: return 1 << 17 | 0x2;     // left shift
        case 0x3C: return 1 << 17 | 0x4;     // right shift
        case 0x3B: return 1 << 18 | 0x1;     // left control
        case 0x3E: return 1 << 18 | 0x2000;  // right control
        case 0x3A: return 1 << 19 | 0x20;    // left option
        case 0x3D: return 1 << 19 | 0x40;    // right option
        case 0x37: return 1 << 20 | 0x8;     // left command
        case 0x36: return 1 << 20 | 0x10;    // right command
        case 0x39: return 1 << 16;           // caps lock
        case 0x3F: return 1 << 23;           // fn
    }
    return 0;
}

static void SendKey(UIPress *press, BOOL down) {
    UIKey *key = press.key;
    if (!key) return;
    uint16_t mac = RecompMacKeyCode(key.keyCode);
    if (mac == 0xFFFF) return;
    NSUInteger bits = ModifierBits(mac);
    RNSEvent *e;
    if (bits) {
        if (mac == 0x39) {
            if (down) RecompModifierFlags ^= bits;
        } else if (down) {
            RecompModifierFlags |= bits;
        } else {
            RecompModifierFlags &= ~(bits & 0xFFFF);
            // Clear the device-independent bit only when neither side is held.
            NSUInteger side = RecompModifierFlags & 0xFFFF;
            NSUInteger keep = 0;
            if (side & (0x2 | 0x4)) keep |= 1 << 17;
            if (side & (0x1 | 0x2000)) keep |= 1 << 18;
            if (side & (0x20 | 0x40)) keep |= 1 << 19;
            if (side & (0x8 | 0x10)) keep |= 1 << 20;
            RecompModifierFlags = (RecompModifierFlags & ~(NSUInteger)(bits & ~0xFFFF)) | keep;
        }
        e = [RNSEvent recompEventWithType:kFlags];
    } else {
        e = [RNSEvent recompEventWithType:down ? kKeyDown : kKeyUp];
        BOOL shift = (RecompModifierFlags & (1 << 17)) != 0;
        NSString *special = RecompKeyCharacters(mac, shift);
        e->_characters = special ?: key.characters;
        e->_charactersIgnoringModifiers = special ?: key.charactersIgnoringModifiers;
    }
    e->_keyCode = mac;
    e->_modifierFlags = RecompModifierFlags;
    RecompDispatchEvent(e);
}

void RecompInstallTouchPad(UIView *root);

@implementation RecompViewController
- (void)loadView { self.view = [[RecompRootView alloc] initWithFrame:UIScreen.mainScreen.bounds]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    gController = self;
    RecompInstallTouchPad(self.view);
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(mouseConnected:) name:GCMouseDidConnectNotification object:nil];
    for (GCMouse *m in GCMouse.mice) [self watchMouse:m];
}
- (void)mouseConnected:(NSNotification *)n { [self watchMouse:n.object]; }
- (void)watchMouse:(GCMouse *)m {
    // Relative motion while the pointer is locked (camera look).
    m.mouseInput.mouseMovedHandler = ^(GCMouseInput *input, float dx, float dy) {
        if (!gLocked) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            RNSEvent *e = [RNSEvent recompEventWithType:RecompPressedButtons & 1 ? kLDrag : RecompPressedButtons & 2 ? kRDrag : kMoved];
            RNSWindow *w = [(RNSApplication *)NSApp keyWindow];
            e->_window = w;
            e->_location = [w convertPointFromScreen:RecompMouseLocation];
            e->_deltaX = dx;
            e->_deltaY = -dy;
            RecompDispatchEvent(e);
        });
    };
}
- (BOOL)prefersPointerLocked { return gLocked; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (BOOL)canBecomeFirstResponder { return YES; }
- (void)viewDidAppear:(BOOL)a { [super viewDidAppear:a]; [self becomeFirstResponder]; }
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *p in presses) SendKey(p, YES);
}
- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *p in presses) SendKey(p, NO);
}
- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *p in presses) SendKey(p, NO);
}
@end
