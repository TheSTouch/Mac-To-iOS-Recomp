// The rest of AppKit a game touches: cursors, images, colours, fonts, menus,
// the pasteboard, alerts, the workspace, accessibility and AppKit's constants.
// Most of it only needs to exist; what matters on iOS is implemented.
#import "RecompAppKit.h"
#import <objc/runtime.h>

id RecompMissing(id obj, SEL sel, BOOL isClass);
#define RECOMP_FORWARDING \
    - (id)forwardingTargetForSelector:(SEL)sel { return RecompMissing(self, sel, NO); } \
    + (id)forwardingTargetForSelector:(SEL)sel { return RecompMissing(self, sel, YES); }

// --- constants ------------------------------------------------------------------

#define K(name, value) NSString *const name = value;
K(NSAccessibilityAnnouncementKey, @"AXAnnouncementKey")
K(NSAccessibilityAnnouncementRequestedNotification, @"AXAnnouncementRequested")
K(NSAccessibilityButtonRole, @"AXButton")
K(NSAccessibilityCheckBoxRole, @"AXCheckBox")
K(NSAccessibilityComboBoxRole, @"AXComboBox")
K(NSAccessibilityImageRole, @"AXImage")
K(NSAccessibilityLayoutAreaRole, @"AXLayoutArea")
K(NSAccessibilityLinkRole, @"AXLink")
K(NSAccessibilityPriorityKey, @"AXPriorityKey")
K(NSAccessibilitySecureTextFieldSubrole, @"AXSecureTextField")
K(NSAccessibilitySliderRole, @"AXSlider")
K(NSAccessibilityStaticTextRole, @"AXStaticText")
K(NSAccessibilityTextFieldRole, @"AXTextField")
K(NSAccessibilityTextLinkSubrole, @"AXTextLink")
K(NSAccessibilityUIElementDestroyedNotification, @"AXUIElementDestroyed")
K(NSAccessibilityUnknownRole, @"AXUnknown")
K(NSAccessibilityValueChangedNotification, @"AXValueChanged")
K(NSAccessibilityWindowRole, @"AXWindow")
K(NSApplicationDidBecomeActiveNotification, @"NSApplicationDidBecomeActiveNotification")
K(NSApplicationWillResignActiveNotification, @"NSApplicationWillResignActiveNotification")
K(NSCalibratedRGBColorSpace, @"NSCalibratedRGBColorSpace")
// UIKit's run loop mode while touches track, so blocks scheduled for AppKit's
// tracking mode still run during a touch.
K(NSEventTrackingRunLoopMode, @"UITrackingRunLoopMode")
K(NSModalPanelRunLoopMode, @"NSModalPanelRunLoopMode")
K(NSPasteboardTypeFileURL, @"public.file-url")
K(NSPasteboardTypeString, @"public.utf8-plain-text")
K(NSViewBoundsDidChangeNotification, @"NSViewBoundsDidChangeNotification")
K(NSViewFrameDidChangeNotification, @"NSViewFrameDidChangeNotification")
K(NSWindowDidEndLiveResizeNotification, @"NSWindowDidEndLiveResizeNotification")
K(NSWindowDidEnterFullScreenNotification, @"NSWindowDidEnterFullScreenNotification")
K(NSWindowDidExitFullScreenNotification, @"NSWindowDidExitFullScreenNotification")
K(NSWindowDidMoveNotification, @"NSWindowDidMoveNotification")
K(NSWindowDidResizeNotification, @"NSWindowDidResizeNotification")
K(NSWindowWillMoveNotification, @"NSWindowWillMoveNotification")
K(NSWindowWillStartLiveResizeNotification, @"NSWindowWillStartLiveResizeNotification")
K(NSWorkspaceActiveSpaceDidChangeNotification, @"NSWorkspaceActiveSpaceDidChangeNotification")
K(NSWorkspaceSessionDidBecomeActiveNotification, @"NSWorkspaceSessionDidBecomeActiveNotification")
K(NSWorkspaceSessionDidResignActiveNotification, @"NSWorkspaceSessionDidResignActiveNotification")
// Attributed-string keys share their values with UIKit's.
K(RecompNSFontAttributeName, @"NSFont")
K(RecompNSForegroundColorAttributeName, @"NSColor")
K(RecompNSBackgroundColorAttributeName, @"NSBackgroundColor")
K(RecompNSParagraphStyleAttributeName, @"NSParagraphStyle")
K(RecompNSStrokeColorAttributeName, @"NSStrokeColor")
K(RecompNSStrokeWidthAttributeName, @"NSStrokeWidth")
K(RecompNSUnderlineStyleAttributeName, @"NSUnderline")
K(RecompNSGlyphInfoAttributeName, @"NSGlyphInfo")
K(RecompNSMarkedClauseSegmentAttributeName, @"NSMarkedClauseSegment")
K(RecompNSDocumentTypeDocumentAttribute, @"DocumentType")
K(RecompNSPlainTextDocumentType, @"NSPlainText")
#undef K

