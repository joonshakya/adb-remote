package local.adbremote.android.bridge

/** libAdbBridge.so: AdbKit (Swift). One entry point; see bridge/Sources/AdbBridge/Bridge.swift. */
object Native {
    init {
        System.loadLibrary("AdbBridge")
    }

    /** Returns a 4-byte big-endian JSON length, the JSON reply, then any binary payload. */
    @JvmStatic
    external fun call(request: String, input: ByteArray?): ByteArray
}
