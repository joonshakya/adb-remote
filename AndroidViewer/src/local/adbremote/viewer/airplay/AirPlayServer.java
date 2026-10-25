package local.adbremote.viewer.airplay;

import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.Charset;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * The AirPlay control connection (RTSP on port 7000): pairing, FairPlay key exchange and
 * stream setup for screen mirroring (video stream type 110) and its sound (type 96).
 * Protocol details follow UxPlay (github.com/FDH2/UxPlay). One iPhone at a time.
 */
final class AirPlayServer {
    static final String TAG = "AirPlay";
    /**
     * Features advertised to the iPhone: UxPlay's set (mirroring, audio, photos, FairPlay, legacy
     * pairing) plus bit 0 (video) and bit 4 (HLS), so apps hand videos over instead of mirroring.
     */
    static final long FEATURES = 0x5A7FFEF7L;
    static final String MODEL = "AppleTV3,2";
    static final String SOURCE_VERSION = "220.68";

    interface Listener {
        /** Screen mirroring started: show the video. */
        void onMirrorStart(MirrorSource stream);
        /** Screen mirroring ended (the iPhone stopped, or the connection dropped). */
        void onMirrorStop();
        /** Any activity, to keep the service from timing out. */
        void onActivity();
    }

    private static final Charset ASCII = Charset.forName("US-ASCII");
    private static final SecureRandom random = new SecureRandom();

    private final Listener listener;
    private final android.content.Context context;
    private final VideoSession video;
    private final String name;
    private final String deviceId;
    private final byte[] edSecret;
    private final int width;
    private final int height;
    private final int fps;
    private ServerSocket listenerSocket;
    private volatile boolean running;
    private Connection active;

    AirPlayServer(android.content.Context context, Listener listener, String name, String deviceId, byte[] edSecret,
                  int width, int height, int fps) {
        this.context = context;
        this.video = new VideoSession(context);
        this.listener = listener;
        this.name = name;
        this.deviceId = deviceId;
        this.edSecret = edSecret;
        this.width = width;
        this.height = height;
        this.fps = fps;
    }

    byte[] publicKey() {
        byte[] pk = new byte[32];
        System.arraycopy(edSecret, 32, pk, 0, 32);
        return pk;
    }

    /** Starts listening; returns the port. */
    int start() throws IOException {
        listenerSocket = new ServerSocket();
        listenerSocket.setReuseAddress(true);
        try {
            listenerSocket.bind(new InetSocketAddress(7000));
        } catch (IOException taken) {
            listenerSocket.close();
            listenerSocket = new ServerSocket(0);
        }
        running = true;
        new Thread("airplay-accept") {
            @Override public void run() {
                while (running) {
                    try {
                        final Socket socket = listenerSocket.accept();
                        new Thread("airplay-rtsp") {
                            @Override public void run() { new Connection(socket).run(); }
                        }.start();
                    } catch (IOException e) {
                        if (!running) return;
                    }
                }
            }
        }.start();
        return listenerSocket.getLocalPort();
    }

    void stop() {
        running = false;
        try { listenerSocket.close(); } catch (Exception ignored) {}
        Connection connection = active;
        if (connection != null) connection.close();
    }

    // MARK: TXT records (also returned by GET /info)

    List<String> airplayTxt() {
        List<String> txt = new ArrayList<String>();
        txt.add("deviceid=" + deviceId);
        txt.add("features=0x" + Long.toHexString(FEATURES).toUpperCase(Locale.US) + ",0x0");
        txt.add("pw=false");
        txt.add("flags=0x4");
        txt.add("model=" + MODEL);
        txt.add("pk=" + hex(publicKey()));
        txt.add("pi=2e388006-13ba-4041-9a67-25dd4a43d536");
        txt.add("srcvers=" + SOURCE_VERSION);
        txt.add("vv=2");
        return txt;
    }

