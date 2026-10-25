package local.adbremote.viewer.airplay;

import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.media.MediaCodec;
import android.media.MediaFormat;
import android.os.Build;
import android.util.Log;

import java.io.IOException;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.nio.ByteBuffer;

import javax.crypto.Cipher;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * AirPlay sound: RTP over UDP, AES-CBC encrypted per packet, 44.1 kHz stereo.
 *  - Screen mirroring sends AAC-ELD (480 samples per packet), played at once to stay
 *    with the picture.
 *  - Music-only AirPlay sends ALAC (352 samples per packet); a short buffer is kept so
 *    Wi-Fi hiccups don't cause gaps.
 */
final class AudioStream {
    static final int ALAC = 2, AAC_LC = 4, AAC_ELD = 8;
    private static final int RATE = 44100;
    /** Music is held back this long before it starts, to ride out late packets. */
    private static final int MUSIC_BUFFER_MS = 300;

    private final byte[] key;
    private final byte[] iv;
    private final int codecType;
    private DatagramSocket data;
    private DatagramSocket control;
    private volatile boolean running;
    private MediaCodec decoder;
    private long alac;
    private AudioTrack track;
    private volatile float gain = 1f;
    private volatile boolean flushRequested;
    private boolean playing;
    private int packets;
    private int lastDecoded;
    private int buffered;

    AudioStream(byte[] key, byte[] iv, int codecType) {
        this.key = key;
        this.iv = iv;
        this.codecType = codecType;
    }

    /** Opens the sockets; returns {data port, control port}. */
    int[] start() throws IOException {
        data = new DatagramSocket();
        data.setReceiveBufferSize(1 << 19);
        control = new DatagramSocket();
        running = true;
        new Thread("airplay-audio") {
            @Override public void run() { receive(); }
        }.start();
        Log.i(AirPlayServer.TAG, "audio format " + codecType);
        return new int[] {data.getLocalPort(), control.getLocalPort()};
    }

    void stop() {
        running = false;
        if (data != null) data.close();
        if (control != null) control.close();
    }

    /** Skip or pause on the iPhone: drop what is queued so the next sound starts at once. */
    void flush() {
        flushRequested = true;
    }

    /** AirPlay volume in dB: 0 is full, -30 the quietest, -144 muted. */
    @SuppressWarnings("deprecation")
    void setVolume(float db) {
        Log.i(AirPlayServer.TAG, "volume " + db + " dB");
        gain = db <= -30f ? 0f : (float) Math.pow(10, db / 20);
        AudioTrack t = track;
        if (t == null) return;
        if (Build.VERSION.SDK_INT >= 21) t.setVolume(gain); else t.setStereoVolume(gain, gain);
    }

    private void receive() {
        try {
            openOutput();
            Cipher cbc = Cipher.getInstance("AES/CBC/NoPadding");
            SecretKeySpec aes = new SecretKeySpec(key, "AES");
            IvParameterSpec ivSpec = new IvParameterSpec(iv);
            byte[] buffer = new byte[16384];
            int last = -1;
            while (running) {
                DatagramPacket packet = new DatagramPacket(buffer, buffer.length);
                data.receive(packet);
                if (flushRequested) {
                    flushRequested = false;
                    resetOutput();
                    last = -1;
                }
                int length = packet.getLength();
                if (length <= 16) continue; // empty "no data yet" packets
                if (codecType == ALAC && length == 44) continue; // format-only packets
                int seq = ((buffer[2] & 0xff) << 8) | (buffer[3] & 0xff);
                // Mirroring sends each frame up to three times; play each once, in order.
                if (last >= 0) {
                    int ahead = (seq - last) & 0xffff;
                    if (ahead == 0 || ahead > 0x8000) continue;
                }
                last = seq;
                int payload = length - 12;
                byte[] frame = new byte[payload];
                int encrypted = payload / 16 * 16;
                cbc.init(Cipher.DECRYPT_MODE, aes, ivSpec);
                if (encrypted > 0) cbc.doFinal(buffer, 12, encrypted, frame, 0);
                System.arraycopy(buffer, 12 + encrypted, frame, encrypted, payload - encrypted);
                if (packets++ % 1000 == 0) {
                    // ALAC frames start with 0x20 and AAC-ELD with 0x8c-0x8e when decryption is right.
                    Log.i(AirPlayServer.TAG, "audio packets " + packets + ", length " + length
                            + ", first byte " + Integer.toHexString(frame[0] & 0xff) + ", decoded " + lastDecoded
                            + ", playing " + playing + ", gain " + gain);
                }
                decode(frame);
            }
        } catch (Exception e) {
            if (running) Log.w(AirPlayServer.TAG, "audio ended: " + e);
        } finally {
            closeOutput();
        }
    }

