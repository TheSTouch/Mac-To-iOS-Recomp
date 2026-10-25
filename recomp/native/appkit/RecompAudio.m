// Audio for a Mac game built on CoreAudio's HAL and macOS audio units.
//
// iOS has no audio devices to query (AudioObject* fails), no default-output
// unit and no desktop 3D mixer. The game's calls are bound here (see INTERCEPT
// in unreal_ios.py): device queries describe one output device at the audio
// session's sample rate, and component descriptions are mapped to the iOS
// units that do the same job before the real AudioToolbox sees them. Audio
// unit calls that still fail are logged once each.
#import "RecompAppKit.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

void *RecompRealSym(const char *name, void *mine);
#define REAL(name) static __typeof__(&name) real; if (!real) real = (__typeof__(&name))RecompRealSym(#name, (void *)name)

// AudioHardware.h is macOS-only; the parts used here.
typedef UInt32 AudioObjectID;
typedef struct { UInt32 mSelector, mScope, mElement; } AudioObjectPropertyAddress;
typedef OSStatus (*AudioObjectPropertyListenerProc)(AudioObjectID, UInt32, const AudioObjectPropertyAddress *, void *);
enum {
    kAudioObjectUnknown = 0, kAudioObjectSystemObject = 1,
    kAudioHardwarePropertyDefaultOutputDevice = 'dOut', kAudioHardwarePropertyDefaultSystemOutputDevice = 'sOut',
    kAudioHardwarePropertyDefaultInputDevice = 'dIn ', kAudioHardwarePropertyDevices = 'dev#',
    kAudioDevicePropertyNominalSampleRate = 'nsrt', kAudioDevicePropertyBufferFrameSize = 'fsiz',
    kAudioDevicePropertyLatency = 'ltnc', kAudioDevicePropertySafetyOffset = 'saft',
    kAudioDevicePropertyDeviceIsAlive = 'livn', kAudioDevicePropertyDeviceIsRunning = 'goin',
    kAudioDevicePropertyStreamFormat = 'sfmt', kAudioStreamPropertyPhysicalFormat = 'pft ',
    kAudioObjectPropertyName = 'lnam', kAudioDevicePropertyDeviceUID = 'uid ', kAudioDevicePropertyModelUID = 'muid',
    kAudioDevicePropertyStreamConfiguration = 'slay', kAudioDevicePropertyPreferredChannelsForStereo = 'dch2',
};

static const AudioObjectID kDevice = 2;
static const OSStatus kUnknownProperty = 'who?';

static Float64 SampleRate(void) {
    Float64 r = AVAudioSession.sharedInstance.sampleRate;
    return r > 0 ? r : 48000;
}

static AudioStreamBasicDescription StreamFormat(void) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = SampleRate();
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    f.mChannelsPerFrame = 2;
    f.mBitsPerChannel = 32;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = f.mBytesPerPacket = 8;
    return f;
}

// Writes the property into out (when given) and returns its size, or 0 if unknown.
static UInt32 DeviceProperty(AudioObjectID obj, const AudioObjectPropertyAddress *a, void *out, UInt32 cap) {
    UInt32 sel = a->mSelector;
#define PUT(type, value) do { type v_ = (value); if (out) { if (cap < sizeof v_) return 0; memcpy(out, &v_, sizeof v_); } return sizeof v_; } while (0)
    if (obj == kAudioObjectSystemObject) {
        switch (sel) {
            case kAudioHardwarePropertyDefaultOutputDevice:
            case kAudioHardwarePropertyDefaultSystemOutputDevice: PUT(AudioObjectID, kDevice);
            case kAudioHardwarePropertyDefaultInputDevice: PUT(AudioObjectID, kAudioObjectUnknown);
            case kAudioHardwarePropertyDevices: PUT(AudioObjectID, kDevice);
        }
        return 0;
    }
    if (obj != kDevice) return 0;
    switch (sel) {
        case kAudioDevicePropertyNominalSampleRate: PUT(Float64, SampleRate());
        case kAudioDevicePropertyBufferFrameSize: PUT(UInt32, 512);
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset: PUT(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning: PUT(UInt32, 1);
        case kAudioDevicePropertyStreamFormat: // also kAudioStreamPropertyVirtualFormat
        case kAudioStreamPropertyPhysicalFormat: PUT(AudioStreamBasicDescription, StreamFormat());
        case kAudioObjectPropertyName:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID: PUT(CFStringRef, (CFStringRef)CFRetain(CFSTR("iPad Speakers")));
        case kAudioDevicePropertyStreamConfiguration: {
            AudioBufferList l = {1, {{2, 0, NULL}}};
            PUT(AudioBufferList, l);
        }
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            UInt32 ch[2] = {1, 2};
            if (out) { if (cap < sizeof ch) return 0; memcpy(out, ch, sizeof ch); }
            return sizeof ch;
        }
    }
    return 0;
#undef PUT
}

OSStatus AudioObjectGetPropertyData(AudioObjectID obj, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q,
                                    UInt32 *ioSize, void *out) {
    UInt32 n = DeviceProperty(obj, a, out, ioSize ? *ioSize : 0);
    if (!n) return kUnknownProperty;
    if (ioSize) *ioSize = n;
    return noErr;
}

