// Deprecated: built from recomp/vendor/kettle
// The Cloud unified service as the Steam client uses it, over the session of
// RecompSteamSession.h. Field numbers follow steammessages_cloud.steamclient.proto.
//
//   list      Cloud.GetAppFileChangelist (synced change 0: the full list; file names
//             are a path prefix from a string table plus the file's own name)
//   download  Cloud.ClientFileDownload gives a URL and headers; the HTTP GET returns
//             the raw file, or a zip of it with one entry when Steam compressed it
//             (file_size != raw_file_size)
//   upload    Cloud.BeginAppUploadBatch (every name uploaded or deleted), then per file
//             Cloud.ClientBeginFileUpload (HTTP requests to make: block offset and
//             length, or an explicit body), the requests, Cloud.ClientCommitFileUpload;
//             per deleted file Cloud.ClientDeleteFile; then
//             Cloud.CompleteAppUploadBatchBlocking with the batch's result
//
// Files go up as they are (no compression, no encryption). Encrypted downloads are not
// handled: no tested game has one.
#import "cloud.h"
#import "RecompSteamSession.h"
#import "RecompSteamProto.h"
#import <CommonCrypto/CommonDigest.h>

static const double kCallTimeout = 20, kHTTPTimeout = 120;

@implementation RSCloudFile
@end

NSData *RSCloudSHA1(NSData *data) {
    unsigned char d[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, d);
    return [NSData dataWithBytes:d length:sizeof d];
}

NSString *RSCloudHex(NSData *data) {
    NSMutableString *s = [NSMutableString stringWithCapacity:data.length * 2];
    const uint8_t *b = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) [s appendFormat:@"%02x", b[i]];
    return s;
}

static void Fail(NSString **error, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static void Fail(NSString **error, NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (error && !*error) *error = s;
}

// A service call, waited for. Returns the response body, nil on failure (error says why).
static NSData *Call(const char *method, rs_pb_writer *w, NSString **error) {
    __block NSData *body = nil;
    __block int32_t eresult = RecompSteamResultTimeout;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    RecompSteam_Call(method, w->data, w->length, kCallTimeout, ^(const RecompSteamMessage *m) {
        eresult = m->eresult;
        body = [NSData dataWithBytes:m->body length:m->length];
        dispatch_semaphore_signal(done);
    });
    rs_pb_free(w);
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kCallTimeout + 5) * NSEC_PER_SEC))))
        eresult = RecompSteamResultTimeout;
    if (eresult != RecompSteamResultOK) {
        Fail(error, @"%s: %@", method, eresult == RecompSteamResultTimeout ? @"no answer from Steam"
                                                                           : [NSString stringWithFormat:@"EResult %d", eresult]);
        return nil;
    }
    return body ?: [NSData data];
}

static NSString *String(const rs_pb_field *f) {
    return [[NSString alloc] initWithBytes:f->data length:f->length encoding:NSUTF8StringEncoding] ?: @"";
}

static NSData *HTTP(NSString *method, NSString *url, NSDictionary *headers, NSData *body, NSString **error) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:kHTTPTimeout];
    req.HTTPMethod = method;
    for (NSString *k in headers) [req setValue:headers[k] forHTTPHeaderField:k];
    __block NSData *got = nil;
    __block NSInteger status = 0;
    __block NSError *err = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    void (^finish)(NSData *, NSURLResponse *, NSError *) = ^(NSData *d, NSURLResponse *r, NSError *e) {
        got = d;
        err = e;
        status = [r isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)r).statusCode : 0;
        dispatch_semaphore_signal(done);
    };
    NSURLSessionTask *task = body ? [NSURLSession.sharedSession uploadTaskWithRequest:req fromData:body completionHandler:finish]
                                  : [NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:finish];
    [task resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (err || status / 100 != 2) {
        Fail(error, @"%@ %@: %@", method, req.URL.host,
             err ? err.localizedDescription : [NSString stringWithFormat:@"HTTP %ld", (long)status]);
        return nil;
    }
    return got ?: [NSData data];
}

