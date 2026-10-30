// On-screen gamepad. Touches drive a software GCController (made with
// +controllerWithExtendedGamepad) that the game finds like a real one, in
// +[GCController controllers]. Games read gamepads through GameController, so
// their button prompts stay on the gamepad glyphs.
//
// Layout: touch the left half to get a floating move stick, the right half
// for a floating camera stick; A/B/X/Y bottom right, a D-pad on the left edge
// above L3, shoulders and triggers along the top edges, Menu and View top left.
// Hidden while a physical controller is connected. Pointer devices (trackpad,
// mouse) pass through.
//
// Positions and sizes are for an iPad's screen height; a shorter screen (a phone
// in landscape) scales them down, never below thumb size. On an iPad they count
// from the safe area's sides. On a phone held sideways they count from the screen's
// side edges, each side's outermost control a small margin in, using the space above
// and below the Dynamic Island (or notch): a control over the island's keep-out zone
// slides out of its band toward its own edge (or, with no room there, inward), one in
// a rounded corner moves in until it is clear, and the D-pad sits at mid height, right
// beside the island when the island is on the left, else at the left edge. Menu and
// View move inward and LT and RT up into the corners, leaving room above the island.
// No public API gives the island's shape, so it is guessed from the side safe inset.
#import "RecompAppKit.h"
#import <GameController/GameController.h>
#import <objc/runtime.h>

static GCController *gPad;

@interface RecompPadButton : NSObject
@property (copy) NSString *name;
@property CGPoint center;   // relative: x from the left (>0) or right (<0) edge, y from the bottom (>0) or top (<0) edge
@property CGPoint edge;     // relative, on a phone held sideways, where it differs from center (else zero)
@property CGPoint point;    // on screen, set by -layoutSubviews
@property CGFloat radius;   // at scale 1 (an iPad)
@property (strong) CAShapeLayer *layer;
@property (strong) CATextLayer *label;
@property (copy) GCControllerButtonInput * (^input)(GCExtendedGamepad *); // nil for a D-pad arm
@property CGVector dpad;    // a D-pad arm's direction, y up
@property BOOL down;
@end
@implementation RecompPadButton
@end

@interface RecompStick : NSObject
@property CGPoint origin;
@property CGFloat curve; // response exponent: higher = finer control near the centre
@property (strong) CAShapeLayer *base, *knob;
@property (copy) GCControllerDirectionPad * (^input)(GCExtendedGamepad *);
@end
@implementation RecompStick
@end

@interface RecompTouchPad : UIView
@end

@implementation RecompTouchPad {
    NSArray<RecompPadButton *> *_buttons;
    RecompStick *_left, *_right;
    NSMapTable<UITouch *, id> *_owners; // touch -> button or stick
    CGFloat _scale; // layout scale for this screen height: 1 on an iPad
    CGFloat _fromLeft, _fromRight; // where relative x counts from, in from each side
    BOOL _edges;    // a phone held sideways: controls against the screen's side edges
    CGRect _cutout; // with _edges, the Dynamic Island's or notch's keep-out zone
    CGPoint _dpad;  // the D-pad's centre on screen
    UIWindowScene *_scene; // observed: turning the phone over changes no size or inset
}

static UIColor *Ink(CGFloat a) { return [UIColor colorWithWhite:1 alpha:a]; }

- (RecompPadButton *)button:(NSString *)name at:(CGPoint)c radius:(CGFloat)r input:(GCControllerButtonInput * (^)(GCExtendedGamepad *))input {
    RecompPadButton *b = [RecompPadButton new];
    b.name = name; b.center = c; b.radius = r; b.input = input;
    b.layer = [CAShapeLayer layer];
    b.layer.fillColor = Ink(0.12).CGColor;
    b.layer.strokeColor = Ink(0.45).CGColor;
    b.layer.lineWidth = 1.5;
    b.label = [CATextLayer layer];
    b.label.string = name;
    b.label.alignmentMode = kCAAlignmentCenter;
    b.label.foregroundColor = Ink(0.75).CGColor;
    b.label.contentsScale = UIScreen.mainScreen.scale;
    [self.layer addSublayer:b.layer];
    [self.layer addSublayer:b.label];
    return b;
}