OSStatus AudioObjectGetPropertyDataSize(AudioObjectID obj, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q,
                                        UInt32 *outSize) {
    UInt32 n = DeviceProperty(obj, a, NULL, 0);
    if (!n) return kUnknownProperty;
    if (outSize) *outSize = n;
    return noErr;
}

Boolean AudioObjectHasProperty(AudioObjectID obj, const AudioObjectPropertyAddress *a) {
    return DeviceProperty(obj, a, NULL, 0) != 0;
}

OSStatus AudioObjectSetPropertyData(AudioObjectID obj, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q,
                                    UInt32 size, const void *data) {
    return noErr;
}

OSStatus AudioObjectAddPropertyListener(AudioObjectID obj, const AudioObjectPropertyAddress *a,
                                        AudioObjectPropertyListenerProc proc, void *client) {
    return noErr;
}

OSStatus AudioObjectRemovePropertyListener(AudioObjectID obj, const AudioObjectPropertyAddress *a,
                                           AudioObjectPropertyListenerProc proc, void *client) {
    return noErr;
}

// --- audio units ---------------------------------------------------------------------

static NSString *FourCC(OSType t) {
    char c[5] = {(char)(t >> 24), (char)(t >> 16), (char)(t >> 8), (char)t, 0};
    return [NSString stringWithUTF8String:c] ?: [NSString stringWithFormat:@"%u", (unsigned)t];
}

// macOS unit -> the iOS unit doing the same job.
static AudioComponentDescription Remap(const AudioComponentDescription *in) {
    AudioComponentDescription d = *in;
    if (d.componentType == kAudioUnitType_Output &&
        (d.componentSubType == 'def ' || d.componentSubType == 'ahal' || d.componentSubType == 'sys '))
        d.componentSubType = kAudioUnitSubType_RemoteIO;
    else if (d.componentType == kAudioUnitType_Mixer && d.componentSubType == '3dmx')
        d.componentSubType = kAudioUnitSubType_SpatialMixer; // the embedded 3D mixer ("3dem")
    else if (d.componentType == kAudioUnitType_Effect && d.componentSubType == 'mrev')
        d.componentSubType = kAudioUnitSubType_Reverb2;
    if (d.componentSubType != in->componentSubType)
        RLOG(@"audio unit %@/%@ -> %@", FourCC(in->componentType), FourCC(in->componentSubType), FourCC(d.componentSubType));
    return d;
}

static void SessionOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSError *e = nil;
        AVAudioSession *s = AVAudioSession.sharedInstance;
        [s setCategory:AVAudioSessionCategoryAmbient error:&e];
        [s setActive:YES error:&e];
        if (e) RLOG(@"audio session: %@", e);
    });
}

AudioComponent AudioComponentFindNext(AudioComponent c, const AudioComponentDescription *desc) {
    REAL(AudioComponentFindNext);
    SessionOnce();
    AudioComponentDescription d = Remap(desc);
    AudioComponent r = real(c, &d);
    if (!r && !c) RLOG(@"no audio unit %@/%@", FourCC(d.componentType), FourCC(d.componentSubType));
    return r;
}

OSStatus AUGraphAddNode(AUGraph g, const AudioComponentDescription *desc, AUNode *node) {
    REAL(AUGraphAddNode);
    SessionOnce();
    AudioComponentDescription d = Remap(desc);
    OSStatus s = real(g, &d, node);
    if (s) RLOG(@"AUGraphAddNode %@/%@ failed: %d", FourCC(d.componentType), FourCC(d.componentSubType), (int)s);
    return s;
}

static void LogOnce(NSString *what, UInt32 prop, UInt32 scope, OSStatus s) {
    static NSMutableSet *seen;
    @synchronized ([NSProcessInfo class]) {
        if (!seen) seen = [NSMutableSet new];
        NSString *k = [NSString stringWithFormat:@"%@ %u/%u %d", what, prop, scope, (int)s];
        if ([seen containsObject:k]) return;
        [seen addObject:k];
        RLOG(@"%@ failed: property %u scope %u -> %d", what, prop, scope, (int)s);
    }
}

OSStatus AudioUnitSetProperty(AudioUnit u, AudioUnitPropertyID p, AudioUnitScope sc, AudioUnitElement el,
                              const void *data, UInt32 size) {
    REAL(AudioUnitSetProperty);
    if (p == 2000) return noErr; // kAudioOutputUnitProperty_CurrentDevice: there is only one
    OSStatus s = real(u, p, sc, el, data, size);
    if (s) LogOnce(@"AudioUnitSetProperty", p, sc, s);
    return s;
}

OSStatus AUGraphInitialize(AUGraph g) {
    REAL(AUGraphInitialize);
    OSStatus s = real(g);
    if (s) RLOG(@"AUGraphInitialize failed: %d", (int)s);
    return s;
}

OSStatus AUGraphStart(AUGraph g) {
    REAL(AUGraphStart);
    OSStatus s = real(g);
    RLOG(@"AUGraphStart: %d", (int)s);
    return s;
}
