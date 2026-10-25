// Keyboard layout: HID usage -> Mac virtual key code, and the Carbon calls
// (TIS*, UCKeyTranslate, LMGetKbdType) games use to name keys. The layout is
// US ANSI; iOS gives games no access to the user's keyboard layout data.
#import "RecompAppKit.h"

uint16_t RecompMacKeyCode(long hid) {
    static const uint16_t letters[26] = {0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E,
                                         0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06};
    static const uint16_t digits[10] = {0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D}; // 1..9, 0
    static const uint16_t fkeys[12] = {0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F};
    static const uint16_t keypad[10] = {0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C, 0x52}; // 1..9, 0
    if (hid >= 0x04 && hid <= 0x1D) return letters[hid - 0x04];
    if (hid >= 0x1E && hid <= 0x27) return digits[hid - 0x1E];
    if (hid >= 0x3A && hid <= 0x45) return fkeys[hid - 0x3A];
    if (hid >= 0x59 && hid <= 0x62) return keypad[hid - 0x59];
    switch (hid) {
        case 0x28: return 0x24; // return
        case 0x29: return 0x35; // escape
        case 0x2A: return 0x33; // backspace (Mac "delete")
        case 0x2B: return 0x30; // tab
        case 0x2C: return 0x31; // space
        case 0x2D: return 0x1B; // -
        case 0x2E: return 0x18; // =
        case 0x2F: return 0x21; // [
        case 0x30: return 0x1E; // ]
        case 0x31: return 0x2A; // backslash
        case 0x32: return 0x2A; // non-US #
        case 0x33: return 0x29; // ;
        case 0x34: return 0x27; // '
        case 0x35: return 0x32; // `
        case 0x36: return 0x2B; // ,
        case 0x37: return 0x2F; // .
        case 0x38: return 0x2C; // /
        case 0x39: return 0x39; // caps lock
        case 0x49: return 0x72; // insert -> help
        case 0x4A: return 0x73; // home
        case 0x4B: return 0x74; // page up
        case 0x4C: return 0x75; // forward delete
        case 0x4D: return 0x77; // end
        case 0x4E: return 0x79; // page down
        case 0x4F: return 0x7C; // right
        case 0x50: return 0x7B; // left
        case 0x51: return 0x7D; // down
        case 0x52: return 0x7E; // up
        case 0x53: return 0x47; // num lock -> keypad clear
        case 0x54: return 0x4B; // keypad /
        case 0x55: return 0x43; // keypad *
        case 0x56: return 0x4E; // keypad -
        case 0x57: return 0x45; // keypad +
        case 0x58: return 0x4C; // keypad enter
        case 0x63: return 0x41; // keypad .
        case 0x64: return 0x0A; // non-US backslash (ISO section)
        case 0x67: return 0x51; // keypad =
        case 0x68: return 0x69; // F13
        case 0x69: return 0x6B; // F14
        case 0x6A: return 0x71; // F15
        case 0x6B: return 0x6A; // F16
        case 0x6C: return 0x40; // F17
        case 0x6D: return 0x4F; // F18
        case 0x6E: return 0x50; // F19
        case 0x6F: return 0x5A; // F20
        case 0xE0: return 0x3B; // left control
        case 0xE1: return 0x38; // left shift
        case 0xE2: return 0x3A; // left option
        case 0xE3: return 0x37; // left command
        case 0xE4: return 0x3E; // right control
        case 0xE5: return 0x3C; // right shift
        case 0xE6: return 0x3D; // right option
        case 0xE7: return 0x36; // right command
    }
    return 0xFFFF;
}

// Printable characters (unshifted, shifted) per Mac key code, US ANSI.
static const char *kPrintable[128][2] = {
    [0x00] = {"a", "A"}, [0x01] = {"s", "S"}, [0x02] = {"d", "D"}, [0x03] = {"f", "F"}, [0x04] = {"h", "H"},
    [0x05] = {"g", "G"}, [0x06] = {"z", "Z"}, [0x07] = {"x", "X"}, [0x08] = {"c", "C"}, [0x09] = {"v", "V"},
    [0x0A] = {"\xC2\xA7", "\xC2\xB1"}, [0x0B] = {"b", "B"}, [0x0C] = {"q", "Q"}, [0x0D] = {"w", "W"},
    [0x0E] = {"e", "E"}, [0x0F] = {"r", "R"}, [0x10] = {"y", "Y"}, [0x11] = {"t", "T"}, [0x12] = {"1", "!"},
    [0x13] = {"2", "@"}, [0x14] = {"3", "#"}, [0x15] = {"4", "$"}, [0x16] = {"6", "^"}, [0x17] = {"5", "%"},
    [0x18] = {"=", "+"}, [0x19] = {"9", "("}, [0x1A] = {"7", "&"}, [0x1B] = {"-", "_"}, [0x1C] = {"8", "*"},
    [0x1D] = {"0", ")"}, [0x1E] = {"]", "}"}, [0x1F] = {"o", "O"}, [0x20] = {"u", "U"}, [0x21] = {"[", "{"},
    [0x22] = {"i", "I"}, [0x23] = {"p", "P"}, [0x25] = {"l", "L"}, [0x26] = {"j", "J"}, [0x27] = {"'", "\""},
    [0x28] = {"k", "K"}, [0x29] = {";", ":"}, [0x2A] = {"\\", "|"}, [0x2B] = {",", "<"}, [0x2C] = {"/", "?"},
    [0x2D] = {"n", "N"}, [0x2E] = {"m", "M"}, [0x2F] = {".", ">"}, [0x31] = {" ", " "}, [0x32] = {"`", "~"},
    [0x41] = {".", "."}, [0x43] = {"*", "*"}, [0x45] = {"+", "+"}, [0x4B] = {"/", "/"}, [0x4E] = {"-", "-"},
    [0x51] = {"=", "="}, [0x52] = {"0", "0"}, [0x53] = {"1", "1"}, [0x54] = {"2", "2"}, [0x55] = {"3", "3"},
    [0x56] = {"4", "4"}, [0x57] = {"5", "5"}, [0x58] = {"6", "6"}, [0x59] = {"7", "7"}, [0x5B] = {"8", "8"},
    [0x5C] = {"9", "9"},
};

