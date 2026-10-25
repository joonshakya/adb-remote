package local.adbremote.viewer.airplay;

/** The receiver's native code (jni/airplay_jni.c): FairPlay key exchange and pairing curves. */
final class Native {
    static {
        System.loadLibrary("airplay");
    }

    private Native() {}

    /** New Ed25519 secret key (64 bytes: seed, then the 32-byte public key). */
    static native byte[] signKeypair();

    /** Ed25519 signature (64 bytes) of message with secretKey. */
    static native byte[] sign(byte[] secretKey, byte[] message);

    /** X25519: the public key for privateKey when point is null, else the shared secret. */
    static native byte[] x25519(byte[] privateKey, byte[] point);

    /** Reply (142 bytes) to the first FairPlay setup message of the given mode. */
    static native byte[] fpSetupReply(int mode);

    /** A new ALAC decoder for AirPlay's 44.1 kHz 16-bit stereo; free with alacFree. */
    static native long alacCreate();

    /** Decodes one ALAC packet into out as 16-bit stereo PCM; returns the bytes written. */
    static native int alacDecode(long decoder, byte[] packet, int length, byte[] out);

    static native void alacFree(long decoder);

    /** The 16-byte AES key from SETUP's 72-byte "ekey", using the 164-byte second FairPlay message. */
    static native byte[] fpDecrypt(byte[] keyMessage, byte[] ekey);
}
