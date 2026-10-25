package local.adbremote.viewer.airplay;

/**
 * Reads the colour description from an H.264 SPS (its VUI): whether the picture uses the
 * full 0-255 range and which colour matrix. Some TV decoders ignore these, so they are
 * passed to the decoder explicitly.
 */
final class Sps {
    boolean hasSignalType;
    boolean fullRange;
    int matrix = 2; // 2 = unspecified

    /** sps starts with a start code (00 00 00 01), then the NAL header. */
    static Sps parse(byte[] sps) {
        Sps out = new Sps();
        try {
            out.read(new Bits(unescape(sps, 5)));
        } catch (RuntimeException ignored) {
            // Leave "not found"; the decoder then uses its defaults.
        }
        return out;
    }

    private void read(Bits b) {
        int profile = b.u(8);
        b.u(16); // constraint flags, level
        b.ue(); // sps id
        if (profile == 100 || profile == 110 || profile == 122 || profile == 244 || profile == 44
                || profile == 83 || profile == 86 || profile == 118 || profile == 128 || profile == 138
                || profile == 139 || profile == 134 || profile == 135) {
            int chroma = b.ue();
            if (chroma == 3) b.u(1);
            b.ue(); // bit depth luma
            b.ue(); // bit depth chroma
            b.u(1);
            if (b.u(1) == 1) { // scaling matrices
                for (int i = 0; i < (chroma == 3 ? 12 : 8); i++) {
                    if (b.u(1) == 1) skipScalingList(b, i < 6 ? 16 : 64);
                }
            }
        }
        b.ue(); // log2 max frame num
        int poc = b.ue();
        if (poc == 0) {
            b.ue();
        } else if (poc == 1) {
            b.u(1);
            b.se();
            b.se();
            int n = b.ue();
            for (int i = 0; i < n; i++) b.se();
        }
        b.ue(); // max ref frames
        b.u(1);
        b.ue(); // width in macroblocks
        b.ue(); // height in map units
        if (b.u(1) == 0) b.u(1); // frame_mbs_only, mb_adaptive
        b.u(1); // direct 8x8
        if (b.u(1) == 1) { b.ue(); b.ue(); b.ue(); b.ue(); } // cropping
        if (b.u(1) == 0) return; // no VUI
        if (b.u(1) == 1) { // aspect ratio
            if (b.u(8) == 255) b.u(32);
        }
        if (b.u(1) == 1) b.u(1); // overscan
        if (b.u(1) == 1) { // video signal type
            hasSignalType = true;
            b.u(3); // video format
            fullRange = b.u(1) == 1;
            if (b.u(1) == 1) { // colour description
                b.u(8); // primaries
                b.u(8); // transfer
                matrix = b.u(8);
            }
        }
    }

    private static void skipScalingList(Bits b, int size) {
        int last = 8, next = 8;
        for (int j = 0; j < size; j++) {
            if (next != 0) next = (last + b.se() + 256) % 256;
            last = next == 0 ? last : next;
        }
    }

    /** Drops emulation-prevention bytes (00 00 03 -> 00 00). */
    private static byte[] unescape(byte[] in, int from) {
        byte[] out = new byte[in.length];
        int n = 0, zeros = 0;
        for (int i = from; i < in.length; i++) {
            int v = in[i] & 0xff;
            if (zeros >= 2 && v == 3) {
                zeros = 0;
                continue;
            }
            zeros = v == 0 ? zeros + 1 : 0;
            out[n++] = (byte) v;
        }
        byte[] trimmed = new byte[n];
        System.arraycopy(out, 0, trimmed, 0, n);
        return trimmed;
    }

    private static final class Bits {
        final byte[] b;
        int pos;

        Bits(byte[] b) { this.b = b; }

        int u(int n) {
            int v = 0;
            for (int i = 0; i < n; i++) {
                if (pos >= b.length * 8) throw new IndexOutOfBoundsException();
                v = (v << 1) | ((b[pos >> 3] >> (7 - (pos & 7))) & 1);
                pos++;
            }
            return v;
        }

        int ue() {
            int zeros = 0;
            while (u(1) == 0) {
                if (++zeros > 31) throw new IllegalStateException();
            }
            return (1 << zeros) - 1 + (zeros == 0 ? 0 : u(zeros));
        }

        int se() {
            int k = ue();
            return (k & 1) == 1 ? (k + 1) / 2 : -(k / 2);
        }
    }
}