    @SuppressWarnings("deprecation")
    private void openOutput() throws IOException {
        if (codecType == ALAC) {
            alac = Native.alacCreate();
        } else {
            MediaFormat format = MediaFormat.createAudioFormat("audio/mp4a-latm", RATE, 2);
            // AudioSpecificConfig: AAC-ELD with 480-sample frames, or plain AAC-LC.
            byte[] config = codecType == AAC_LC ? new byte[] {0x12, 0x10}
                    : new byte[] {(byte) 0xF8, (byte) 0xE8, 0x50, 0x00};
            format.setByteBuffer("csd-0", ByteBuffer.wrap(config));
            format.setInteger(MediaFormat.KEY_IS_ADTS, 0);
            // Android's own AAC decoder handles AAC-ELD; some TV chips' decoders don't.
            try {
                decoder = MediaCodec.createByCodecName("OMX.google.aac.decoder");
            } catch (Exception e) {
                decoder = null;
            }
            if (decoder == null) decoder = MediaCodec.createDecoderByType("audio/mp4a-latm");
            decoder.configure(format, null, null, 0);
            decoder.start();
        }
        int min = AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT);
        int bytes = codecType == ALAC ? RATE * 4 * (MUSIC_BUFFER_MS * 2) / 1000 : 480 * 4 * 8;
        track = new AudioTrack(AudioManager.STREAM_MUSIC, RATE, AudioFormat.CHANNEL_OUT_STEREO,
                AudioFormat.ENCODING_PCM_16BIT, Math.max(min * 2, bytes), AudioTrack.MODE_STREAM);
        setVolume(gain <= 0 ? -144 : (float) (20 * Math.log10(gain)));
        playing = false;
        buffered = 0;
    }

    private void resetOutput() {
        AudioTrack t = track;
        if (t == null) return;
        t.pause();
        t.flush();
        playing = false;
        buffered = 0;
    }

    private void closeOutput() {
        try { if (decoder != null) { decoder.stop(); decoder.release(); } } catch (Exception ignored) {}
        try { if (track != null) { track.stop(); track.release(); } } catch (Exception ignored) {}
        if (alac != 0) Native.alacFree(alac);
        alac = 0;
        decoder = null;
        track = null;
    }

    /** Queues decoded sound; music starts once a short buffer has built up. */
    private void play(byte[] pcm, int length) {
        if (!playing) {
            buffered += length;
            int threshold = codecType == ALAC ? RATE * 4 * MUSIC_BUFFER_MS / 1000 : 0;
            if (buffered >= threshold) {
                track.play();
                playing = true;
            }
        }
        track.write(pcm, 0, length);
    }

    private final MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
    private byte[] pcm = new byte[352 * 4 * 2];

    @SuppressWarnings("deprecation")
    private void decode(byte[] frame) {
        if (codecType == ALAC) {
            int n = Native.alacDecode(alac, frame, frame.length, pcm);
            lastDecoded = n;
            if (n > 0) play(pcm, n);
            return;
        }
        int in = decoder.dequeueInputBuffer(10000);
        if (in >= 0) {
            ByteBuffer buf = decoder.getInputBuffers()[in];
            buf.clear();
            buf.put(frame);
            decoder.queueInputBuffer(in, 0, frame.length, 0, 0);
        }
        int out;
        while ((out = decoder.dequeueOutputBuffer(info, 0)) != MediaCodec.INFO_TRY_AGAIN_LATER) {
            if (out < 0) continue; // format or buffers changed
            ByteBuffer buf = decoder.getOutputBuffers()[out];
            if (pcm.length < info.size) pcm = new byte[info.size];
            buf.position(info.offset);
            buf.get(pcm, 0, info.size);
            decoder.releaseOutputBuffer(out, false);
            play(pcm, info.size);
        }
    }
}
