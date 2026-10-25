package local.adbremote.viewer.airplay;

import android.util.Log;

import java.io.DataInputStream;
import java.io.IOException;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.List;

/**
 * The mirrored screen: H.264 over its own TCP connection. Each packet has a 128-byte
 * header (payload size, type, timestamp); picture packets are AES-CTR encrypted with
 * one key stream for the whole connection, and carry length-prefixed NAL units.
 */
final class MirrorStream implements MirrorSource {
    /** Receives the decoded-ready video: Annex-B (start-code) access units. */
    interface Sink {
        /** New picture format: SPS and PPS with start codes, and the picture size. */
        void configure(byte[] sps, byte[] pps, int width, int height);
        void frame(byte[] annexB, boolean keyFrame);
    }

    private static final Charset ASCII = Charset.forName("US-ASCII");
    private static final byte[] START = {0, 0, 0, 1};

    private final Ctr cipher;
    private final AirPlayServer.Listener listener;
    private ServerSocket server;
    private Socket socket;
    private volatile boolean running;

    // Until the screen is ready, keep the latest format and the frames since the last key frame.
    private Sink sink;
    private byte[] sps, pps;
    private int width, height;
    private final List<byte[]> pending = new ArrayList<byte[]>();

    MirrorStream(byte[] audioKey, long streamConnectionId, AirPlayServer.Listener listener) throws Exception {
        this.listener = listener;
        String id = unsigned(streamConnectionId);
        byte[] key = AirPlayServer.slice(AirPlayServer.sha512(AirPlayServer.concat(("AirPlayStreamKey" + id).getBytes(ASCII), audioKey)), 0, 16);
        byte[] iv = AirPlayServer.slice(AirPlayServer.sha512(AirPlayServer.concat(("AirPlayStreamIV" + id).getBytes(ASCII), audioKey)), 0, 16);
        cipher = new Ctr(key, iv);
    }

    /** streamConnectionID is an unsigned 64-bit number. */
    private static String unsigned(long v) {
        if (v >= 0) return Long.toString(v);
        return java.math.BigInteger.valueOf(v).add(java.math.BigInteger.ONE.shiftLeft(64)).toString();
    }

    int start() throws IOException {
        // 7100 like an Apple TV (also lets tests forward a known port); any free one otherwise.
        server = new ServerSocket();
        server.setReuseAddress(true);
        try {
            server.bind(new java.net.InetSocketAddress(7100));
        } catch (IOException taken) {
            server.close();
            server = new ServerSocket(0);
        }
        running = true;
        new Thread("airplay-mirror") {
            @Override public void run() { receive(); }
        }.start();
        return server.getLocalPort();
    }

    void stop() {
        running = false;
        try { server.close(); } catch (Exception ignored) {}
        try { if (socket != null) socket.close(); } catch (Exception ignored) {}
    }

    @Override
    public synchronized void setSink(Sink sink) {
        this.sink = sink;
        if (sink == null) return;
        if (sps != null) sink.configure(sps, pps, width, height);
        for (byte[] frame : pending) sink.frame(frame, false);
        pending.clear();
    }

    private void receive() {
        try {
            socket = server.accept();
            server.close();
            socket.setTcpNoDelay(true);
            socket.setReceiveBufferSize(1 << 20);
            DataInputStream in = new DataInputStream(new java.io.BufferedInputStream(socket.getInputStream(), 1 << 16));
            byte[] header = new byte[128];
            while (running) {
                in.readFully(header);
                int size = (header[0] & 0xff) | (header[1] & 0xff) << 8 | (header[2] & 0xff) << 16 | (header[3] & 0xff) << 24;
                if (size < 0 || size > 16 << 20) throw new IOException("bad packet size " + size);
                byte[] payload = new byte[size];
                in.readFully(payload);
                listener.onActivity();
                int type = header[4] & 0xff;
                if (type == 0) {
                    cipher.apply(payload);
                    picture(payload);
                } else if (type == 1) {
                    format(header, payload);
                }
                // 2 and 5: heartbeats and statistics.
            }
        } catch (Exception e) {
            if (running) Log.w(AirPlayServer.TAG, "mirror stream ended: " + e);
        }
    }

    /** Codec packet: an avcC record with the SPS and PPS; the header holds the picture size. */
    private void format(byte[] header, byte[] p) {
        if (p.length < 11) return;
        width = (int) Float.intBitsToFloat(le32(header, 56));
        height = (int) Float.intBitsToFloat(le32(header, 60));
        int spsLength = ((p[6] & 0xff) << 8) | (p[7] & 0xff);
        if (8 + spsLength + 3 > p.length) return;
        int ppsLength = ((p[9 + spsLength] & 0xff) << 8) | (p[10 + spsLength] & 0xff);
        if (11 + spsLength + ppsLength > p.length) return;
        byte[] newSps = AirPlayServer.concat(START, AirPlayServer.slice(p, 8, spsLength));
        byte[] newPps = AirPlayServer.concat(START, AirPlayServer.slice(p, 11 + spsLength, ppsLength));
        synchronized (this) {
            sps = newSps;
            pps = newPps;
            pending.clear();
            Log.i(AirPlayServer.TAG, "video " + width + "x" + height);
            if (sink != null) sink.configure(sps, pps, width, height);
        }
    }

    /** Length-prefixed NAL units to start codes. */
    private void picture(byte[] data) {
        if (data == null) return;
        boolean key = false;
        int at = 0;
        while (at + 4 <= data.length) {
            int length = ((data[at] & 0xff) << 24) | ((data[at + 1] & 0xff) << 16) | ((data[at + 2] & 0xff) << 8) | (data[at + 3] & 0xff);
            if (length < 0 || length > data.length - at - 4) return; // decryption out of step; drop
            data[at] = 0; data[at + 1] = 0; data[at + 2] = 0; data[at + 3] = 1;
            if (length > 0 && (data[at + 4] & 0x1f) == 5) key = true;
            at += 4 + length;
        }
        synchronized (this) {
            if (sink != null) {
                sink.frame(data, key);
            } else {
                if (key) pending.clear();
                if (pending.size() < 120) pending.add(data);
            }
        }
    }

    private static int le32(byte[] b, int at) {
        return (b[at] & 0xff) | (b[at + 1] & 0xff) << 8 | (b[at + 2] & 0xff) << 16 | (b[at + 3] & 0xff) << 24;
    }
}
