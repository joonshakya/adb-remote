package local.adbremote.viewer.airplay;

import javax.crypto.Cipher;
import javax.crypto.spec.SecretKeySpec;

/**
 * AES-128 in counter mode as one continuous key stream, decrypting in place. Built on ECB
 * because some Android versions' "AES/CTR" holds back a partial block until the end.
 */
final class Ctr {
    private final Cipher aes;
    private final byte[] counter;
    private final byte[] stream = new byte[16];
    private int used = 16;

    Ctr(byte[] key, byte[] iv) throws Exception {
        aes = Cipher.getInstance("AES/ECB/NoPadding");
        aes.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"));
        counter = iv.clone();
    }

    void apply(byte[] data) throws Exception {
        for (int i = 0; i < data.length; i++) {
            if (used == 16) {
                aes.doFinal(counter, 0, 16, stream, 0);
                for (int j = 15; j >= 0; j--) {
                    if (++counter[j] != 0) break;
                }
                used = 0;
            }
            data[i] ^= stream[used++];
        }
    }
}