static const CGFloat kStickTravel = 110; // points of drag for full deflection, at scale 1
static const CGFloat kDeadZone = 0.1;
static const CGFloat kDesignHeight = 600; // screens at least this tall use scale 1
static const CGFloat kMinScale = 0.7;     // A/B/X/Y stay 44 points wide
static const CGFloat kMinRadius = 18;     // nor the small buttons under 36
static const CGPoint kDPad = {84, 200};   // D-pad centre, between L3 and LT
static const CGFloat kDPadArm = 44;       // centre to each arm
// A phone held sideways. No public API gives the cutout, so it is guessed from the side
// safe inset: from 50 points a Dynamic Island, from 44 a notch; either centred on the edge.
static const CGFloat kNotchInset = 44;
static const CGFloat kIslandInset = 50;
static const CGSize kIsland = {37, 126};  // across, along the edge
static const CGFloat kIslandGap = 11;     // from the screen's edge
static const CGSize kNotch = {30, 210};   // at the edge
static const CGFloat kCutoutClear = 6;    // keep-out zone around either
static const CGFloat kEdgeMargin = 8;     // outermost control to the screen's side edge, at scale 1
static const CGFloat kCornerRadius = 55;  // the screen's rounded corners: discs stay inside

- (RecompPadButton *)arm:(NSString *)name label:(NSString *)label dx:(CGFloat)dx dy:(CGFloat)dy {
    RecompPadButton *b = [self button:name at:CGPointMake(kDPad.x + dx * kDPadArm, kDPad.y + dy * kDPadArm) radius:20 input:nil];
    b.dpad = CGVectorMake(dx, dy);
    b.label.string = label;
    return b;
}

- (RecompStick *)stick:(GCControllerDirectionPad * (^)(GCExtendedGamepad *))input curve:(CGFloat)curve {
    RecompStick *s = [RecompStick new];
    s.input = input;
    s.curve = curve;
    s.base = [CAShapeLayer layer];
    s.base.fillColor = Ink(0.06).CGColor;
    s.base.strokeColor = Ink(0.3).CGColor;
    s.knob = [CAShapeLayer layer];
    s.knob.fillColor = Ink(0.35).CGColor;
    s.base.hidden = s.knob.hidden = YES;
    [self.layer addSublayer:s.base];
    [self.layer addSublayer:s.knob];
    return s;
}

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = YES;
        self.backgroundColor = UIColor.clearColor;
        _owners = [NSMapTable strongToStrongObjectsMapTable];
        _scale = 1;
        CGFloat k = 62; // face-button spacing
        _buttons = @[
            [self button:@"A" at:CGPointMake(-140, 90) radius:32 input:^(GCExtendedGamepad *g) { return g.buttonA; }],
            [self button:@"B" at:CGPointMake(-140 + k, 90 + k) radius:32 input:^(GCExtendedGamepad *g) { return g.buttonB; }],
            [self button:@"X" at:CGPointMake(-140 - k, 90 + k) radius:32 input:^(GCExtendedGamepad *g) { return g.buttonX; }],
            [self button:@"Y" at:CGPointMake(-140, 90 + 2 * k) radius:32 input:^(GCExtendedGamepad *g) { return g.buttonY; }],
            [self button:@"LB" at:CGPointMake(56, -170) radius:24 input:^(GCExtendedGamepad *g) { return g.leftShoulder; }],
            [self button:@"LT" at:CGPointMake(56, -110) radius:24 input:^(GCExtendedGamepad *g) { return g.leftTrigger; }],
            [self button:@"RB" at:CGPointMake(-56, -170) radius:24 input:^(GCExtendedGamepad *g) { return g.rightShoulder; }],
            [self button:@"RT" at:CGPointMake(-56, -110) radius:24 input:^(GCExtendedGamepad *g) { return g.rightTrigger; }],
            [self button:@"Menu" at:CGPointMake(48, -34) radius:22 input:^(GCExtendedGamepad *g) { return g.buttonMenu; }],
            [self button:@"View" at:CGPointMake(108, -34) radius:22 input:^(GCExtendedGamepad *g) { return g.buttonOptions; }],
            [self button:@"L3" at:CGPointMake(56, 60) radius:22 input:^(GCExtendedGamepad *g) { return g.leftThumbstickButton; }],
            [self button:@"R3" at:CGPointMake(-260, 50) radius:22 input:^(GCExtendedGamepad *g) { return g.rightThumbstickButton; }],
            [self arm:@"Up" label:@"\u2191" dx:0 dy:1],
            [self arm:@"Down" label:@"\u2193" dx:0 dy:-1],
            [self arm:@"Left" label:@"\u2190" dx:-1 dy:0],
            [self arm:@"Right" label:@"\u2192" dx:1 dy:0],
        ];
        // A phone held sideways: Menu and View move inward, LT and RT up into the corners,
        // leaving room above the Dynamic Island for LB or RB.
        [self buttonNamed:@"Menu"].edge = CGPointMake(136, -34);
        [self buttonNamed:@"View"].edge = CGPointMake(196, -34);
        [self buttonNamed:@"LT"].edge = CGPointMake(56, -60);
        [self buttonNamed:@"RT"].edge = CGPointMake(-56, -60);
        _left = [self stick:^(GCExtendedGamepad *g) { return g.leftThumbstick; } curve:1.3];
        _right = [self stick:^(GCExtendedGamepad *g) { return g.rightThumbstick; } curve:1.8]; // camera
    }
    return self;
}

