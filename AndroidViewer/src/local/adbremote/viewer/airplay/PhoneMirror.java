package local.adbremote.viewer.airplay;

import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.util.Log;

import java.io.DataInputStream;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.ArrayList;
import java.util.List;

/**
 * Mirroring from the ADB Remote Android app: its screen as H.264 and its sound as PCM, unencrypted
 * on the local network (port 7200). The pictures go through the same screen as AirPlay mirroring.
 *
 * Stream: "ADBM" and a version byte, then packets of type (1 byte), length (4), time in µs (8),
 * payload. Types: 1 = format (width 4, height 4, SPS+PPS with start codes), 2 = picture,
 * 3 = key picture (Annex-B), 4 = sound (48 kHz stereo 16-bit little-endian).
 * A new connection replaces the current one.
 */
final class PhoneMirror {
    static final int PORT = 7200;
    private static final int RATE = 48000;

    private final AirPlayService service;
    private ServerSocket server;
    private volatile boolean running;
    private Connection current;

    PhoneMirror(AirPlayService service) {
        this.service = service;
    }

    void start() throws IOException {
        server = new ServerSocket();
        server.setReuseAddress(true);
        server.bind(new InetSocketAddress(PORT));
        running = true;
        new Thread("phone-mirror") {
            @Override public void run() {
                while (running) {
                    try {
                        final Connection c = new Connection(server.accept());
                        synchronized (PhoneMirror.this) {
                            if (current != null) current.close();
                            current = c;
                        }
                        new Thread("phone-mirror-in") {
                            @Override public void run() { c.receive(); }
                        }.start();
                    } catch (IOException e) {
                        return;
                    }
                }
            }
        }.start();
    }

    void stop() {
        running = false;
        try { server.close(); } catch (Exception ignored) {}
        synchronized (this) {
            if (current != null) current.close();
            current = null;
        }
    }

    /** One phone's mirroring session. */
    final class Connection implements MirrorSource {
        private final Socket socket;
        private volatile boolean open = true;
        private AudioTrack track;

        // Until the screen is ready, keep the latest format and the frames since the last key frame.
        private MirrorStream.Sink sink;
        private byte[] sps, pps;
        private int width, height;
        private final List<byte[]> pending = new ArrayList<byte[]>();

        Connection(Socket socket) {
            this.socket = socket;
        }

        @Override
        public synchronized void setSink(MirrorStream.Sink sink) {
            this.sink = sink;
            if (sink == null) return;
            if (sps != null) sink.configure(sps, pps, width, height);
            for (byte[] frame : pending) sink.frame(frame, false);
            pending.clear();
        }

        void close() {
            open = false;
            try { socket.close(); } catch (Exception ignored) {}
        }

        void receive() {
            try {
                socket.setTcpNoDelay(true);
                socket.setReceiveBufferSize(1 << 20);
                DataInputStream in = new DataInputStream(new java.io.BufferedInputStream(socket.getInputStream(), 1 << 16));
                byte[] magic = new byte[5];
                in.readFully(magic);
                if (magic[0] != 'A' || magic[1] != 'D' || magic[2] != 'B' || magic[3] != 'M') throw new IOException("not a phone mirror stream");
                Log.i(AirPlayServer.TAG, "phone mirroring from " + socket.getInetAddress().getHostAddress());
                service.onMirrorStart(this);
                while (open) {
                    int type = in.readUnsignedByte();
                    int length = in.readInt();
                    in.readLong(); // time: frames are shown as they arrive
                    if (length < 0 || length > 16 << 20) throw new IOException("bad packet size " + length);
                    byte[] payload = new byte[length];
                    in.readFully(payload);
                    service.onActivity();
                    if (type == 1) format(payload);
                    else if (type == 2 || type == 3) picture(payload, type == 3);
                    else if (type == 4) sound(payload);
                }
            } catch (Exception e) {
                if (open) Log.i(AirPlayServer.TAG, "phone mirroring ended: " + e);
            } finally {
                open = false;
                try { socket.close(); } catch (Exception ignored) {}
                if (track != null) {
                    try { track.release(); } catch (Exception ignored) {}
                }
                synchronized (PhoneMirror.this) {
                    if (current == this) current = null;
                }
                service.onPhoneMirrorStop(this);
            }
        }

        /** Size, then the encoder's SPS and PPS (start codes included); split into the two. */
        private void format(byte[] p) {
            if (p.length < 8) return;
            int w = (p[0] & 0xff) << 24 | (p[1] & 0xff) << 16 | (p[2] & 0xff) << 8 | (p[3] & 0xff);
            int h = (p[4] & 0xff) << 24 | (p[5] & 0xff) << 16 | (p[6] & 0xff) << 8 | (p[7] & 0xff);
            byte[] config = AirPlayServer.slice(p, 8, p.length - 8);
            byte[] newSps = null, newPps = null;
            List<int[]> units = nalUnits(config);
            for (int[] u : units) {
                int nalType = config[u[0]] & 0x1f;
                byte[] unit = AirPlayServer.concat(new byte[] {0, 0, 0, 1}, AirPlayServer.slice(config, u[0], u[1] - u[0]));
                if (nalType == 7) newSps = unit;
                else if (nalType == 8) newPps = unit;
            }
            if (newSps == null || newPps == null) return;
            synchronized (this) {
                sps = newSps;
                pps = newPps;
                width = w;
                height = h;
                pending.clear();
                Log.i(AirPlayServer.TAG, "phone video " + w + "x" + h);
                if (sink != null) sink.configure(sps, pps, width, height);
            }
        }

        private void picture(byte[] annexB, boolean key) {
            synchronized (this) {
                if (sink != null) {
                    sink.frame(annexB, key);
                } else {
                    if (key) pending.clear();
                    if (pending.size() < 120) pending.add(annexB);
                }
            }
        }

        private void sound(byte[] pcm) {
            if (track == null) {
                int min = AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT);
                track = new AudioTrack(AudioManager.STREAM_MUSIC, RATE, AudioFormat.CHANNEL_OUT_STEREO,
                        AudioFormat.ENCODING_PCM_16BIT, Math.max(min * 2, RATE * 4 / 10), AudioTrack.MODE_STREAM);
                track.play();
            }
            track.write(pcm, 0, pcm.length);
        }
    }

    /** [start, end) of each NAL unit in an Annex-B buffer (after its start code). */
    static List<int[]> nalUnits(byte[] b) {
        List<int[]> starts = new ArrayList<int[]>();
        int i = 0;
        while (i + 3 <= b.length) {
            if (b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1) {
                starts.add(new int[] {i + 3, 0});
                i += 3;
            } else {
                i++;
            }
        }
        for (int k = 0; k < starts.size(); k++) {
            int end = k + 1 < starts.size() ? starts.get(k + 1)[0] - 3 : b.length;
            // A 4-byte start code leaves a zero before the next unit's 3-byte one.
            while (end > starts.get(k)[0] && b[end - 1] == 0) end--;
            starts.get(k)[1] = end;
        }
        return starts;
    }
}
