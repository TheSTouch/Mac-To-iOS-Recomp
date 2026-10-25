// AppKit on UIKit: just enough of AppKit for a native Mac game binary to run
// on iPadOS. The classes are named RNS* and exported under the AppKit names
// (_OBJC_CLASS_$_NSWindow -> RNSWindow, see build flags), so they never clash
// with a class iOS already has under that name.
//
// Coordinates follow AppKit: screen origin bottom-left, y up, in points.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#define RLOG(fmt, ...) NSLog(@"[recomp] " fmt, ##__VA_ARGS__)

typedef CGRect NSRect;
typedef CGPoint NSPoint;
typedef CGSize NSSize;

// --- shared state ---------------------------------------------------------

@class RNSWindow, RNSView, RNSEvent;

// Root UIKit view that hosts every visible NSWindow and turns touches,
// keys and pointer moves into NSEvents.
@interface RecompRootView : UIView
@end

@interface RecompViewController : UIViewController
@end

// Screen size in points (landscape), valid from any thread after launch.
CGSize RecompScreenSize(void);
CGFloat RecompScreenScale(void);
// Delivers an event the way AppKit does: local monitors, then -[NSApp sendEvent:].
void RecompDispatchEvent(RNSEvent *event);
// Root view, main thread only; nil before launch.
RecompRootView *RecompRoot(void);
void RecompOnMain(dispatch_block_t block);
// Last known pointer position in screen coordinates.
extern NSPoint RecompMouseLocation;
extern NSUInteger RecompPressedButtons;
extern NSUInteger RecompModifierFlags;
// Cursor state driven by NSCursor / CGDisplayHideCursor / CGAssociateMouse...
void RecompSetCursorHidden(BOOL hidden);
void RecompSetPointerLocked(BOOL locked);
// Keeps the on-screen gamepad above the game's windows.
void RecompRaiseTouchPad(void);
BOOL RecompPointerLocked(void);

// --- classes ---------------------------------------------------------------

@interface RNSResponder : NSObject
@property (assign) RNSResponder *nextResponder;
@end

@interface RNSView : RNSResponder
@property (readonly) UIView *uiView;
@property (nonatomic) NSRect frame;
@property (nonatomic) NSRect bounds;
@property (assign) RNSView *superview;
@property (assign) RNSWindow *window;
@property (nonatomic, strong) CALayer *layer;
@property (nonatomic) BOOL wantsLayer;
@property (nonatomic) NSUInteger autoresizingMask;
@property (nonatomic, getter=isHidden) BOOL hidden;
- (instancetype)initWithFrame:(NSRect)frame;
- (NSArray *)subviews;
- (void)addSubview:(RNSView *)view;
- (void)removeFromSuperview;
- (void)recompSetWindow:(RNSWindow *)window;
@end

@interface RNSWindow : RNSResponder
@property (nonatomic) NSRect frame;
@property (nonatomic, strong) RNSView *contentView;
@property (assign) id delegate;
@property (nonatomic) NSUInteger styleMask;
@property (nonatomic) NSInteger level;
@property (nonatomic, readonly) NSInteger windowNumber;
@property (nonatomic, getter=isVisible) BOOL visible;
@property (assign) RNSResponder *firstResponder;
- (void)recompLayout;
- (UIView *)recompFrameView;
- (BOOL)ignoresMouseEvents;
- (NSPoint)convertPointFromScreen:(NSPoint)p;
@end

// UIViews that stand for an NSWindow / NSView answer -owner.
@protocol RecompOwned
- (id)owner;
@end

@interface RNSEvent : NSObject {
@public
    NSUInteger _type, _modifierFlags, _keyCode;
    NSPoint _location; // in the window, or the screen when window is nil
    NSTimeInterval _timestamp;
    __weak RNSWindow *_window;
    NSInteger _windowNumber, _buttonNumber, _clickCount, _subtype, _data1, _data2;
    CGFloat _deltaX, _deltaY, _scrollX, _scrollY;
    BOOL _precise, _repeat;
    NSUInteger _phase, _momentumPhase;
    NSString *_characters, *_charactersIgnoringModifiers;
}
+ (RNSEvent *)recompEventWithType:(NSUInteger)type;
@end

@interface RNSApplication : RNSResponder
@property (assign) id delegate;
@property (strong) NSMutableArray *recompWindows;
- (void)sendEvent:(RNSEvent *)event;
- (id)keyWindow;
@end

extern id NSApp;

// Mac virtual key code for a USB HID usage (UIKeyboardHIDUsage); 0xFFFF if none.
uint16_t RecompMacKeyCode(long hidUsage);
// AppKit-style characters for a Mac key code (function keys use NSF* code points).
NSString *RecompKeyCharacters(uint16_t keyCode, BOOL shift);