static NSDictionary *Headers(const uint8_t *data, size_t length, uint32_t field) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    rs_pb_reader r = rs_pb_read(data, length);
    rs_pb_field f;
    while (rs_pb_next(&r, &f)) {
        if (f.number != field || f.wire != RS_PB_BYTES) continue;
        rs_pb_field n, v;
        if (rs_pb_get(f.data, f.length, 1, &n) && rs_pb_get(f.data, f.length, 2, &v)) out[String(&n)] = String(&v);
    }
    return out;
}

// --- list ----------------------------------------------------------------------------

NSArray<RSCloudFile *> *RSCloudList(uint32_t appid, uint64_t *change, NSString **error) {
    rs_pb_writer w = {0};
    rs_pb_varint(&w, 1, appid);
    rs_pb_varint(&w, 2, 0);
    NSData *body = Call("Cloud.GetAppFileChangelist#1", &w, error);
    if (!body) return nil;
    NSMutableArray *prefixes = [NSMutableArray array], *machines = [NSMutableArray array];
    NSMutableArray *raw = [NSMutableArray array];
    rs_pb_reader r = rs_pb_read(body.bytes, body.length);
    rs_pb_field f;
    while (rs_pb_next(&r, &f)) {
        if (f.number == 1 && change) *change = f.varint;
        else if (f.number == 2) [raw addObject:[NSData dataWithBytes:f.data length:f.length]];
        else if (f.number == 4) [prefixes addObject:String(&f)];
        else if (f.number == 5) [machines addObject:String(&f)];
    }
    if (r.error) {
        Fail(error, @"Cloud.GetAppFileChangelist: answer cut short");
        return nil;
    }
    NSMutableArray *out = [NSMutableArray array];
    for (NSData *d in raw) {
        RSCloudFile *file = [[RSCloudFile alloc] init];
        uint64_t prefix = UINT64_MAX, machine = UINT64_MAX, state = 0;
        NSString *name = @"";
        rs_pb_reader fr = rs_pb_read(d.bytes, d.length);
        while (rs_pb_next(&fr, &f)) {
            switch (f.number) {
                case 1: name = String(&f); break;
                case 2: file.sha = [NSData dataWithBytes:f.data length:f.length]; break;
                case 3: file.time = f.varint; break;
                case 4: file.size = f.varint; break;
                case 5: state = f.varint; break;
                case 7: prefix = f.varint; break;
                case 8: machine = f.varint; break;
            }
        }
        if (state != 0) continue; // forgotten or deleted
        file.name = prefix < prefixes.count ? [prefixes[prefix] stringByAppendingString:name] : name;
        if (machine < machines.count) file.machine = machines[machine];
        [out addObject:file];
    }
    return out;
}

// --- download --------------------------------------------------------------------------

static uint16_t U16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t U32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

// The one entry of the zip Steam keeps a compressed file in (stored or deflated).
static NSData *Unzip(NSData *zip, NSString **error) {
    const uint8_t *b = zip.bytes;
    size_t n = zip.length;
    // The central directory gives the sizes even when the local header defers them.
    for (size_t back = 0; back + 22 <= n && back < 0x10000 + 22; back++) {
        size_t i = n - 22 - back;   // the end record, searched from the end (a comment may follow it)
        if (U32(b + i) != 0x06054b50) continue;
        size_t cd = U32(b + i + 16);
        if (cd + 46 > n || U32(b + cd) != 0x02014b50) break;
        uint16_t method = U16(b + cd + 10);
        size_t csize = U32(b + cd + 20), local = U32(b + cd + 42);
        if (local + 30 > n || U32(b + local) != 0x04034b50) break;
        size_t start = local + 30 + U16(b + local + 26) + U16(b + local + 28);
        if (start + csize > n) break;
        NSData *packed = [zip subdataWithRange:NSMakeRange(start, csize)];
        if (method == 0) return packed;
        if (method == 8) {
            // NSDataCompressionAlgorithmZlib is raw DEFLATE (RFC 1951), what zip holds.
            NSError *err = nil;
            NSData *out = [packed decompressedDataUsingAlgorithm:NSDataCompressionAlgorithmZlib error:&err];
            if (out) return out;
            Fail(error, @"cannot inflate: %@", err.localizedDescription);
            return nil;
        }
        Fail(error, @"zip method %u not handled", method);
        return nil;
    }
    Fail(error, @"not a zip Steam Cloud makes");
    return nil;
}

