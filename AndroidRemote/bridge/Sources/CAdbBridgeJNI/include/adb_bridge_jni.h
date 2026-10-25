#ifndef ADB_BRIDGE_JNI_H
#define ADB_BRIDGE_JNI_H

#include <stddef.h>
#include <stdint.h>

// Implemented in Swift (Bridge.swift). Returns a malloc'd reply the caller frees:
// 4-byte big-endian JSON length, the JSON, then any binary payload.
uint8_t *adbbridge_call(const char *request, const uint8_t *input, size_t input_len, size_t *out_len);

#endif