// Interposed for the game (see INTERCEPT in unreal_ios.py): asking NSURL for this
// key yields no value, so engine checks for a case-insensitive volume pass.
NSURLResourceKey const NSURLVolumeSupportsCaseSensitiveNamesKey = @"RecompVolumeCaseSensitivityNotReported";

void NSAccessibilityPostNotification(id element, NSString *notification) {}
void NSAccessibilityPostNotificationWithUserInfo(id element, NSString *notification, NSDictionary *info) {}
NSString *NSAccessibilityRoleDescription(NSString *role, NSString *subrole) { return role; }

NSInteger NSRunInformationalAlertPanel(NSString *title, NSString *format, NSString *def, NSString *alt, NSString *other, ...) {
    va_list ap;
    va_start(ap, other);
    NSString *msg = format ? [[NSString alloc] initWithFormat:format arguments:ap] : @"";
    va_end(ap);
    RLOG(@"alert panel: %@: %@", title, msg);
    return 1; // NSAlertDefaultReturn
}

// --- NSCursor -------------------------------------------------------------------

@interface RNSCursor : NSObject
@end
@implementation RNSCursor {
    id _image;
    NSPoint _hot;
}
RECOMP_FORWARDING
static RNSCursor *gCurrentCursor;
+ (instancetype)recompShared:(NSString *)name {
    static NSMutableDictionary *all;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ all = [NSMutableDictionary new]; });
    @synchronized (all) {
        if (!all[name]) all[name] = [RNSCursor new];
        return all[name];
    }
}
+ (id)arrowCursor { return [self recompShared:@"arrow"]; }
+ (id)IBeamCursor { return [self recompShared:@"ibeam"]; }
+ (id)pointingHandCursor { return [self recompShared:@"hand"]; }
+ (id)closedHandCursor { return [self recompShared:@"closed"]; }
+ (id)openHandCursor { return [self recompShared:@"open"]; }
+ (id)crosshairCursor { return [self recompShared:@"cross"]; }
+ (id)operationNotAllowedCursor { return [self recompShared:@"no"]; }
+ (id)resizeLeftRightCursor { return [self recompShared:@"lr"]; }
+ (id)resizeUpDownCursor { return [self recompShared:@"ud"]; }
+ (id)resizeLeftCursor { return [self recompShared:@"l"]; }
+ (id)resizeRightCursor { return [self recompShared:@"r"]; }
+ (id)resizeUpCursor { return [self recompShared:@"u"]; }
+ (id)resizeDownCursor { return [self recompShared:@"d"]; }
+ (id)disappearingItemCursor { return [self recompShared:@"gone"]; }
+ (id)dragCopyCursor { return [self recompShared:@"copy"]; }
+ (id)dragLinkCursor { return [self recompShared:@"link"]; }
+ (id)contextualMenuCursor { return [self recompShared:@"menu"]; }
+ (id)IBeamCursorForVerticalLayout { return [self recompShared:@"vibeam"]; }
+ (id)currentCursor { return gCurrentCursor ?: [self arrowCursor]; }
+ (id)currentSystemCursor { return [self currentCursor]; }
+ (void)hide { RecompSetCursorHidden(YES); }
+ (void)unhide { RecompSetCursorHidden(NO); }
+ (void)setHiddenUntilMouseMoves:(BOOL)b {}
+ (void)pop {}
- (instancetype)initWithImage:(id)image hotSpot:(NSPoint)hot {
    if ((self = [super init])) { _image = image; _hot = hot; }
    return self;
}
- (void)set { gCurrentCursor = self; }
- (void)push { gCurrentCursor = self; }
- (void)pop {}
- (id)image { return _image; }
- (NSPoint)hotSpot { return _hot; }
- (void)setOnMouseEntered:(BOOL)b {}
- (void)setOnMouseExited:(BOOL)b {}
@end

// --- images ------------------------------------------------------------------------

