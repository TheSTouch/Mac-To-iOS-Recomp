// SoundEngineExtension (Wwise 2017.2 wrapper) for AIR ports, iOS stand-in: silent.
//
// Every call succeeds and plays nothing, so the game runs without sound until the extension is
// rebuilt on Wwise's iOS SDK. Results are AKRESULT (1 = AK_Success); PostEvent returns a
// playing ID, which must not be 0 (AK_INVALID_PLAYING_ID). Init and StopPlaying return nothing,
// as in the Mac library.

#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include "FlashRuntimeExtensions.h"

static FREObject newUint(uint32_t v) {
    FREObject r = NULL;
    FRENewObjectFromUint32(v, &r);
    return r;
}

// The first argument when it is a string (bank and event names), for the console log.
static const char *argDesc(uint32_t argc, FREObject argv[]) {
    static char buf[160];
    const uint8_t *s = NULL;
    uint32_t n = 0;
    buf[0] = 0;
    if (argc > 0 && FREGetObjectAsUTF8(argv[0], &n, &s) == FRE_OK && s)
        snprintf(buf, sizeof buf, " %.*s", (int)(n < 150 ? n : 150), (const char *)s);
    return buf;
}

#define FN(name) static FREObject name##_(FREContext, uint32_t, FREObject[]); \
    static FREObject name(FREContext ctx, void *data, uint32_t argc, FREObject argv[]) { \
        fprintf(stderr, "[air] %s%s\n", #name, argDesc(argc, argv)); \
        return name##_(ctx, argc, argv); \
    } \
    static FREObject name##_(FREContext ctx, uint32_t argc, FREObject argv[])
// Called every frame: not logged.
#define QFN(name) static FREObject name(FREContext ctx, void *data, uint32_t argc, FREObject argv[])

FN(Init) { return NULL; }
FN(SetBasePath) { return newUint(1); }
FN(LoadBank) { return newUint(1); }
FN(UnloadBank) { return newUint(1); }
FN(RegisterGameObj) { return newUint(1); }
FN(UnregisterGameObj) { return newUint(1); }
FN(SetDefaultListeners) { return newUint(1); }
FN(SetDefaultListener) { return newUint(1); }
FN(StopPlaying) { return NULL; }
FN(PostEvent) {
    static uint32_t playing;
    return newUint(++playing ? playing : ++playing);
}
QFN(SetRtpcValue) { return newUint(1); }
QFN(SetRtpcValueByPlayingID) { return newUint(1); }
QFN(SetPosition) { return newUint(1); }
QFN(SetListenerPosition) { return newUint(1); }
QFN(TickSoundEngineExtension) { return newUint(1); }

#define ENTRY(name) {(const uint8_t *)#name, NULL, name}

static void SoundEngineExtCtxInitializer(void *extData, const uint8_t *ctxType, FREContext ctx,
                                         uint32_t *numFunctions, const FRENamedFunction **functions) {
    static const FRENamedFunction fns[] = {
        ENTRY(Init), ENTRY(SetBasePath), ENTRY(LoadBank), ENTRY(UnloadBank), ENTRY(RegisterGameObj),
        ENTRY(UnregisterGameObj), ENTRY(SetDefaultListeners), ENTRY(SetDefaultListener),
        ENTRY(StopPlaying), ENTRY(PostEvent), ENTRY(SetRtpcValue), ENTRY(SetRtpcValueByPlayingID),
        ENTRY(SetPosition), ENTRY(SetListenerPosition), ENTRY(TickSoundEngineExtension),
    };
    *numFunctions = sizeof fns / sizeof fns[0];
    *functions = fns;
}

static void SoundEngineExtCtxFinalizer(FREContext ctx) {}

void SoundEngineExtInitializer(void **extData, FREContextInitializer *ctxInit, FREContextFinalizer *ctxFinal) {
    *extData = NULL;
    *ctxInit = SoundEngineExtCtxInitializer;
    *ctxFinal = SoundEngineExtCtxFinalizer;
}

void SoundEngineExtFinalizer(void *extData) {}