// Characters AppKit reports for non-printing keys (NSF*FunctionKey and controls).
static unichar SpecialChar(uint16_t k) {
    switch (k) {
        case 0x24: return '\r'; case 0x4C: return 0x03; case 0x30: return '\t'; case 0x33: return 0x7F;
        case 0x35: return 0x1B; case 0x7E: return 0xF700; case 0x7D: return 0xF701; case 0x7B: return 0xF702;
        case 0x7C: return 0xF703; case 0x7A: return 0xF704; case 0x78: return 0xF705; case 0x63: return 0xF706;
        case 0x76: return 0xF707; case 0x60: return 0xF708; case 0x61: return 0xF709; case 0x62: return 0xF70A;
        case 0x64: return 0xF70B; case 0x65: return 0xF70C; case 0x6D: return 0xF70D; case 0x67: return 0xF70E;
        case 0x6F: return 0xF70F; case 0x69: return 0xF710; case 0x6B: return 0xF711; case 0x71: return 0xF712;
        case 0x6A: return 0xF713; case 0x40: return 0xF714; case 0x4F: return 0xF715; case 0x50: return 0xF716;
        case 0x5A: return 0xF717; case 0x72: return 0xF746; case 0x73: return 0xF729; case 0x74: return 0xF72C;
        case 0x75: return 0xF728; case 0x77: return 0xF72B; case 0x79: return 0xF72D; case 0x47: return 0xF739;
    }
    return 0;
}

NSString *RecompKeyCharacters(uint16_t k, BOOL shift) {
    unichar c = SpecialChar(k);
    return c ? [NSString stringWithCharacters:&c length:1] : nil;
}

// --- Carbon ----------------------------------------------------------------------

const CFStringRef kTISPropertyUnicodeKeyLayoutData = CFSTR("TISPropertyUnicodeKeyLayoutData");

CFTypeRef TISCopyCurrentKeyboardLayoutInputSource(void) {
    return CFRetain(CFSTR("com.apple.keylayout.US"));
}

void *TISGetInputSourceProperty(CFTypeRef source, CFStringRef key) {
    static CFDataRef data;
    static dispatch_once_t once;
    // The bytes are never parsed: UCKeyTranslate below ignores the layout pointer.
    dispatch_once(&once, ^{ data = CFDataCreate(NULL, (const UInt8 *)"uchr", 4); });
    return CFEqual(key, kTISPropertyUnicodeKeyLayoutData) ? (void *)data : NULL;
}

uint8_t LMGetKbdType(void) { return 40; } // ANSI

int32_t UCKeyTranslate(const void *layout, uint16_t key, uint16_t action, uint32_t modifiers, uint32_t kbdType,
                       uint32_t options, uint32_t *deadKeyState, unsigned long maxLen, unsigned long *actualLen,
                       unichar *out) {
    if (deadKeyState) *deadKeyState = 0;
    if (actualLen) *actualLen = 0;
    if (key >= 128 || maxLen == 0) return 0;
    BOOL shift = (modifiers & 0x02) != 0; // (shiftKey >> 8)
    const char *s = kPrintable[key][shift ? 1 : 0];
    if (s) {
        NSString *str = [NSString stringWithUTF8String:s];
        NSUInteger n = MIN(str.length, maxLen);
        [str getCharacters:out range:NSMakeRange(0, n)];
        if (actualLen) *actualLen = n;
        return 0;
    }
    unichar c = SpecialChar(key);
    if (c == 0x7F) c = 0x08; // UCKeyTranslate reports backspace for the delete key
    if (c && c < 0xF700) {
        out[0] = c;
        if (actualLen) *actualLen = 1;
    }
    return 0;
}
