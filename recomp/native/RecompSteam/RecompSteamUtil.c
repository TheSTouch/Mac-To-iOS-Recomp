// Small helpers for RecompSteam: CRC-32, gunzip, reading a token's SteamID.
#include "RecompSteamInternal.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

uint32_t rs_crc32(const void *data, size_t length)
{
    static uint32_t table[256];
    if (!table[1])
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[i] = c;
        }
    uint32_t crc = 0xFFFFFFFFu;
    const uint8_t *p = data;
    for (size_t i = 0; i < length; i++) crc = table[(crc ^ p[i]) & 0xff] ^ (crc >> 8);
    return crc ^ 0xFFFFFFFFu;
}

// zlib is looked up at run time: Unity's Xcode project does not link it, and IL2CPP
// carries a copy of its own.
typedef int (*inflateInit2_fn)(z_streamp, int, const char *, int);
typedef int (*inflate_fn)(z_streamp, int);
typedef int (*inflateEnd_fn)(z_streamp);

bool rs_gunzip(const void *data, size_t length, size_t expected, uint8_t **out, size_t *out_length)
{
    static inflateInit2_fn init;
    static inflate_fn run;
    static inflateEnd_fn end;
    if (!init) {
        void *z = dlopen("/usr/lib/libz.1.dylib", RTLD_LAZY);
        if (!z) return false;
        run = (inflate_fn)dlsym(z, "inflate");
        end = (inflateEnd_fn)dlsym(z, "inflateEnd");
        init = (inflateInit2_fn)dlsym(z, "inflateInit2_");
        if (!init || !run || !end) return false;
    }
    size_t cap = expected ? expected : length * 4 + 64;
    uint8_t *buf = malloc(cap);
    if (!buf) return false;
    z_stream s;
    memset(&s, 0, sizeof s);
    if (init(&s, 16 + MAX_WBITS, ZLIB_VERSION, (int)sizeof s) != Z_OK) {
        free(buf);
        return false;
    }
    s.next_in = (Bytef *)data;
    s.avail_in = (uInt)length;
    int rc;
    do {
        if (s.total_out == cap) {
            uint8_t *more = realloc(buf, cap * 2);
            if (!more) break;
            buf = more;
            cap *= 2;
        }
        s.next_out = buf + s.total_out;
        s.avail_out = (uInt)(cap - s.total_out);
        rc = run(&s, Z_NO_FLUSH);
    } while (rc == Z_OK);
    end(&s);
    if (rc != Z_STREAM_END) {
        free(buf);
        return false;
    }
    *out = buf;
    *out_length = s.total_out;
    return true;
}

static int b64url(int c)
{
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '-' || c == '+') return 62;
    if (c == '_' || c == '/') return 63;
    return -1;
}

// The JWT's payload (its claims, as JSON), malloc'd; NULL if unreadable.
static char *token_claims(const char *jwt)
{
    if (!jwt) return NULL;
    const char *a = strchr(jwt, '.');
    const char *b = a ? strchr(a + 1, '.') : NULL;
    if (!b) return NULL;
    size_t n = b - (a + 1);
    char *json = calloc(n + 1, 1);
    if (!json) return NULL;
    size_t len = 0;
    unsigned acc = 0;
    int bits = 0;
    for (const char *p = a + 1; p < b; p++) {
        int v = b64url(*p);
        if (v < 0) continue;
        acc = (acc << 6) | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            json[len++] = (char)((acc >> bits) & 0xff);
        }
    }
    json[len] = 0;
    return json;
}

uint64_t rs_token_steamid(const char *jwt)
{
    char *json = token_claims(jwt);
    if (!json) return 0;
    uint64_t id = 0;
    const char *sub = strstr(json, "\"sub\"");
    if (sub) {
        sub = strchr(sub + 5, '"');
        if (sub) id = strtoull(sub + 1, NULL, 10);
    }
    free(json);
    return id;
}

bool rs_token_has_audience(const char *jwt, const char *audience)
{
    char *json = token_claims(jwt);
    if (!json) return false;
    char quoted[64];
    snprintf(quoted, sizeof quoted, "\"%s\"", audience);
    const char *aud = strstr(json, "\"aud\"");
    const char *close = aud ? strchr(aud, ']') : NULL;
    const char *hit = aud ? strstr(aud, quoted) : NULL;
    bool ok = hit && (!close || hit < close);
    free(json);
    return ok;
}