NSData *RSCloudDownload(uint32_t appid, NSString *name, NSString **error) {
    rs_pb_writer w = {0};
    rs_pb_varint(&w, 1, appid);
    rs_pb_string(&w, 2, name.UTF8String);
    NSData *body = Call("Cloud.ClientFileDownload#1", &w, error);
    if (!body) return nil;
    const uint8_t *p = body.bytes;
    size_t n = body.length;
    char host[256], path[2048];
    rs_pb_get_string(p, n, 7, host, sizeof host);
    rs_pb_get_string(p, n, 8, path, sizeof path);
    uint64_t size = rs_pb_get_varint(p, n, 2, 0), raw = rs_pb_get_varint(p, n, 3, 0);
    rs_pb_field sha = {0};
    rs_pb_get(p, n, 4, &sha);
    if (rs_pb_get_varint(p, n, 11, 0)) {
        Fail(error, @"%@: Steam keeps it encrypted, which is not handled", name);
        return nil;
    }
    if (!host[0]) {
        Fail(error, @"%@: Steam gave no address for it", name);
        return nil;
    }
    NSString *url = [NSString stringWithFormat:@"%@://%s%s", rs_pb_get_varint(p, n, 9, 0) ? @"https" : @"http", host, path];
    NSData *data = HTTP(@"GET", url, Headers(p, n, 10), nil, error);
    if (!data) return nil;
    if (size != raw && !(data = Unzip(data, error))) return nil;
    if (data.length != raw || (sha.length && ![RSCloudSHA1(data) isEqualToData:[NSData dataWithBytes:sha.data length:sha.length]])) {
        Fail(error, @"%@: the download does not match Steam's size or SHA-1", name);
        return nil;
    }
    return data;
}

// --- upload ------------------------------------------------------------------------------

static NSString *const kMethods[] = {@"", @"GET", @"HEAD", @"POST", @"PUT", @"DELETE", @"OPTIONS", @"PATCH"};

