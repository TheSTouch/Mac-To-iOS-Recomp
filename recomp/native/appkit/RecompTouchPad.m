// On-screen gamepad. Touches drive a software GCController (made with
// +controllerWithExtendedGamepad) that the game finds like a real one, in
// +[GCController controllers]. Games read gamepads through GameController, so
// their button prompts stay on the gamepad glyphs.
//
// Layout: touch the left half to get a floating move stick, the right half
// for a floating camera stick; A/B/X/Y bottom right, shoulders and triggers
// along the top edges, Menu and View top left. Hidden while a physical
// controller is connected. Pointer devices (trackpad, mouse) pass through.
#import "RecompAppKit.h"
#import <GameController/GameController.h>
#import <objc/runtime.h>

static GCController *gPad;

@interface RecompPadButton : NSObject
@property (copy) NSString *name;
@property CGPoint center;   // relative: x from the left (>0) or right (<0) edge, y from the bottom (>0) or top (<0) edge
@property CGFloat radius;
@property (strong) CAShapeLayer *layer;
@property (strong) CATextLayer *label;
@property (copy) GCControllerButtonInput * (^input)(GCExtendedGamepad *);
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
    b.label.fontSize = r > 26 ? 20 : 13;
    b.label.alignmentMode = kCAAlignmentCenter;
    b.label.foregroundColor = Ink(0.75).CGColor;
    b.label.contentsScale = UIScreen.mainScreen.scale;
    [self.layer addSublayer:b.layer];
    [self.layer addSublayer:b.label];
    return b;
}

static const CGFloat kStickTravel = 110; // points of drag for full deflection
static const CGFloat kDeadZone = 0.1;

- (RecompStick *)stick:(GCControllerDirectionPad * (^)(GCExtendedGamepad *))input curve:(CGFloat)curve {
    RecompStick *s = [RecompStick new];
    s.input = input;
    s.curve = curve;
    s.base = [CAShapeLayer layer];
    s.base.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(-kStickTravel, -kStickTravel, 2 * kStickTravel, 2 * kStickTravel)].CGPath;
    s.base.fillColor = Ink(0.06).CGColor;
    s.base.strokeColor = Ink(0.3).CGColor;
    s.knob = [CAShapeLayer layer];
    s.knob.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(-28, -28, 56, 56)].CGPath;
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
        ];
        _left = [self stick:^(GCExtendedGamepad *g) { return g.leftThumbstick; } curve:1.3];
        _right = [self stick:^(GCExtendedGamepad *g) { return g.rightThumbstick; } curve:1.8]; // camera
    }
    return self;
}

- (CGPoint)place:(CGPoint)rel {
    CGSize s = self.bounds.size;
    return CGPointMake(rel.x >= 0 ? rel.x : s.width + rel.x, rel.y >= 0 ? s.height - rel.y : -rel.y);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (RecompPadButton *b in _buttons) {
        CGPoint c = [self place:b.center];
        b.layer.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.x - b.radius, c.y - b.radius, 2 * b.radius, 2 * b.radius)].CGPath;
        CGFloat h = b.label.fontSize + 4;
        b.label.frame = CGRectMake(c.x - b.radius, c.y - h / 2, 2 * b.radius, h);
    }
    [CATransaction commit];
}

- (RecompPadButton *)buttonAt:(CGPoint)p {
    for (RecompPadButton *b in _buttons) {
        CGPoint c = [self place:b.center];
        if (hypot(p.x - c.x, p.y - c.y) <= b.radius + 12) return b;
    }
    return nil;
}

- (void)press:(RecompPadButton *)b down:(BOOL)down {
    [b.input(gPad.extendedGamepad) setValue:down ? 1 : 0];
    b.layer.fillColor = Ink(down ? 0.4 : 0.12).CGColor;
}

- (void)moveStick:(RecompStick *)s to:(CGPoint)p {
    CGFloat dx = p.x - s.origin.x, dy = p.y - s.origin.y;
    CGFloat len = hypot(dx, dy);
    if (len > kStickTravel) { dx *= kStickTravel / len; dy *= kStickTravel / len; len = kStickTravel; }
    // Dead zone, then a power curve on the magnitude: small drags give small,
    // precise values; the edge of the circle is still full deflection.
    CGFloat m = len / kStickTravel, out = m <= kDeadZone ? 0 : pow((m - kDeadZone) / (1 - kDeadZone), s.curve);
    CGFloat k = len > 0 ? out / m : 0;
    [s.input(gPad.extendedGamepad) setValueForXAxis:dx / kStickTravel * k yAxis:-dy / kStickTravel * k];
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

void RecompRaiseTouchPad(void) {
    if (gTouchPad.superview) [gTouchPad.superview bringSubviewToFront:gTouchPad];
}