@interface RNSBitmapImageRep : NSObject
@end
@implementation RNSBitmapImageRep {
    NSMutableData *_data;
    NSInteger _w, _h, _bpr, _spp, _bps;
    BOOL _alpha;
}
RECOMP_FORWARDING
+ (id)imageRepWithData:(NSData *)d { return [[self alloc] initWithData:d]; }
- (instancetype)initWithData:(NSData *)d {
    UIImage *img = [UIImage imageWithData:d];
    if (!img) return nil;
    CGImageRef cg = img.CGImage;
    if ((self = [self initWithBitmapDataPlanes:NULL pixelsWide:CGImageGetWidth(cg) pixelsHigh:CGImageGetHeight(cg)
                                 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:@"NSDeviceRGBColorSpace"
                                  bitmapFormat:0 bytesPerRow:0 bitsPerPixel:0])) {
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(_data.mutableBytes, _w, _h, 8, _bpr, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGContextDrawImage(ctx, CGRectMake(0, 0, _w, _h), cg);
        CGContextRelease(ctx);
        CGColorSpaceRelease(cs);
    }
    return self;
}
- (instancetype)initWithBitmapDataPlanes:(unsigned char **)planes pixelsWide:(NSInteger)w pixelsHigh:(NSInteger)h
                           bitsPerSample:(NSInteger)bps samplesPerPixel:(NSInteger)spp hasAlpha:(BOOL)alpha isPlanar:(BOOL)planar
                          colorSpaceName:(NSString *)cs bitmapFormat:(NSUInteger)fmt bytesPerRow:(NSInteger)bpr bitsPerPixel:(NSInteger)bpp {
    if ((self = [super init])) {
        _w = w; _h = h; _spp = spp; _bps = bps; _alpha = alpha;
        _bpr = bpr ?: (w * spp * bps + 7) / 8;
        _data = [NSMutableData dataWithLength:_bpr * h];
        if (planes && planes[0]) memcpy(_data.mutableBytes, planes[0], _bpr * h);
    }
    return self;
}
- (unsigned char *)bitmapData { return _data.mutableBytes; }
- (NSInteger)pixelsWide { return _w; }
- (NSInteger)pixelsHigh { return _h; }
- (NSInteger)bytesPerRow { return _bpr; }
- (NSInteger)bytesPerPlane { return _bpr * _h; }
- (NSInteger)samplesPerPixel { return _spp; }
- (NSInteger)bitsPerSample { return _bps; }
- (NSInteger)bitsPerPixel { return _spp * _bps; }
- (BOOL)hasAlpha { return _alpha; }
- (BOOL)isPlanar { return NO; }
- (NSSize)size { return CGSizeMake(_w, _h); }
- (void)setSize:(NSSize)s {}
- (CGImageRef)CGImage {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef p = CGDataProviderCreateWithCFData((__bridge CFDataRef)_data);
    CGImageRef img = CGImageCreate(_w, _h, _bps, _spp * _bps, _bpr, cs,
                                   (CGBitmapInfo)(_alpha ? kCGImageAlphaPremultipliedLast : kCGImageAlphaNoneSkipLast), p, NULL, NO, 0);
    CGDataProviderRelease(p);
    CGColorSpaceRelease(cs);
    return (CGImageRef)CFAutorelease(img);
}
- (NSData *)TIFFRepresentation { return nil; }
- (NSData *)representationUsingType:(NSUInteger)t properties:(NSDictionary *)p {
    UIImage *img = [UIImage imageWithCGImage:self.CGImage];
    return t == 3 ? UIImageJPEGRepresentation(img, 0.9) : UIImagePNGRepresentation(img); // 3 = NSBitmapImageFileTypeJPEG
}
@end

@interface RNSImage : NSObject
@end
@implementation RNSImage {
    NSMutableArray *_reps;
    NSSize _size;
}
RECOMP_FORWARDING
+ (id)imageNamed:(NSString *)n { return nil; }
- (instancetype)init { if ((self = [super init])) _reps = [NSMutableArray new]; return self; }
- (instancetype)initWithSize:(NSSize)s { if ((self = [self init])) _size = s; return self; }
- (instancetype)initWithData:(NSData *)d {
    RNSBitmapImageRep *rep = [RNSBitmapImageRep imageRepWithData:d];
    if (!rep) return nil;
    if ((self = [self initWithSize:[rep size]])) [_reps addObject:rep];
    return self;
}
- (instancetype)initWithContentsOfFile:(NSString *)path {
    NSData *d = [NSData dataWithContentsOfFile:path];
    return d ? [self initWithData:d] : nil;
}
- (instancetype)initWithContentsOfURL:(NSURL *)url { return [self initWithContentsOfFile:url.path]; }
- (instancetype)initWithCGImage:(CGImageRef)cg size:(NSSize)s {
    NSData *png = UIImagePNGRepresentation([UIImage imageWithCGImage:cg]);
    return [self initWithData:png];
}
- (void)addRepresentation:(id)rep { if (rep) [_reps addObject:rep]; if (CGSizeEqualToSize(_size, CGSizeZero)) _size = [rep size]; }
- (void)removeRepresentation:(id)rep { [_reps removeObject:rep]; }
- (NSArray *)representations { return [_reps copy]; }
- (NSSize)size { return _size; }
- (void)setSize:(NSSize)s { _size = s; }
- (BOOL)isValid { return _reps.count > 0; }
- (void)setTemplate:(BOOL)t {}
- (void)lockFocus {}
- (void)unlockFocus {}
- (NSData *)TIFFRepresentation { return nil; }
- (CGImageRef)CGImageForProposedRect:(NSRect *)r context:(id)c hints:(NSDictionary *)h {
    id rep = _reps.firstObject;
    return [rep respondsToSelector:@selector(CGImage)] ? [rep CGImage] : NULL;
}
- (void)drawInRect:(NSRect)r {}
- (void)drawInRect:(NSRect)r fromRect:(NSRect)f operation:(NSUInteger)o fraction:(CGFloat)a {}
- (void)drawAtPoint:(NSPoint)p fromRect:(NSRect)f operation:(NSUInteger)o fraction:(CGFloat)a {}
@end

// --- colours and fonts ---------------------------------------------------------------

@interface RNSColor : NSObject
@property (nonatomic) CGFloat r, g, b, a;
@end
@implementation RNSColor
RECOMP_FORWARDING
+ (id)recompR:(CGFloat)r g:(CGFloat)g b:(CGFloat)b a:(CGFloat)a {
    RNSColor *c = [self new];
    c.r = r; c.g = g; c.b = b; c.a = a;
    return c;
}
+ (id)colorWithDeviceRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a { return [self recompR:r g:g b:b a:a]; }
+ (id)colorWithSRGBRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a { return [self recompR:r g:g b:b a:a]; }
+ (id)colorWithCalibratedRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a { return [self recompR:r g:g b:b a:a]; }
+ (id)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a { return [self recompR:r g:g b:b a:a]; }
+ (id)colorWithDeviceWhite:(CGFloat)w alpha:(CGFloat)a { return [self recompR:w g:w b:w a:a]; }
+ (id)colorWithCalibratedWhite:(CGFloat)w alpha:(CGFloat)a { return [self recompR:w g:w b:w a:a]; }
+ (id)colorWithWhite:(CGFloat)w alpha:(CGFloat)a { return [self recompR:w g:w b:w a:a]; }
+ (id)clearColor { return [self recompR:0 g:0 b:0 a:0]; }
+ (id)blackColor { return [self recompR:0 g:0 b:0 a:1]; }
+ (id)whiteColor { return [self recompR:1 g:1 b:1 a:1]; }
+ (id)grayColor { return [self recompR:.5 g:.5 b:.5 a:1]; }
+ (id)darkGrayColor { return [self recompR:1. / 3 g:1. / 3 b:1. / 3 a:1]; }
+ (id)lightGrayColor { return [self recompR:2. / 3 g:2. / 3 b:2. / 3 a:1]; }
+ (id)redColor { return [self recompR:1 g:0 b:0 a:1]; }
+ (id)greenColor { return [self recompR:0 g:1 b:0 a:1]; }
+ (id)blueColor { return [self recompR:0 g:0 b:1 a:1]; }
+ (id)yellowColor { return [self recompR:1 g:1 b:0 a:1]; }
+ (id)textColor { return [self blackColor]; }
+ (id)textBackgroundColor { return [self whiteColor]; }
+ (id)windowBackgroundColor { return [self blackColor]; }
+ (id)controlTextColor { return [self blackColor]; }
+ (id)selectedTextBackgroundColor { return [self recompR:.7 g:.8 b:1 a:1]; }
- (CGColorRef)CGColor {
    return [UIColor colorWithRed:self.r green:self.g blue:self.b alpha:self.a].CGColor;
}
- (CGFloat)redComponent { return self.r; }
- (CGFloat)greenComponent { return self.g; }
- (CGFloat)blueComponent { return self.b; }
- (CGFloat)alphaComponent { return self.a; }
- (void)getRed:(CGFloat *)r green:(CGFloat *)g blue:(CGFloat *)b alpha:(CGFloat *)a {
    if (r) *r = self.r; if (g) *g = self.g; if (b) *b = self.b; if (a) *a = self.a;
}
- (id)colorUsingColorSpaceName:(NSString *)n { return self; }
- (id)colorUsingColorSpace:(id)s { return self; }
- (id)colorWithAlphaComponent:(CGFloat)a { return [RNSColor recompR:self.r g:self.g b:self.b a:a]; }
- (void)set {}
- (void)setFill {}
- (void)setStroke {}
@end

@interface RNSFont : NSObject
@property (strong) UIFont *ui;
@end
@implementation RNSFont
RECOMP_FORWARDING
+ (id)recompWith:(UIFont *)f { if (!f) return nil; RNSFont *r = [self new]; r.ui = f; return r; }
+ (id)fontWithName:(NSString *)n size:(CGFloat)s { return [self recompWith:[UIFont fontWithName:n size:s] ?: [UIFont systemFontOfSize:s]]; }
+ (id)systemFontOfSize:(CGFloat)s { return [self recompWith:[UIFont systemFontOfSize:s]]; }
+ (id)boldSystemFontOfSize:(CGFloat)s { return [self recompWith:[UIFont boldSystemFontOfSize:s]]; }
+ (id)userFontOfSize:(CGFloat)s { return [self systemFontOfSize:s ?: 12]; }
+ (id)userFixedPitchFontOfSize:(CGFloat)s { return [self recompWith:[UIFont monospacedSystemFontOfSize:s ?: 12 weight:UIFontWeightRegular]]; }
+ (id)monospacedSystemFontOfSize:(CGFloat)s weight:(CGFloat)w { return [self recompWith:[UIFont monospacedSystemFontOfSize:s weight:w]]; }
+ (id)labelFontOfSize:(CGFloat)s { return [self systemFontOfSize:s]; }
+ (CGFloat)systemFontSize { return 13; }
+ (CGFloat)smallSystemFontSize { return 11; }
- (CGFloat)pointSize { return self.ui.pointSize; }
- (NSString *)fontName { return self.ui.fontName; }
- (NSString *)familyName { return self.ui.familyName; }
- (NSString *)displayName { return self.ui.fontName; }
- (CGFloat)ascender { return self.ui.ascender; }
- (CGFloat)descender { return self.ui.descender; }
- (CGFloat)leading { return self.ui.leading; }
- (CGFloat)capHeight { return self.ui.capHeight; }
- (CGFloat)xHeight { return self.ui.xHeight; }
@end

// --- menus ---------------------------------------------------------------------------

@interface RNSMenuItem : NSObject
@property (copy) NSString *title, *keyEquivalent;
@property SEL action;
@property (assign) id target;
@property (strong) id submenu, representedObject, image;
@property (assign) id menu;
@property NSInteger tag, state;
@property NSUInteger keyEquivalentModifierMask;
@property (getter=isEnabled) BOOL enabled;
@property (getter=isHidden) BOOL hidden;
@property BOOL recompSeparator;
@end
@implementation RNSMenuItem
RECOMP_FORWARDING
+ (id)separatorItem { RNSMenuItem *i = [self new]; i.recompSeparator = YES; return i; }
- (instancetype)init { return [self initWithTitle:@"" action:NULL keyEquivalent:@""]; }
- (instancetype)initWithTitle:(NSString *)t action:(SEL)a keyEquivalent:(NSString *)k {
    if ((self = [super init])) { _title = [t copy]; _action = a; _keyEquivalent = [k copy]; _enabled = YES; }
    return self;
}
- (BOOL)isSeparatorItem { return _recompSeparator; }
- (BOOL)hasSubmenu { return _submenu != nil; }
- (BOOL)isHighlighted { return NO; }
- (void)setToolTip:(NSString *)t {}
- (void)setAttributedTitle:(id)t {}
- (void)setAlternate:(BOOL)b {}
- (void)setIndentationLevel:(NSInteger)l {}
- (void)setView:(id)v {}
- (id)view { return nil; }
- (BOOL)isHighlightingKeyEquivalent { return NO; }
@end

@interface RNSMenu : NSObject
@property (copy) NSString *title;
@property (assign) id delegate;
@property (assign) id supermenu;
@property BOOL autoenablesItems;
@end
@implementation RNSMenu {
    NSMutableArray *_items;
}
RECOMP_FORWARDING
+ (void)setMenuBarVisible:(BOOL)v {}
+ (BOOL)menuBarVisible { return NO; }
- (instancetype)init { return [self initWithTitle:@""]; }
- (instancetype)initWithTitle:(NSString *)t {
    if ((self = [super init])) { _title = [t copy]; _items = [NSMutableArray new]; _autoenablesItems = YES; }
    return self;
}
- (void)addItem:(RNSMenuItem *)i { [self insertItem:i atIndex:_items.count]; }
- (id)addItemWithTitle:(NSString *)t action:(SEL)a keyEquivalent:(NSString *)k {
    RNSMenuItem *i = [[RNSMenuItem alloc] initWithTitle:t action:a keyEquivalent:k];
    [self addItem:i];
    return i;
}
- (void)insertItem:(RNSMenuItem *)i atIndex:(NSInteger)idx {
    if (!i) return;
    i.menu = self;
    if ([i.submenu isKindOfClass:[RNSMenu class]]) [(RNSMenu *)i.submenu setSupermenu:self];
    [_items insertObject:i atIndex:MIN((NSUInteger)idx, _items.count)];
}
- (id)insertItemWithTitle:(NSString *)t action:(SEL)a keyEquivalent:(NSString *)k atIndex:(NSInteger)idx {
    RNSMenuItem *i = [[RNSMenuItem alloc] initWithTitle:t action:a keyEquivalent:k];
    [self insertItem:i atIndex:idx];
    return i;
}
- (void)removeItem:(id)i { [_items removeObject:i]; }
- (void)removeItemAtIndex:(NSInteger)idx { if ((NSUInteger)idx < _items.count) [_items removeObjectAtIndex:idx]; }
- (void)removeAllItems { [_items removeAllObjects]; }
- (NSArray *)itemArray { return [_items copy]; }
- (void)setItemArray:(NSArray *)a { _items = [a mutableCopy]; }
- (NSInteger)numberOfItems { return _items.count; }
- (id)itemAtIndex:(NSInteger)idx { return (NSUInteger)idx < _items.count ? _items[idx] : nil; }
- (NSInteger)indexOfItem:(id)i { NSUInteger n = [_items indexOfObject:i]; return n == NSNotFound ? -1 : (NSInteger)n; }
- (id)itemWithTag:(NSInteger)t { for (RNSMenuItem *i in _items) if (i.tag == t) return i; return nil; }
- (id)itemWithTitle:(NSString *)t { for (RNSMenuItem *i in _items) if ([i.title isEqualToString:t]) return i; return nil; }
- (void)setSubmenu:(id)m forItem:(RNSMenuItem *)i { i.submenu = m; }
- (void)update {}
- (id)highlightedItem { return nil; }
- (void)cancelTracking {}
- (BOOL)performKeyEquivalent:(id)e { return NO; }
- (void)setShowsStateColumn:(BOOL)b {}
- (void)setMinimumWidth:(CGFloat)w {}
@end

// --- pasteboard ---------------------------------------------------------------------

@interface RNSPasteboardItem : NSObject
@end
@implementation RNSPasteboardItem {
    NSMutableDictionary *_strings;
}
RECOMP_FORWARDING
- (instancetype)init { if ((self = [super init])) _strings = [NSMutableDictionary new]; return self; }
- (BOOL)setString:(NSString *)s forType:(NSString *)t { if (s && t) _strings[t] = s; return YES; }
- (BOOL)setData:(NSData *)d forType:(NSString *)t { return NO; }
- (NSString *)stringForType:(NSString *)t { return _strings[t]; }
- (NSArray *)types { return _strings.allKeys; }
@end

@interface RNSPasteboard : NSObject
@end
@implementation RNSPasteboard
RECOMP_FORWARDING
+ (id)generalPasteboard { static RNSPasteboard *p; static dispatch_once_t o; dispatch_once(&o, ^{ p = [RNSPasteboard new]; }); return p; }
+ (id)pasteboardWithName:(NSString *)n { return [self generalPasteboard]; }
- (NSInteger)clearContents { UIPasteboard.generalPasteboard.items = @[]; return UIPasteboard.generalPasteboard.changeCount; }
- (NSInteger)changeCount { return UIPasteboard.generalPasteboard.changeCount; }
- (NSInteger)declareTypes:(NSArray *)t owner:(id)o { return self.changeCount; }
- (NSArray *)types { return UIPasteboard.generalPasteboard.hasStrings ? @[@"public.utf8-plain-text"] : @[]; }
- (BOOL)setString:(NSString *)s forType:(NSString *)t { UIPasteboard.generalPasteboard.string = s; return YES; }
- (NSString *)stringForType:(NSString *)t { return UIPasteboard.generalPasteboard.string; }
- (NSData *)dataForType:(NSString *)t { return [UIPasteboard.generalPasteboard.string dataUsingEncoding:NSUTF8StringEncoding]; }
- (BOOL)writeObjects:(NSArray *)objs {
    for (id o in objs) {
        NSString *s = [o isKindOfClass:[NSString class]] ? o : [o respondsToSelector:@selector(stringForType:)] ? [o stringForType:@"public.utf8-plain-text"] : nil;
        if (s) { UIPasteboard.generalPasteboard.string = s; return YES; }
    }
    return NO;
}
- (NSArray *)readObjectsForClasses:(NSArray *)classes options:(NSDictionary *)o {
    NSString *s = UIPasteboard.generalPasteboard.string;
    return s ? @[s] : @[];
}
- (BOOL)canReadObjectForClasses:(NSArray *)c options:(NSDictionary *)o { return UIPasteboard.generalPasteboard.hasStrings; }
- (NSString *)availableTypeFromArray:(NSArray *)t { return UIPasteboard.generalPasteboard.hasStrings ? t.firstObject : nil; }
@end

// --- alerts -----------------------------------------------------------------------

@interface RNSAlert : NSObject
@property (copy) NSString *messageText, *informativeText;
@property NSUInteger alertStyle;
@end
@implementation RNSAlert {
    NSMutableArray *_buttons;
}
RECOMP_FORWARDING
- (instancetype)init { if ((self = [super init])) _buttons = [NSMutableArray new]; return self; }
- (id)addButtonWithTitle:(NSString *)t { [_buttons addObject:t ?: @"OK"]; return nil; }
- (NSArray *)buttons { return @[]; }
- (void)setShowsHelp:(BOOL)b {}
- (void)setIcon:(id)i {}
- (id)window { return nil; }
- (void)setAccessoryView:(id)v {}
- (void)layout {}
// Shows a UIAlertController and waits for an answer, like AppKit's modal loop.
- (NSInteger)runModal {
    RLOG(@"alert: %@ / %@", self.messageText, self.informativeText);
    __block NSInteger answer = 0;
    NSArray *buttons = _buttons.count ? _buttons : @[@"OK"];
    dispatch_block_t show = ^{
        UIViewController *vc = RecompRoot().window.rootViewController;
        if (!vc) { answer = 1000; return; }
        UIAlertController *a = [UIAlertController alertControllerWithTitle:self.messageText message:self.informativeText
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [buttons enumerateObjectsUsingBlock:^(NSString *t, NSUInteger i, BOOL *stop) {
            [a addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { answer = 1000 + i; }]];
        }];
        while (vc.presentedViewController) vc = vc.presentedViewController;
        [vc presentViewController:a animated:YES completion:nil];
    };
    if (NSThread.isMainThread) {
        show();
        while (!answer) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    } else {
        dispatch_async(dispatch_get_main_queue(), show);
        while (!answer) usleep(50000);
    }
    return answer;
}
@end

// --- workspace ----------------------------------------------------------------------

@interface RNSWorkspace : NSObject
@end
@implementation RNSWorkspace {
    NSNotificationCenter *_center;
}
RECOMP_FORWARDING
+ (id)sharedWorkspace { static RNSWorkspace *w; static dispatch_once_t o; dispatch_once(&o, ^{ w = [RNSWorkspace new]; }); return w; }
- (NSNotificationCenter *)notificationCenter { if (!_center) _center = [NSNotificationCenter new]; return _center; }
- (BOOL)openURL:(NSURL *)url {
    RecompOnMain(^{ [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil]; });
    return YES;
}
- (BOOL)openFile:(NSString *)f { return NO; }
- (BOOL)selectFile:(NSString *)f inFileViewerRootedAtPath:(NSString *)r { return NO; }
- (BOOL)isFilePackageAtPath:(NSString *)p { return [p.pathExtension isEqualToString:@"app"]; }
- (NSString *)fullPathForApplication:(NSString *)a { return nil; }
- (NSURL *)URLForApplicationWithBundleIdentifier:(NSString *)b { return nil; }
- (id)frontmostApplication { return nil; }
- (id)menuBarOwningApplication { return nil; }
- (NSArray *)runningApplications { return @[]; }
- (id)iconForFile:(NSString *)f { return nil; }
- (BOOL)accessibilityDisplayShouldReduceMotion { return UIAccessibilityIsReduceMotionEnabled(); }
- (BOOL)accessibilityDisplayShouldIncreaseContrast { return UIAccessibilityDarkerSystemColorsEnabled(); }
- (BOOL)isVoiceOverEnabled { return UIAccessibilityIsVoiceOverRunning(); }
- (BOOL)isSwitchControlEnabled { return NO; }
@end

// --- text and scroll views -----------------------------------------------------------

@interface RNSScrollView : RNSView
@property (strong) id documentView;
@end
@implementation RNSScrollView
- (void)setHasVerticalScroller:(BOOL)b {}
- (void)setHasHorizontalScroller:(BOOL)b {}
- (void)setAutohidesScrollers:(BOOL)b {}
- (void)setBorderType:(NSUInteger)t {}
- (NSSize)contentSize { return self.bounds.size; }
- (id)contentView { return nil; }
@end

@interface RNSTextView : RNSView
@property (copy) NSString *string;
@end
@implementation RNSTextView
- (void)setEditable:(BOOL)b {}
- (void)setSelectable:(BOOL)b {}
- (void)setRichText:(BOOL)b {}
- (void)setDrawsBackground:(BOOL)b {}
- (void)setFont:(id)f {}
- (void)setTextColor:(id)c {}
- (void)setBackgroundColor:(id)c {}
- (void)setHorizontallyResizable:(BOOL)b {}
- (void)setVerticallyResizable:(BOOL)b {}
- (void)setMinSize:(NSSize)s {}
- (void)setMaxSize:(NSSize)s {}
- (id)textContainer { return nil; }
- (id)textStorage { return nil; }
- (void)insertText:(id)t { self.string = [(self.string ?: @"") stringByAppendingString:[t description]]; }
@end

// --- accessibility -------------------------------------------------------------------

@interface RNSAccessibilityElement : NSObject
@end
@implementation RNSAccessibilityElement {
    id _parent, _role, _subrole, _label, _window;
    NSRect _frame;
    BOOL _focused;
}
RECOMP_FORWARDING
+ (id)accessibilityElementWithRole:(NSString *)r frame:(NSRect)f label:(NSString *)l parent:(id)p {
    RNSAccessibilityElement *e = [self new];
    e->_role = r; e->_frame = f; e->_label = l; e->_parent = p;
    return e;
}
- (void)setAccessibilityParent:(id)p { _parent = p; }
- (id)accessibilityParent { return _parent; }
- (void)setAccessibilityRole:(id)r { _role = r; }
- (id)accessibilityRole { return _role; }
- (void)setAccessibilitySubrole:(id)r { _subrole = r; }
- (id)accessibilitySubrole { return _subrole; }
- (void)setAccessibilityLabel:(id)l { _label = l; }
- (id)accessibilityLabel { return _label; }
- (void)setAccessibilityFrame:(CGRect)f { _frame = f; }
- (CGRect)accessibilityFrame { return _frame; }
- (void)setAccessibilityFrameInParentSpace:(NSRect)f { _frame = f; }
- (void)setAccessibilityWindow:(id)w { _window = w; }
- (id)accessibilityWindow { return _window; }
- (void)setAccessibilityFocused:(BOOL)f { _focused = f; }
- (BOOL)isAccessibilityFocused { return _focused; }
- (void)setAccessibilityEnabled:(BOOL)e {}
- (void)setAccessibilityHelp:(id)h {}
- (void)setAccessibilityValue:(id)v {}
- (void)setAccessibilityChildren:(NSArray *)c {}
- (void)setAccessibilityTopLevelUIElement:(id)e {}
- (void)setAccessibilityApplicationFocusedUIElement:(id)e {}
- (BOOL)isAccessibilitySelectorAllowed:(SEL)s { return YES; }
@end

// --- Foundation: Apple events (macOS only) -------------------------------------------

@interface RNSAppleEventManager : NSObject
@end
@implementation RNSAppleEventManager
RECOMP_FORWARDING
+ (id)sharedAppleEventManager { static RNSAppleEventManager *m; static dispatch_once_t o; dispatch_once(&o, ^{ m = [RNSAppleEventManager new]; }); return m; }
- (void)setEventHandler:(id)h andSelector:(SEL)s forEventClass:(uint32_t)c andEventID:(uint32_t)e {}
- (void)removeEventHandlerForEventClass:(uint32_t)c andEventID:(uint32_t)e {}
- (id)currentAppleEvent { return nil; }
@end