static BOOL UploadFile(uint32_t appid, uint64_t batch, NSString *name, NSData *data, uint64_t time, NSString **error) {
    NSData *sha = RSCloudSHA1(data);
    rs_pb_writer w = {0};
    rs_pb_varint(&w, 1, appid);
    rs_pb_varint(&w, 2, data.length);
    rs_pb_varint(&w, 3, data.length);
    rs_pb_bytes(&w, 4, sha.bytes, sha.length);
    rs_pb_varint(&w, 5, time);
    rs_pb_string(&w, 6, name.UTF8String);
    rs_pb_varint(&w, 7, 0xFFFFFFFFu);                 // every platform
    rs_pb_varint(&w, 9, RecompSteam_CellID());
    rs_pb_bool(&w, 10, false);
    rs_pb_bool(&w, 11, false);
    rs_pb_varint(&w, 13, batch);
    NSData *body = Call("Cloud.ClientBeginFileUpload#1", &w, error);
    BOOL ok = body != nil;
    if (ok) {
        rs_pb_reader r = rs_pb_read(body.bytes, body.length);
        rs_pb_field f;
        while (ok && rs_pb_next(&r, &f)) {
            if (f.number != 2 || f.wire != RS_PB_BYTES) continue;
            char host[256], path[2048];
            rs_pb_get_string(f.data, f.length, 1, host, sizeof host);
            rs_pb_get_string(f.data, f.length, 2, path, sizeof path);
            uint64_t method = rs_pb_get_varint(f.data, f.length, 4, 4);
            uint64_t offset = rs_pb_get_varint(f.data, f.length, 6, 0), length = rs_pb_get_varint(f.data, f.length, 7, 0);
            rs_pb_field explicitBody = {0};
            NSData *part;
            if (rs_pb_get(f.data, f.length, 8, &explicitBody) && explicitBody.length)
                part = [NSData dataWithBytes:explicitBody.data length:explicitBody.length];
            else if (offset + length <= data.length)
                part = [data subdataWithRange:NSMakeRange((NSUInteger)offset, (NSUInteger)length)];
            else {
                Fail(error, @"%@: Steam asked for bytes past its end", name);
                ok = NO;
                break;
            }
            NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithDictionary:Headers(f.data, f.length, 5)];
            [headers removeObjectForKey:@"Content-Length"]; // NSURLSession sets it
            NSString *url = [NSString stringWithFormat:@"%@://%s%s", rs_pb_get_varint(f.data, f.length, 3, 1) ? @"https" : @"http",
                             host, path];
            ok = HTTP(method < 8 ? kMethods[method] : @"PUT", url, headers, part, error) != nil;
        }
    }
    rs_pb_writer c = {0};
    rs_pb_bool(&c, 1, ok);
    rs_pb_varint(&c, 2, appid);
    rs_pb_bytes(&c, 3, sha.bytes, sha.length);
    rs_pb_string(&c, 4, name.UTF8String);
    NSData *committed = Call("Cloud.ClientCommitFileUpload#1", &c, error);
    if (ok && !(committed && rs_pb_get_varint(committed.bytes, committed.length, 1, 0))) {
        Fail(error, @"%@: Steam did not commit it", name);
        ok = NO;
    }
    return ok;
}

BOOL RSCloudCommit(uint32_t appid, NSString *machine, NSDictionary<NSString *, NSString *> *uploads,
                   NSDictionary<NSString *, NSNumber *> *times, NSArray<NSString *> *deletes, NSString **error) {
    if (!uploads.count && !deletes.count) return YES;
    rs_pb_writer w = {0};
    rs_pb_varint(&w, 1, appid);
    rs_pb_string(&w, 2, machine.UTF8String);
    for (NSString *n in uploads) rs_pb_string(&w, 3, n.UTF8String);
    for (NSString *n in deletes) rs_pb_string(&w, 4, n.UTF8String);
    rs_pb_varint(&w, 5, 0);
    rs_pb_varint(&w, 6, 0);
    NSData *body = Call("Cloud.BeginAppUploadBatch#1", &w, error);
    if (!body) return NO;
    uint64_t batch = rs_pb_get_varint(body.bytes, body.length, 1, 0);
    BOOL ok = YES;
    for (NSString *name in uploads) {
        @autoreleasepool {
            NSError *err = nil;
            NSData *data = [NSData dataWithContentsOfFile:uploads[name] options:NSDataReadingMappedIfSafe error:&err];
            if (!data) {
                Fail(error, @"%@: %@", name, err.localizedDescription);
                ok = NO;
                break;
            }
            if (!(ok = UploadFile(appid, batch, name, data, times[name].unsignedLongLongValue, error))) break;
        }
    }
    for (NSString *name in ok ? deletes : @[]) {
        rs_pb_writer d = {0};
        rs_pb_varint(&d, 1, appid);
        rs_pb_string(&d, 2, name.UTF8String);
        rs_pb_bool(&d, 3, true);
        rs_pb_varint(&d, 4, batch);
        if (!(ok = Call("Cloud.ClientDeleteFile#1", &d, error) != nil)) break;
    }
    rs_pb_writer done = {0};
    rs_pb_varint(&done, 1, appid);
    rs_pb_varint(&done, 2, batch);
    rs_pb_varint(&done, 3, ok ? RecompSteamResultOK : RecompSteamResultFail);
    if (!Call("Cloud.CompleteAppUploadBatchBlocking#1", &done, error)) ok = NO;
    return ok;
}
