// JNI entry point for local.adbremote.android.bridge.Native. Everything else is Swift.
#include "adb_bridge_jni.h"

#include <jni.h>
#include <stdlib.h>

JNIEXPORT jbyteArray JNICALL
Java_local_adbremote_android_bridge_Native_call(JNIEnv *env, jclass cls, jstring request, jbyteArray input) {
    const char *req = (*env)->GetStringUTFChars(env, request, NULL);
    jbyte *in = NULL;
    jsize in_len = 0;
    if (input) {
        in_len = (*env)->GetArrayLength(env, input);
        in = (*env)->GetByteArrayElements(env, input, NULL);
    }
    size_t out_len = 0;
    uint8_t *out = adbbridge_call(req, (const uint8_t *)in, (size_t)in_len, &out_len);
    if (in) (*env)->ReleaseByteArrayElements(env, input, in, JNI_ABORT);
    (*env)->ReleaseStringUTFChars(env, request, req);
    jbyteArray result = (*env)->NewByteArray(env, (jsize)out_len);
    if (result) (*env)->SetByteArrayRegion(env, result, 0, (jsize)out_len, (const jbyte *)out);
    free(out);
    return result;
}