- (CGPoint)place:(CGPoint)rel {
    CGSize s = self.bounds.size;
    CGFloat x = rel.x * _scale, y = rel.y * _scale;
    return CGPointMake(x >= 0 ? _fromLeft + x : s.width - _fromRight + x, y >= 0 ? s.height - y : -y);
}

- (CGPoint)rel:(RecompPadButton *)b { return _edges && !CGPointEqualToPoint(b.edge, CGPointZero) ? b.edge : b.center; }

- (CGFloat)radius:(RecompPadButton *)b { return MAX(b.radius * _scale, MIN(b.radius, kMinRadius)); }

// A disc in one of the screen's rounded corners moves toward the corner's centre until it is inside.
- (CGPoint)inCorner:(CGPoint)c radius:(CGFloat)r {
    CGSize s = self.bounds.size;
    CGFloat R = kCornerRadius;
    CGPoint o = CGPointMake(c.x < R ? R : c.x > s.width - R ? s.width - R : c.x, c.y < R ? R : c.y > s.height - R ? s.height - R : c.y);
    CGFloat d = hypot(c.x - o.x, c.y - o.y);
    if (d + r <= R) return c;
    return CGPointMake(o.x + (c.x - o.x) * (R - r) / d, o.y + (c.y - o.y) * (R - r) / d);
}

- (BOOL)overCutout:(CGPoint)c radius:(CGFloat)r {
    CGFloat x = MAX(CGRectGetMinX(_cutout), MIN(c.x, CGRectGetMaxX(_cutout)));
    CGFloat y = MAX(CGRectGetMinY(_cutout), MIN(c.y, CGRectGetMaxY(_cutout)));
    return hypot(c.x - x, c.y - y) < r;
}

- (BOOL)fits:(RecompPadButton *)b at:(CGPoint)c radius:(CGFloat)r {
    if (c.y - r < 0 || c.y + r > self.bounds.size.height || [self overCutout:c radius:r]) return NO;
    for (RecompPadButton *o in _buttons)
        if (o != b && hypot(c.x - o.point.x, c.y - o.point.y) < r + [self radius:o]) return NO;
    return YES;
}

