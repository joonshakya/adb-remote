// Raw DEFLATE decompression (ZIP entries) with the system zlib,
// which both iOS and Android ship.
#ifndef ADB_ZLIB_H
#define ADB_ZLIB_H

#include <stddef.h>
#include <stdint.h>

typedef struct adb_inflater adb_inflater;

adb_inflater *adb_inflater_new(void);
void adb_inflater_free(adb_inflater *inflater);
// Feeds compressed input; calls `sink` for each block of output.
// Returns 0 to continue, 1 at the end of the stream, -1 on bad data.
int adb_inflater_write(adb_inflater *inflater, const uint8_t *in, size_t len,
                       void (*sink)(void *context, const uint8_t *out, size_t len), void *context);

#endif
