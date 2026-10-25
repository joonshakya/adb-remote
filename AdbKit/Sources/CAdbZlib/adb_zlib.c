#include "adb_zlib.h"

#include <stdlib.h>
#include <zlib.h>

struct adb_inflater {
    z_stream stream;
};

adb_inflater *adb_inflater_new(void) {
    adb_inflater *inflater = calloc(1, sizeof(adb_inflater));
    if (!inflater) return NULL;
    // Negative window bits: raw DEFLATE, no zlib header (as stored in ZIP).
    if (inflateInit2(&inflater->stream, -MAX_WBITS) != Z_OK) {
        free(inflater);
        return NULL;
    }
    return inflater;
}

void adb_inflater_free(adb_inflater *inflater) {
    if (!inflater) return;
    inflateEnd(&inflater->stream);
    free(inflater);
}

int adb_inflater_write(adb_inflater *inflater, const uint8_t *in, size_t len,
                       void (*sink)(void *context, const uint8_t *out, size_t len), void *context) {
    uint8_t out[65536];
    z_stream *s = &inflater->stream;
    s->next_in = (Bytef *)in;
    s->avail_in = (uInt)len;
    while (1) {
        s->next_out = out;
        s->avail_out = sizeof(out);
        int r = inflate(s, Z_NO_FLUSH);
        size_t produced = sizeof(out) - s->avail_out;
        if (produced > 0) sink(context, out, produced);
        if (r == Z_STREAM_END) return 1;
        if (r != Z_OK && r != Z_BUF_ERROR) return -1;
        if (s->avail_in == 0 && s->avail_out != 0) return 0;
        if (r == Z_BUF_ERROR && produced == 0) return 0;
    }
}