// A control on a phone held sideways: inside the rounded corners, and clear of the cutout's
// keep-out zone, sliding out of its band toward the control's own edge (top or bottom), or,
// if it does not fit there, inward just enough.
- (CGPoint)fit:(RecompPadButton *)b {
    CGFloat r = [self radius:b];
    CGPoint c = [self inCorner:b.point radius:r];
    if (![self overCutout:c radius:r]) return c;
    CGFloat y = b.center.y < 0 ? CGRectGetMinY(_cutout) - r : CGRectGetMaxY(_cutout) + r;
    CGPoint slid = [self inCorner:CGPointMake(c.x, y) radius:r];
    if ([self fits:b at:slid radius:r]) return slid;
    BOOL left = CGRectGetMidX(_cutout) < self.bounds.size.width / 2;
    return CGPointMake(left ? CGRectGetMaxX(_cutout) + r : CGRectGetMinX(_cutout) - r, c.y);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize s = self.bounds.size;
    _scale = MAX(MIN(s.height / kDesignHeight, 1), kMinScale);
    UIEdgeInsets in = self.safeAreaInsets;
    CGFloat inset = MAX(in.left, in.right);
    UIInterfaceOrientation o = self.window.windowScene.interfaceOrientation;
    _edges = inset >= kNotchInset && UIInterfaceOrientationIsLandscape(o);
    _fromLeft = in.left; _fromRight = in.right;
    CGFloat margin = kEdgeMargin * _scale, reach = kDPadArm * _scale + [self radius:[self buttonNamed:@"Left"]];
    _dpad = [self place:kDPad];
    if (_edges) {
        // Each side's controls (not the D-pad) move together, the outermost at the margin.
        CGFloat outL = INFINITY, outR = INFINITY;
        for (RecompPadButton *b in _buttons) {
            if (!b.input) continue;
            CGFloat out = fabs([self rel:b].x) * _scale - [self radius:b];
            if ([self rel:b].x > 0) outL = MIN(outL, out); else outR = MIN(outR, out);
        }
        _fromLeft = margin - outL; _fromRight = margin - outR;
        // The island is at the phone's top: on the left when the interface is landscapeRight.
        BOOL island = inset >= kIslandInset, left = o == UIInterfaceOrientationLandscapeRight;
        CGSize z = island ? kIsland : kNotch;
        CGFloat gap = island ? kIslandGap : 0;
        _cutout = CGRectInset(CGRectMake(left ? gap : s.width - gap - z.width, (s.height - z.height) / 2, z.width, z.height),
                              -kCutoutClear, -kCutoutClear);
        _dpad = CGPointMake((left ? CGRectGetMaxX(_cutout) : 0) + margin + reach, s.height / 2);
    }
    for (RecompPadButton *b in _buttons)
        b.point = b.input ? [self place:[self rel:b]]
            : CGPointMake(_dpad.x + b.dpad.dx * kDPadArm * _scale, _dpad.y - b.dpad.dy * kDPadArm * _scale);
    if (_edges)
        for (RecompPadButton *b in _buttons)
            if (b.input) b.point = [self fit:b];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (RecompPadButton *b in _buttons) {
        CGPoint c = b.point;
        CGFloat r = [self radius:b];
        b.layer.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r)].CGPath;
        b.label.fontSize = round((b.radius > 26 || b.input == nil ? 20 : 13) * MAX(_scale, 0.85));
        CGFloat h = b.label.fontSize + 4;
        b.label.frame = CGRectMake(c.x - r, c.y - h / 2, 2 * r, h);
    }
    CGFloat t = kStickTravel * _scale, k = 28 * _scale;
    for (RecompStick *st in @[_left, _right]) {
        st.base.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(-t, -t, 2 * t, 2 * t)].CGPath;
        st.knob.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(-k, -k, 2 * k, 2 * k)].CGPath;
    }
    [CATransaction commit];
}

- (void)safeAreaInsetsDidChange {
    [super safeAreaInsetsDidChange];
    [self setNeedsLayout];
}

// Turning a phone from one landscape to the other moves the island to the other side.
- (void)didMoveToWindow {
    [super didMoveToWindow];
    UIWindowScene *scene = self.window.windowScene;
    if (scene == _scene) return;
    [_scene removeObserver:self forKeyPath:@"effectiveGeometry"];
    _scene = scene;
    [_scene addObserver:self forKeyPath:@"effectiveGeometry" options:0 context:NULL];
}

- (void)observeValueForKeyPath:(NSString *)path ofObject:(id)o change:(NSDictionary *)change context:(void *)ctx {
    [self setNeedsLayout];
}

// The D-pad's arms share one disc, split by direction from its centre: no
// touch on it, not even between the arms, starts the move stick.
- (RecompPadButton *)armAt:(CGPoint)p {
    CGFloat dx = p.x - _dpad.x, dy = _dpad.y - p.y, best = -INFINITY;
    RecompPadButton *arm = nil;
    for (RecompPadButton *b in _buttons) {
        if (b.input || hypot(dx, dy) > kDPadArm * _scale + [self radius:b] + 12 * _scale) continue;
        CGFloat dot = dx * b.dpad.dx + dy * b.dpad.dy;
        if (dot > best) { best = dot; arm = b; }
    }
    return arm;
}

