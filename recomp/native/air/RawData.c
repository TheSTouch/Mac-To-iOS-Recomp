// RawData native extension for AIR ports (Brawlhalla's `.swz` reader), rebuilt for iOS.
//
// The game ships this ANE for Intel Macs only. It decrypts and inflates the `.swz` data
// archives; ActionScript passes the key (RawData_Init), the whole file (RawData_SetData), then
// pulls one entry at a time as a string (RawData_GetData) until it gets null. This is the same
// algorithm, written from the Mac library's disassembly:
//
//   file   = BE32 checksum, BE32 seed ^ key, entries...
//   entry  = BE32 packedLen ^ r1, BE32 size ^ r2, BE32 checksum, packedLen bytes
//   r1, r2 = the next draws of a WELL512 generator seeded with (seed ^ key)
//
// Each packed byte is XORed with a byte of a further draw, then zlib-inflated.

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

typedef struct { uint32_t s[16]; uint32_t i; } Well512;

static void well_seed(Well512 *w, uint32_t seed) {
    w->i = 0;
    w->s[0] = seed;
    for (uint32_t k = 1; k < 16; k++)
        w->s[k] = k + 0x6c078965u * (w->s[k - 1] ^ (w->s[k - 1] >> 30));
}

static uint32_t well_next(Well512 *w) {
    uint32_t a = w->s[w->i], c = w->s[(w->i + 13) & 15];
    uint32_t b = a ^ c ^ (a << 16) ^ (c << 15);
    c = w->s[(w->i + 9) & 15];
    c ^= c >> 11;
    a = w->s[w->i] = b ^ c;
    uint32_t d = a ^ ((a << 5) & 0xda442d24u);
    w->i = (w->i + 15) & 15;
    a = w->s[w->i];
    w->s[w->i] = a ^ b ^ d ^ (a << 2) ^ (b << 18) ^ (c << 28);
    return w->s[w->i];
}

static uint32_t be32(const uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static uint32_t sKey;
static Well512 sGen;
static uint8_t *sData;
static uint32_t sLen, sPos;

static void rawdata_clear(void) {
    free(sData);
    sData = NULL;
    sLen = sPos = 0;
}

void rawdata_set_key(uint32_t key) { sKey = key; }

// Takes a copy of a whole `.swz` file; false if its header does not match the key.
int rawdata_set(const uint8_t *bytes, uint32_t len) {
    rawdata_clear();
    if (len < 8) return 0;
    sData = malloc(len);
    memcpy(sData, bytes, len);
    sLen = len;
    uint32_t checksum = be32(sData);
    well_seed(&sGen, be32(sData + 4) ^ sKey);
    sPos = 8;
    uint32_t rounds = sKey % 31 + 5, x = 0x2df4a1cdu;
    for (uint32_t k = 0; k < rounds; k++) x ^= well_next(&sGen);
    return x == checksum;
}

// The next entry, NUL-terminated (malloc'd, *size excludes the NUL); NULL at the end or on a
// bad entry, which also drops the file like the original does.
uint8_t *rawdata_next(uint32_t *size) {
    *size = 0;
    if (!sData || sPos + 12 > sLen) goto fail;
    const uint8_t *h = sData + sPos;
    sPos += 12;
    uint32_t packed = be32(h) ^ well_next(&sGen);
    uint32_t sizeKey = well_next(&sGen);
    if (sPos + packed > sLen) goto fail;
    uint32_t sum = well_next(&sGen);
    for (uint32_t k = 0; k < packed; k++) {
        uint32_t sh = k & 15, rot = k % 7 + 1;
        uint8_t b = sData[sPos + k] ^ (uint8_t)((well_next(&sGen) & (0xffu << sh)) >> sh);
        sData[sPos + k] = b;
        sum = b ^ (sum >> rot | sum << (32 - rot));
    }
    if (sum != be32(h + 8)) goto fail;
    uint32_t n = be32(h + 4) ^ sizeKey;
    uint8_t *out = malloc((size_t)n + 1);
    z_stream z = {0};
    int ok = inflateInit(&z) == Z_OK;
    if (ok) {
        z.next_in = sData + sPos;
        z.avail_in = packed;
        z.next_out = out;
        z.avail_out = n;
        inflate(&z, Z_NO_FLUSH);
        ok = z.avail_in == 0 && z.avail_out == 0;
        ok = inflateEnd(&z) == Z_OK && ok;
    }
    if (!ok) {
        free(out);
        goto fail;
    }
    sPos += packed;
    if (sPos == sLen) rawdata_clear();
    out[n] = 0;
    *size = n;
    return out;
fail:
    rawdata_clear();
    return NULL;
}

#ifndef RAWDATA_NO_FRE
#include <stdio.h>
#include "FlashRuntimeExtensions.h"

static FREObject RawData_Init(FREContext ctx, void *data, uint32_t argc, FREObject argv[]) {
    uint32_t key = 0;
    if (argc == 1 && FREGetObjectAsUint32(argv[0], &key) == FRE_OK) rawdata_set_key(key);
    FREObject r = NULL;
    FRENewObjectFromBool(1, &r);
    return r;
}

static FREObject RawData_SetData(FREContext ctx, void *data, uint32_t argc, FREObject argv[]) {
    rawdata_clear();
    int ok = 0;
    FREByteArray ba;
    if (argc == 1 && FREAcquireByteArray(argv[0], &ba) == FRE_OK) {
        ok = rawdata_set(ba.bytes, ba.length);
        fprintf(stderr, "[air] RawData_SetData %u bytes -> %s\n", ba.length, ok ? "ok" : "bad header");
        FREReleaseByteArray(argv[0]);
    }
    FREObject r = NULL;
    FRENewObjectFromBool(ok, &r);
    return r;
}

static FREObject RawData_GetData(FREContext ctx, void *data, uint32_t argc, FREObject argv[]) {
    uint32_t n;
    uint8_t *s = rawdata_next(&n);
    fprintf(stderr, "[air] RawData_GetData -> %s %u\n", s ? "entry" : "end", n);
    if (!s) return NULL;
    FREObject r = NULL;
    FRENewObjectFromUTF8(n + 1, s, &r);
    free(s);
    return r;
}

static void RawDataContextInitializer(void *extData, const uint8_t *ctxType, FREContext ctx,
                                      uint32_t *numFunctions, const FRENamedFunction **functions) {
    static const FRENamedFunction fns[] = {
        {(const uint8_t *)"RawData_Init", NULL, RawData_Init},
        {(const uint8_t *)"RawData_SetData", NULL, RawData_SetData},
        {(const uint8_t *)"RawData_GetData", NULL, RawData_GetData},
    };
    *numFunctions = 3;
    *functions = fns;
}

static void RawDataContextFinalizer(FREContext ctx) {}

// iOS links every extension into one binary, so the initializers carry the extension's name.
void RawDataExtInitializer(void **extData, FREContextInitializer *ctxInit, FREContextFinalizer *ctxFinal) {
    *extData = NULL;
    *ctxInit = RawDataContextInitializer;
    *ctxFinal = RawDataContextFinalizer;
}

void RawDataExtFinalizer(void *extData) {}
#endif
