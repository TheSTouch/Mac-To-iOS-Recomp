// A small protobuf encoder and decoder for the Steam messages RecompSteam uses: no
// generated code, no runtime. Callers write and read fields by number, following the
// .proto files of SteamKit2 / node-steam-user.
//
//   rs_pb_writer w = {0};
//   rs_pb_varint(&w, 1, app_id);
//   RecompSteam_Send(857, w.data, w.length);
//   rs_pb_free(&w);
//
//   rs_pb_reader r = rs_pb_read(body, length);
//   rs_pb_field f;
//   while (rs_pb_next(&r, &f)) if (f.number == 3) ticket = f.data, ticket_length = f.length;
//
// Like RecompSteamSession.h, this header only ever gains declarations.
#ifndef RECOMP_STEAM_PROTO_H
#define RECOMP_STEAM_PROTO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t *data;
    size_t length, capacity;
} rs_pb_writer;

void rs_pb_free(rs_pb_writer *w);
void rs_pb_raw(rs_pb_writer *w, const void *bytes, size_t length);  // bytes as they are, no tag
void rs_pb_varint(rs_pb_writer *w, uint32_t field, uint64_t value);  // int32/uint32/uint64/enum (negatives: (uint64_t)(int64_t)v)
void rs_pb_sint(rs_pb_writer *w, uint32_t field, int64_t value);    // sint32/sint64 (zigzag)
void rs_pb_bool(rs_pb_writer *w, uint32_t field, bool value);
void rs_pb_fixed32(rs_pb_writer *w, uint32_t field, uint32_t value); // fixed32, float bits
void rs_pb_fixed64(rs_pb_writer *w, uint32_t field, uint64_t value); // fixed64, double bits
void rs_pb_float(rs_pb_writer *w, uint32_t field, float value);
void rs_pb_bytes(rs_pb_writer *w, uint32_t field, const void *bytes, size_t length);
void rs_pb_string(rs_pb_writer *w, uint32_t field, const char *s);   // NULL writes nothing
void rs_pb_message(rs_pb_writer *w, uint32_t field, const rs_pb_writer *sub);  // an embedded message

enum { RS_PB_VARINT = 0, RS_PB_FIXED64 = 1, RS_PB_BYTES = 2, RS_PB_FIXED32 = 5 };

typedef struct {
    const uint8_t *p, *end;
    bool error;          // set when the input was cut short or malformed
} rs_pb_reader;

typedef struct {
    uint32_t number;
    int wire;            // RS_PB_*
    uint64_t varint;     // the value of VARINT, FIXED64 and FIXED32 fields
    const uint8_t *data; // BYTES fields (strings, bytes, embedded messages, packed repeated)
    size_t length;
} rs_pb_field;

rs_pb_reader rs_pb_read(const void *data, size_t length);
bool rs_pb_next(rs_pb_reader *r, rs_pb_field *f);

// Conveniences: the last occurrence of field (protobuf's rule for scalars).
bool rs_pb_get(const void *data, size_t length, uint32_t field, rs_pb_field *out);
uint64_t rs_pb_get_varint(const void *data, size_t length, uint32_t field, uint64_t fallback);
// A string field copied into out (NUL-terminated, truncated to size-1); "" when absent.
size_t rs_pb_get_string(const void *data, size_t length, uint32_t field, char *out, size_t size);
float rs_pb_float_of(const rs_pb_field *f);
int64_t rs_pb_zigzag(uint64_t v);

#ifdef __cplusplus
}
#endif
#endif