- (RecompPadButton *)buttonAt:(CGPoint)p {
    RecompPadButton *arm = [self armAt:p];
    if (arm) return arm;
    for (RecompPadButton *b in _buttons) {
        CGPoint c = b.point;
        if (b.input && hypot(p.x - c.x, p.y - c.y) <= [self radius:b] + 12 * _scale) return b;
    }
    return nil;
}

- (RecompPadButton *)buttonNamed:(NSString *)name {
    for (RecompPadButton *b in _buttons)
        if ([b.name caseInsensitiveCompare:name] == NSOrderedSame) return b;
    return nil;
}

- (void)press:(RecompPadButton *)b down:(BOOL)down {
    b.down = down;
    b.layer.fillColor = Ink(down ? 0.4 : 0.12).CGColor;
    if (b.input) { [b.input(gPad.extendedGamepad) setValue:down ? 1 : 0]; return; }
    // A D-pad arm: the pad's axes from every arm held, set the way
    // RecompPadScript sets them, which also presses its up/down/left/right.
    CGFloat x = 0, y = 0;
    for (RecompPadButton *a in _buttons)
        if (!a.input && a.down) { x += a.dpad.dx; y += a.dpad.dy; }
    [gPad.extendedGamepad.dpad setValueForXAxis:x yAxis:y];
}

- (void)moveStick:(RecompStick *)s to:(CGPoint)p {
    CGFloat travel = kStickTravel * _scale;
    CGFloat dx = p.x - s.origin.x, dy = p.y - s.origin.y;
    CGFloat len = hypot(dx, dy);
    if (len > travel) { dx *= travel / len; dy *= travel / len; len = travel; }
    // Dead zone, then a power curve on the magnitude: small drags give small,
    // precise values; the edge of the circle is still full deflection.
    CGFloat m = len / travel, out = m <= kDeadZone ? 0 : pow((m - kDeadZone) / (1 - kDeadZone), s.curve);
    CGFloat k = len > 0 ? out / m : 0;
    [s.input(gPad.extendedGamepad) setValueForXAxis:dx / travel * k yAxis:-dy / travel * k];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    s.knob.position = CGPointMake(s.origin.x + dx, s.origin.y + dy);
    [CATransaction commit];
}

