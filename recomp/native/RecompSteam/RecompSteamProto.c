// See RecompSteamProto.h.
#include "RecompSteamProto.h"

#include <stdlib.h>
#include <string.h>

static void grow(rs_pb_writer *w, size_t more)
{
    if (w->length + more <= w->capacity) return;
    size_t cap = w->capacity ? w->capacity * 2 : 64;
    while (cap < w->length + more) cap *= 2;
    uint8_t *data = realloc(w->data, cap);
    if (!data) abort();
    w->data = data;
    w->capacity = cap;
}

void rs_pb_free(rs_pb_writer *w)
{
    free(w->data);
    memset(w, 0, sizeof *w);
}

void rs_pb_raw(rs_pb_writer *w, const void *bytes, size_t length)
{
    if (!length) return;
    grow(w, length);
    memcpy(w->data + w->length, bytes, length);
    w->length += length;
}

static void raw_varint(rs_pb_writer *w, uint64_t v)
{
    uint8_t b[10];
    int n = 0;
    do {
        b[n] = v & 0x7f;
        v >>= 7;
        if (v) b[n] |= 0x80;
        n++;
    } while (v);
    rs_pb_raw(w, b, n);
}

static void tag(rs_pb_writer *w, uint32_t field, int wire) { raw_varint(w, ((uint64_t)field << 3) | wire); }

void rs_pb_varint(rs_pb_writer *w, uint32_t field, uint64_t value)
{
    tag(w, field, RS_PB_VARINT);
    raw_varint(w, value);
}

void rs_pb_sint(rs_pb_writer *w, uint32_t field, int64_t value)
{
    rs_pb_varint(w, field, ((uint64_t)value << 1) ^ (uint64_t)(value >> 63));
}

void rs_pb_bool(rs_pb_writer *w, uint32_t field, bool value) { rs_pb_varint(w, field, value ? 1 : 0); }

void rs_pb_fixed32(rs_pb_writer *w, uint32_t field, uint32_t value)
{
    tag(w, field, RS_PB_FIXED32);
    uint8_t b[4] = {value, value >> 8, value >> 16, value >> 24};
    rs_pb_raw(w, b, 4);
}

void rs_pb_fixed64(rs_pb_writer *w, uint32_t field, uint64_t value)
{
    tag(w, field, RS_PB_FIXED64);
    uint8_t b[8];
    for (int i = 0; i < 8; i++) b[i] = (uint8_t)(value >> (8 * i));
    rs_pb_raw(w, b, 8);
}

void rs_pb_float(rs_pb_writer *w, uint32_t field, float value)
{
    uint32_t bits;
    memcpy(&bits, &value, 4);
    rs_pb_fixed32(w, field, bits);
}

void rs_pb_bytes(rs_pb_writer *w, uint32_t field, const void *bytes, size_t length)
{
    tag(w, field, RS_PB_BYTES);
    raw_varint(w, length);
    rs_pb_raw(w, bytes, length);
}

void rs_pb_string(rs_pb_writer *w, uint32_t field, const char *s)
{
    if (s) rs_pb_bytes(w, field, s, strlen(s));
}

void rs_pb_message(rs_pb_writer *w, uint32_t field, const rs_pb_writer *sub)
{
    rs_pb_bytes(w, field, sub->data, sub->length);
}

rs_pb_reader rs_pb_read(const void *data, size_t length)
{
    rs_pb_reader r = {data, (const uint8_t *)data + length, false};
    if (!data) r.p = r.end = NULL;
    return r;
}

static bool read_varint(rs_pb_reader *r, uint64_t *out)
{
    uint64_t v = 0;
    for (int shift = 0; shift < 64; shift += 7) {
        if (r->p >= r->end) return false;
        uint8_t b = *r->p++;
        v |= (uint64_t)(b & 0x7f) << shift;
        if (!(b & 0x80)) {
            *out = v;
            return true;
        }
    }
    return false;
}

bool rs_pb_next(rs_pb_reader *r, rs_pb_field *f)
{
    if (r->error || r->p >= r->end) return false;
    uint64_t key;
    memset(f, 0, sizeof *f);
    if (!read_varint(r, &key)) goto bad;
    f->number = (uint32_t)(key >> 3);
    f->wire = key & 7;
    switch (f->wire) {
    case RS_PB_VARINT:
        if (!read_varint(r, &f->varint)) goto bad;
        return true;
    case RS_PB_FIXED64:
        if (r->end - r->p < 8) goto bad;
        for (int i = 0; i < 8; i++) f->varint |= (uint64_t)r->p[i] << (8 * i);
        r->p += 8;
        return true;
    case RS_PB_FIXED32:
        if (r->end - r->p < 4) goto bad;
        for (int i = 0; i < 4; i++) f->varint |= (uint64_t)r->p[i] << (8 * i);
        r->p += 4;
        return true;
    case RS_PB_BYTES: {
        uint64_t n;
        if (!read_varint(r, &n) || n > (uint64_t)(r->end - r->p)) goto bad;
        f->data = r->p;
        f->length = (size_t)n;
        r->p += n;
        return true;
    }
    }
bad:
    r->error = true;
    return false;
}

bool rs_pb_get(const void *data, size_t length, uint32_t field, rs_pb_field *out)
{
    rs_pb_reader r = rs_pb_read(data, length);
    rs_pb_field f;
    bool found = false;
    while (rs_pb_next(&r, &f))
        if (f.number == field) {
            *out = f;
            found = true;
        }
    return found;
}

uint64_t rs_pb_get_varint(const void *data, size_t length, uint32_t field, uint64_t fallback)
{
    rs_pb_field f;
    return rs_pb_get(data, length, field, &f) && f.wire != RS_PB_BYTES ? f.varint : fallback;
}

size_t rs_pb_get_string(const void *data, size_t length, uint32_t field, char *out, size_t size)
{
    rs_pb_field f;
    size_t n = 0;
    if (size && rs_pb_get(data, length, field, &f) && f.wire == RS_PB_BYTES) {
        n = f.length < size - 1 ? f.length : size - 1;
        memcpy(out, f.data, n);
    }
    if (size) out[n] = 0;
    return n;
}

float rs_pb_float_of(const rs_pb_field *f)
{
    uint32_t bits = (uint32_t)f->varint;
    float v;
    memcpy(&v, &bits, 4);
    return v;
}

int64_t rs_pb_zigzag(uint64_t v) { return (int64_t)(v >> 1) ^ -(int64_t)(v & 1); }