    List<String> raopTxt() {
        List<String> txt = new ArrayList<String>();
        txt.add("ch=2");
        txt.add("cn=0,1,2,3");
        txt.add("da=true");
        txt.add("et=0,3,5");
        txt.add("vv=2");
        txt.add("ft=0x" + Long.toHexString(FEATURES).toUpperCase(Locale.US) + ",0x0");
        txt.add("am=" + MODEL);
        txt.add("md=0,1,2");
        txt.add("rhd=5.6.0.0");
        txt.add("pw=false");
        txt.add("sr=44100");
        txt.add("ss=16");
        txt.add("sv=false");
        txt.add("tp=UDP");
        txt.add("txtvers=1");
        txt.add("sf=0x4");
        txt.add("vs=" + SOURCE_VERSION);
        txt.add("vn=65537");
        txt.add("pk=" + hex(publicKey()));
        return txt;
    }

    private static byte[] txtBytes(List<String> txt) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        for (String entry : txt) {
            byte[] b = entry.getBytes(ASCII);
            out.write(b.length);
            out.write(b, 0, b.length);
        }
        return out.toByteArray();
    }

    // MARK: Connection

    private final class Connection {
        final Socket socket;
        InputStream in;
        OutputStream out;
        // Pairing and keys
        byte[] ecdhSecret;
        byte[] fairplayMessage;
        byte[] aesKey;
        byte[] aesIv;
        // Streams
        MirrorStream mirror;
        AudioStream audio;
        TimingClient timing;
        boolean reversed;
        boolean closeAfterReply;

        Connection(Socket socket) {
            this.socket = socket;
        }

        void run() {
            try {
                socket.setTcpNoDelay(true);
                in = socket.getInputStream();
                out = socket.getOutputStream();
                while (running) {
                    Request request = Request.read(in);
                    if (request == null) break;
                    listener.onActivity();
                    // After POST /reverse this connection carries our requests to the iPhone;
                    // what arrives are its replies, which need no answer.
                    if (reversed) continue;
                    handle(request);
                    if (closeAfterReply) break;
                }
            } catch (Exception e) {
                Log.w(TAG, "connection ended: " + e);
            } finally {
                close();
            }
        }

        void close() {
            stopMirror();
            if (audio != null) { audio.stop(); audio = null; }
            if (timing != null) { timing.stop(); timing = null; }
            try { socket.close(); } catch (IOException ignored) {}
            synchronized (AirPlayServer.this) {
                if (active == this) active = null;
            }
        }

        void stopMirror() {
            if (mirror != null) {
                mirror.stop();
                mirror = null;
                listener.onMirrorStop();
            }
        }

        void handle(Request r) throws Exception {
            Response response = new Response(r);
            String path = r.path;
            Log.d(TAG, r.method + " " + path);
            if (r.method.equals("GET") && path.equals("/info")) {
                info(r, response);
            } else if (r.method.equals("POST") && path.equals("/pair-setup")) {
                response.body("application/octet-stream", publicKey());
            } else if (r.method.equals("POST") && path.equals("/pair-verify")) {
                pairVerify(r, response);
            } else if (r.method.equals("POST") && path.equals("/fp-setup")) {
                fpSetup(r, response);
            } else if (r.method.equals("SETUP")) {
                setup(r, response);
            } else if (r.method.equals("GET_PARAMETER")) {
                String body = new String(r.body, ASCII);
                if (body.contains("volume")) {
                    response.body("text/parameters", "volume: 0.000000\r\n".getBytes(ASCII));
                }
            } else if (r.method.equals("SET_PARAMETER")) {
                setParameter(r);
            } else if (r.method.equals("RECORD")) {
                response.header("Audio-Latency", "11025");
                response.header("Audio-Jack-Status", "connected; type=analog");
            } else if (r.method.equals("FLUSH")) {
                if (audio != null) audio.flush();
            } else if (r.method.equals("TEARDOWN")) {
                // Like an Apple TV: a full teardown ends the session and its connection. The iPhone
                // waits for this when it switches from mirroring to handing over a video.
                response.header("Connection", "close");
                closeAfterReply = teardown(r);
            } else if (r.method.equals("OPTIONS")) {
                response.header("Public", "SETUP, RECORD, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER");
            } else if (path.equals("/server-info")) {
                serverInfo(response);
            } else if (path.equals("/reverse")) {
                response.status(101, "Switching Protocols");
                response.header("Upgrade", "PTTH/1.0");
                response.header("Connection", "Upgrade");
                response.send(out);
                video.setEventChannel(socket, out);
                reversed = true;
                return;
            } else if (path.equals("/play")) {
                if (!video.play(r)) response.status(400, "Bad Request");
            } else if (path.equals("/action")) {
                video.action(r.body);
            } else if (path.equals("/scrub")) {
                String position = r.queryValue("position");
                if (position != null) {
                    MediaActivity.seek(Double.parseDouble(position));
                } else {
                    response.body("text/parameters", String.format(Locale.US, "duration: %.6f\nposition: %.6f\n",
                            MediaActivity.duration(), MediaActivity.position()).getBytes(ASCII));
                }
            } else if (path.equals("/rate")) {
                String value = r.queryValue("value");
                if (value != null) MediaActivity.setRate(Double.parseDouble(value));
            } else if (path.equals("/stop")) {
                video.stop();
            } else if (path.equals("/playback-info")) {
                playbackInfo(response);
            } else if (path.equals("/setProperty")) {
                Map<String, Object> ok = new LinkedHashMap<String, Object>();
                ok.put("errorCode", 0L);
                response.body("text/x-apple-plist+xml", Bplist.xml(ok));
            } else if (path.equals("/photo") && r.body.length > 0) {
                MediaActivity.showPhoto(context, r.body);
            }
            // POST /feedback, POST /audioMode and anything else: plain 200 OK.
            response.send(out);
        }

        /** GET /server-info: what the video side supports (UxPlay's answer). */
        void serverInfo(Response response) {
            Map<String, Object> res = new LinkedHashMap<String, Object>();
            res.put("features", 0x27FL); // video, photo, FairPlay video, volume, HLS, slideshow, audio
            res.put("macAddress", deviceId);
            res.put("model", MODEL);
            res.put("osBuildVersion", "12B435");
            res.put("protovers", "1.0");
            res.put("srcvers", SOURCE_VERSION);
            res.put("vv", 2L);
            res.put("deviceid", deviceId);
            response.body("text/x-apple-plist+xml", Bplist.xml(res));
        }

        /** GET /playback-info: progress for the iPhone's controls; a closed connection means "finished". */
        void playbackInfo(Response response) {
            if (MediaActivity.ended() && !MediaActivity.isShowing()) {
                closeAfterReply = true;
                return;
            }
            if (!MediaActivity.ready()) return;
            double duration = MediaActivity.duration(), position = MediaActivity.position();
            Map<String, Object> res = new LinkedHashMap<String, Object>();
            res.put("duration", duration);
            res.put("position", position);
            res.put("rate", MediaActivity.playing() ? 1.0 : 0.0);
            res.put("readyToPlay", 1L);
            res.put("playbackBufferEmpty", 0L);
            res.put("playbackBufferFull", 1L);
            res.put("playbackLikelyToKeepUp", 1L);
            List<Object> loaded = new ArrayList<Object>();
            Map<String, Object> l = new LinkedHashMap<String, Object>();
            l.put("duration", Math.max(duration - position, 0));
            l.put("start", position);
            loaded.add(l);
            res.put("loadedTimeRanges", loaded);
            List<Object> seekable = new ArrayList<Object>();
            Map<String, Object> s = new LinkedHashMap<String, Object>();
            s.put("duration", duration);
            s.put("start", 0.0);
            seekable.add(s);
            res.put("seekableTimeRanges", seekable);
            response.body("text/x-apple-plist+xml", Bplist.xml(res));
        }

        void info(Request r, Response response) {
            Map<String, Object> res = new LinkedHashMap<String, Object>();
            if (Bplist.isBinary(r.body)) {
                // First request: the iPhone asks for our Bonjour TXT record.
                Object qualifier = Bplist.dict(Bplist.parse(r.body)).get("qualifier");
                if (qualifier instanceof List && ((List<?>) qualifier).contains("txtAirPlay")) {
                    res.put("txtAirPlay", txtBytes(airplayTxt()));
                }
                response.body("application/x-apple-binary-plist", Bplist.write(res));
                return;
            }
            res.put("deviceID", deviceId);
            res.put("macAddress", deviceId);
            res.put("pk", publicKey());
            res.put("features", FEATURES);
            res.put("name", name);
            res.put("pi", "2e388006-13ba-4041-9a67-25dd4a43d536");
            res.put("vv", 2L);
            res.put("statusFlags", 68L);
            res.put("keepAliveLowPower", true);
            res.put("sourceVersion", SOURCE_VERSION);
            res.put("keepAliveSendStatsAsBody", true);
            res.put("model", MODEL);
            res.put("initialVolume", 0.0);
            List<Object> latencies = new ArrayList<Object>();
            List<Object> formats = new ArrayList<Object>();
            for (long t : new long[] {100, 101}) {
                Map<String, Object> latency = new LinkedHashMap<String, Object>();
                latency.put("type", t);
                latency.put("inputLatencyMicros", 0L);
                latency.put("audioType", "default");
                latency.put("outputLatencyMicros", false);
                latencies.add(latency);
                Map<String, Object> format = new LinkedHashMap<String, Object>();
                format.put("type", t);
                format.put("audioInputFormats", 0x3fffffcL);
                format.put("audioOutputFormats", 0x3fffffcL);
                formats.add(format);
            }
            res.put("audioLatencies", latencies);
            res.put("audioFormats", formats);
            Map<String, Object> display = new LinkedHashMap<String, Object>();
            display.put("uuid", "e0ff8a27-6738-3d56-8a16-cc53aacee925");
            display.put("widthPhysical", 0L);
            display.put("heightPhysical", 0L);
            display.put("width", (long) width);
            display.put("height", (long) height);
            display.put("widthPixels", (long) width);
            display.put("heightPixels", (long) height);
            display.put("rotation", false);
            display.put("refreshRate", 1.0 / fps);
            display.put("maxFPS", (long) fps);
            display.put("overscanned", false);
            display.put("features", 14L);
            List<Object> displays = new ArrayList<Object>();
            displays.add(display);
            res.put("displays", displays);
            response.body("application/x-apple-binary-plist", Bplist.write(res));
        }

        void pairVerify(Request r, Response response) throws Exception {
            byte[] d = r.body;
            if (d.length < 4) return;
            if (d[0] == 1 && d.length >= 4 + 32 + 32) {
                byte[] theirs = slice(d, 4, 32);
                byte[] priv = new byte[32];
                random.nextBytes(priv);
                byte[] ours = Native.x25519(priv, null);
                ecdhSecret = Native.x25519(priv, theirs);
                byte[] message = concat(ours, theirs);
                byte[] signature = Native.sign(edSecret, message);
                new Ctr(slice(sha512(concat("Pair-Verify-AES-Key".getBytes(ASCII), ecdhSecret)), 0, 16),
                        slice(sha512(concat("Pair-Verify-AES-IV".getBytes(ASCII), ecdhSecret)), 0, 16)).apply(signature);
                response.body("application/octet-stream", concat(ours, signature));
            }
            // Step 2 (d[0] == 0) carries the iPhone's signature; any iPhone may mirror, so it isn't checked.
        }

        void fpSetup(Request r, Response response) {
            byte[] d = r.body;
            if (d.length == 16) {
                byte[] reply = Native.fpSetupReply(d[14]);
                if (reply != null) response.body("application/octet-stream", reply);
            } else if (d.length == 164) {
                fairplayMessage = d;
                byte[] reply = new byte[32];
                byte[] header = {0x46, 0x50, 0x4c, 0x59, 0x03, 0x01, 0x04, 0x00, 0x00, 0x00, 0x00, 0x14};
                System.arraycopy(header, 0, reply, 0, 12);
                System.arraycopy(d, 144, reply, 12, 20);
                response.body("application/octet-stream", reply);
            }
        }

        void setup(Request r, Response response) throws Exception {
            Map<String, Object> req = Bplist.dict(Bplist.parse(r.body));
            Map<String, Object> res = new LinkedHashMap<String, Object>();
            if (req.get("ekey") instanceof byte[] && req.get("eiv") instanceof byte[]) {
                synchronized (AirPlayServer.this) {
                    // A new iPhone takes over from the previous one.
                    if (active != null && active != this) active.close();
                    active = this;
                }
                aesIv = (byte[]) req.get("eiv");
                aesKey = fairplayMessage != null ? Native.fpDecrypt(fairplayMessage, (byte[]) req.get("ekey")) : new byte[16];
                if (ecdhSecret != null) aesKey = slice(sha512(concat(aesKey, ecdhSecret)), 0, 16);
                int remoteTimingPort = (int) Bplist.number(req.get("timingPort"), 0);
                timing = new TimingClient(socket.getInetAddress(), remoteTimingPort);
                res.put("timingPort", (long) timing.localPort());
                res.put("eventPort", 0L);
                Log.i(TAG, "SETUP from " + req.get("name") + " (" + req.get("model") + ")");
            }
            Object streams = req.get("streams");
            if (streams instanceof List) {
                List<Object> out = new ArrayList<Object>();
                for (Object item : (List<?>) streams) {
                    Map<String, Object> stream = Bplist.dict(item);
                    long type = Bplist.number(stream.get("type"), 0);
                    Map<String, Object> reply = new LinkedHashMap<String, Object>();
                    if (type == 110) {
                        stopMirror();
                        mirror = new MirrorStream(aesKey, Bplist.number(stream.get("streamConnectionID"), 0), listener);
                        reply.put("dataPort", (long) mirror.start());
                        reply.put("type", 110L);
                        listener.onMirrorStart(mirror);
                    } else if (type == 96) {
                        if (audio != null) audio.stop();
                        audio = new AudioStream(aesKey, aesIv, (int) Bplist.number(stream.get("ct"), AudioStream.AAC_ELD));
                        int[] ports = audio.start();
                        reply.put("dataPort", (long) ports[0]);
                        reply.put("controlPort", (long) ports[1]);
                        reply.put("type", 96L);
                    }
                    out.add(reply);
                }
                res.put("streams", out);
            }
            response.body("application/x-apple-binary-plist", Bplist.write(res));
        }

        void setParameter(Request r) {
            String type = r.header("content-type");
            if (type == null || !type.contains("text/parameters")) return;
            String body = new String(r.body, ASCII).trim();
            if (body.startsWith("volume:") && audio != null) {
                try {
                    audio.setVolume(Float.parseFloat(body.substring(7).trim()));
                } catch (NumberFormatException ignored) {
                }
            }
        }

        /** Returns true when everything was torn down (rather than one stream). */
        boolean teardown(Request r) {
            List<?> streams = null;
            if (r.body.length > 0) {
                Object s = Bplist.dict(Bplist.parse(r.body)).get("streams");
                if (s instanceof List) streams = (List<?>) s;
            }
            if (streams == null) {
                stopMirror();
                if (audio != null) { audio.stop(); audio = null; }
                return true;
            }
            for (Object item : streams) {
                long type = Bplist.number(Bplist.dict(item).get("type"), 0);
                if (type == 110) stopMirror();
                if (type == 96 && audio != null) { audio.stop(); audio = null; }
            }
            return false;
        }
    }

    // MARK: Timing

    /**
     * Sends NTP-style timing requests to the iPhone, as an Apple TV does. The replies
     * aren't used: video and sound are played as soon as they arrive.
     */
    private static final class TimingClient {
        private final DatagramSocket socket;
        private volatile boolean running = true;

        TimingClient(final InetAddress remote, final int remotePort) throws IOException {
            socket = new DatagramSocket();
            if (remotePort <= 0) return;
            new Thread("airplay-timing") {
                @Override public void run() {
                    byte[] request = new byte[32];
                    request[0] = (byte) 0x80;
                    request[1] = (byte) 0xd2;
                    request[3] = 0x07;
                    byte[] reply = new byte[128];
                    try {
                        socket.setSoTimeout(1000);
                        while (running) {
                            long now = System.currentTimeMillis();
                            long seconds = now / 1000 + 2208988800L;
                            long fraction = ((now % 1000) << 32) / 1000;
                            for (int i = 0; i < 4; i++) {
                                request[24 + i] = (byte) (seconds >>> (24 - 8 * i));
                                request[28 + i] = (byte) (fraction >>> (24 - 8 * i));
                            }
                            socket.send(new DatagramPacket(request, request.length, remote, remotePort));
                            try { socket.receive(new DatagramPacket(reply, reply.length)); } catch (IOException ignored) {}
                            Thread.sleep(3000);
                        }
                    } catch (Exception ignored) {
                    }
                }
            }.start();
        }

        int localPort() { return socket.getLocalPort(); }

        void stop() {
            running = false;
            socket.close();
        }
    }

    // MARK: RTSP messages

    static final class Request {
        String method;
        String path;
        String query = "";
        String protocol;
        final Map<String, String> headers = new LinkedHashMap<String, String>();
        byte[] body = new byte[0];

        String header(String name) { return headers.get(name.toLowerCase(Locale.US)); }

        /** A value from "?a=1&b=2". */
        String queryValue(String name) {
            for (String pair : query.split("&")) {
                if (pair.startsWith(name + "=")) return pair.substring(name.length() + 1);
            }
            return null;
        }

        static Request read(InputStream in) throws IOException {
            String line = readLine(in);
            while (line != null && line.isEmpty()) line = readLine(in);
            if (line == null) return null;
            String[] parts = line.split(" ");
            if (parts.length < 3) throw new IOException("bad request line: " + line);
            Request r = new Request();
            r.method = parts[0];
            r.path = parts[1];
            r.protocol = parts[2];
            // Some requests use full URLs (rtsp://host/path).
            int scheme = r.path.indexOf("://");
            if (scheme >= 0) {
                int slash = r.path.indexOf('/', scheme + 3);
                r.path = slash >= 0 ? r.path.substring(slash) : "/";
            }
            int query = r.path.indexOf('?');
            if (query >= 0) {
                r.query = r.path.substring(query + 1);
                r.path = r.path.substring(0, query);
            }
            String header;
            while ((header = readLine(in)) != null && !header.isEmpty()) {
                int colon = header.indexOf(':');
                if (colon > 0) r.headers.put(header.substring(0, colon).trim().toLowerCase(Locale.US), header.substring(colon + 1).trim());
            }
            String length = r.header("content-length");
            if (length != null) {
                int n = Integer.parseInt(length);
                r.body = new byte[n];
                int read = 0;
                while (read < n) {
                    int got = in.read(r.body, read, n - read);
                    if (got < 0) throw new IOException("closed in body");
                    read += got;
                }
            }
            return r;
        }

        private static String readLine(InputStream in) throws IOException {
            StringBuilder sb = new StringBuilder();
            int c;
            while ((c = in.read()) >= 0) {
                if (c == '\n') return sb.toString();
                if (c != '\r') sb.append((char) c);
            }
            return sb.length() > 0 ? sb.toString() : null;
        }
    }

    static final class Response {
        private final Request request;
        private final Map<String, String> headers = new LinkedHashMap<String, String>();
        private byte[] body = new byte[0];
        private int status = 200;
        private String reason = "OK";

        void status(int status, String reason) {
            this.status = status;
            this.reason = reason;
        }

        Response(Request request) {
            this.request = request;
        }

        void header(String name, String value) { headers.put(name, value); }

        void body(String type, byte[] data) {
            headers.put("Content-Type", type);
            body = data;
        }

        void send(OutputStream out) throws IOException {
            StringBuilder sb = new StringBuilder();
            sb.append(request.protocol.startsWith("HTTP") ? request.protocol : "RTSP/1.0")
                    .append(' ').append(status).append(' ').append(reason).append("\r\n");
            String cseq = request.header("cseq");
            if (cseq != null) sb.append("CSeq: ").append(cseq).append("\r\n");
            sb.append("Server: AirTunes/").append(SOURCE_VERSION).append("\r\n");
            for (Map.Entry<String, String> h : headers.entrySet()) {
                sb.append(h.getKey()).append(": ").append(h.getValue()).append("\r\n");
            }
            sb.append("Content-Length: ").append(body.length).append("\r\n\r\n");
            out.write(sb.toString().getBytes(ASCII));
            out.write(body);
            out.flush();
        }
    }

    // MARK: Bytes

    static byte[] sha512(byte[] data) {
        try {
            return MessageDigest.getInstance("SHA-512").digest(data);
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    static byte[] concat(byte[] a, byte[] b) {
        byte[] out = new byte[a.length + b.length];
        System.arraycopy(a, 0, out, 0, a.length);
        System.arraycopy(b, 0, out, a.length, b.length);
        return out;
    }

    static byte[] slice(byte[] b, int from, int length) {
        byte[] out = new byte[length];
        System.arraycopy(b, from, out, 0, length);
        return out;
    }

    static String hex(byte[] b) {
        StringBuilder sb = new StringBuilder();
        for (byte x : b) sb.append(String.format(Locale.US, "%02x", x));
        return sb.toString();
    }
}