- (void)showStick:(RecompStick *)s at:(CGPoint)p {
    s.origin = p;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    s.base.position = s.knob.position = p;
    s.base.hidden = s.knob.hidden = NO;
    [CATransaction commit];
    [s.input(gPad.extendedGamepad) setValueForXAxis:0 yAxis:0];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e {
    NSMutableSet *pointer = [NSMutableSet set];
    for (UITouch *t in touches) {
        if (t.type == UITouchTypeIndirectPointer) { [pointer addObject:t]; continue; }
        CGPoint p = [t locationInView:self];
        RecompPadButton *b = [self buttonAt:p];
        if (b) {
            [_owners setObject:b forKey:t];
            [self press:b down:YES];
            continue;
        }
        RecompStick *s = p.x < self.bounds.size.width / 2 ? _left : _right;
        if ([[_owners.objectEnumerator allObjects] containsObject:s]) continue; // stick already held
        [_owners setObject:s forKey:t];
        [self showStick:s at:p];
    }
    if (pointer.count) [RecompRoot() touchesBegan:pointer withEvent:e];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e {
    NSMutableSet *pointer = [NSMutableSet set];
    for (UITouch *t in touches) {
        if (t.type == UITouchTypeIndirectPointer) { [pointer addObject:t]; continue; }
        id o = [_owners objectForKey:t];
        if ([o isKindOfClass:[RecompStick class]]) [self moveStick:o to:[t locationInView:self]];
        // A thumb rolled from one D-pad arm to the next presses the new one.
        RecompPadButton *arm = [o isKindOfClass:[RecompPadButton class]] && ![o input] ? [self armAt:[t locationInView:self]] : nil;
        if (arm && arm != o) {
            [_owners setObject:arm forKey:t];
            [self press:o down:NO];
            [self press:arm down:YES];
        }
    }
    if (pointer.count) [RecompRoot() touchesMoved:pointer withEvent:e];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e {
    NSMutableSet *pointer = [NSMutableSet set];
    for (UITouch *t in touches) {
        if (t.type == UITouchTypeIndirectPointer) { [pointer addObject:t]; continue; }
        id o = [_owners objectForKey:t];
        [_owners removeObjectForKey:t];
        if ([o isKindOfClass:[RecompPadButton class]]) {
            [self press:o down:NO];
        } else if ([o isKindOfClass:[RecompStick class]]) {
            RecompStick *s = o;
            [s.input(gPad.extendedGamepad) setValueForXAxis:0 yAxis:0];
            s.base.hidden = s.knob.hidden = YES;
        }
    }
    if (pointer.count) [RecompRoot() touchesEnded:pointer withEvent:e];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e { [self touchesEnded:touches withEvent:e]; }
@end

// --- the software controller ---------------------------------------------------------

static IMP oControllers;
static NSArray *Controllers(id self, SEL s) {
    NSArray *real = ((NSArray * (*)(id, SEL))oControllers)(self, s);
    return gPad && ![real containsObject:gPad] ? [real arrayByAddingObject:gPad] : real;
}

static RecompTouchPad *gTouchPad;

static BOOL PhysicalConnected(void) {
    for (GCController *c in ((NSArray * (*)(id, SEL))oControllers)([GCController class], @selector(controllers)))
        if (c != gPad && c.extendedGamepad) return YES;
    return NO;
}

static void UpdateVisibility(void) {
    BOOL physical = PhysicalConnected();
    if (gTouchPad.hidden != physical) RLOG(@"%@", physical ? @"physical controller: hiding the touch controls" : @"touch controls shown");
    gTouchPad.hidden = physical;
}

void RecompInstallTouchPad(UIView *root) {
    if (!gPad) {
        gPad = [GCController controllerWithExtendedGamepad];
        gPad.playerIndex = GCControllerPlayerIndex1;
        Method m = class_getClassMethod([GCController class], @selector(controllers));
        oControllers = method_setImplementation(m, (IMP)Controllers);
    }
    gTouchPad = [[RecompTouchPad alloc] initWithFrame:root.bounds];
    gTouchPad.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root addSubview:gTouchPad];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    for (NSString *n in @[GCControllerDidConnectNotification, GCControllerDidDisconnectNotification])
        [nc addObserverForName:n object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            if (note.object != gPad) UpdateVisibility();
        }];
    // The game finds it through +[GCController controllers] when its controller
    // support starts, which is after launch: no connect notification needed.
    UpdateVisibility();
}

// Presses from a script, for testing on a device nobody is holding (see the
// recomp-press file in RecompDebug.m): button names as labelled on screen,
// up/down/left/right for the d-pad, "wait" for a second. Main thread only.
void RecompPadScript(NSArray<NSString *> *steps) {
    if (!gPad || !steps.count) return;
    NSString *step = steps.firstObject;
    NSArray *rest = [steps subarrayWithRange:NSMakeRange(1, steps.count - 1)];
    dispatch_block_t next = ^{ RecompPadScript(rest); };
    GCExtendedGamepad *g = gPad.extendedGamepad;
    NSDictionary *dirs = @{@"up": @[@0, @1], @"down": @[@0, @-1], @"left": @[@-1, @0], @"right": @[@1, @0]};
    void (^release)(void) = nil;
    NSArray *dir = dirs[step.lowercaseString]; // before the on-screen arms, named Up, Down...
    if (dir) {
        [g.dpad setValueForXAxis:[dir[0] floatValue] yAxis:[dir[1] floatValue]];
        release = ^{ [g.dpad setValueForXAxis:0 yAxis:0]; };
    } else if ([gTouchPad buttonNamed:step]) {
        RecompPadButton *b = [gTouchPad buttonNamed:step];
        [b.input(g) setValue:1];
        release = ^{ [b.input(g) setValue:0]; };
    }
    RLOG(@"press: %@%@", step, release || [step isEqualToString:@"wait"] ? @"" : @" (no such button)");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (release) release();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (release ? 450 : 850) * NSEC_PER_MSEC), dispatch_get_main_queue(), next);
    });
}

void RecompRaiseTouchPad(void) {
    if (gTouchPad.superview) [gTouchPad.superview bringSubviewToFront:gTouchPad];
}
