package local.adbremote.viewer.airplay;

import android.content.Context;
import android.util.Log;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * "AirPlay video": the iPhone hands over a video instead of mirroring it, and the TV plays it.
 *  - Safari and most apps send a web address, which the TV's player opens directly.
 *  - YouTube sends "mlhls://localhost/.../master.m3u8": the TV asks the iPhone for each HLS
 *    playlist over the reverse ("event") connection, then serves them to its own player
 *    from 127.0.0.1; the video segments themselves come straight from YouTube.
 * Follows UxPlay's implementation (lib/http_handlers.h, lib/airplay_video.c).
 */
final class VideoSession {
    private static final Charset UTF8 = Charset.forName("UTF-8");
    private static final String MASTER = "/master.m3u8";

    private final Context context;
    private volatile OutputStream events;
    private String sessionId;
    private String uriPrefix;
    private double startSeconds;
    /** Playlists still to fetch through the iPhone, one at a time; ones the player waits for go first. */
    private final java.util.LinkedList<String> toFetch = new java.util.LinkedList<String>();
    private String fetching;
    private Socket eventSocket;
    private int nextRequestId = 1;
    private final Map<String, String> playlists = new ConcurrentHashMap<String, String>();
    private ServerSocket hls;

    VideoSession(Context context) {
        this.context = context.getApplicationContext();
    }

    /**
     * The connection the iPhone turned around (POST /reverse) for our requests to it. Only the
     * newest is used; an older one left open makes the iPhone ignore our requests.
     */
    synchronized void setEventChannel(Socket socket, OutputStream out) {
        if (eventSocket != null && eventSocket != socket) {
            try { eventSocket.close(); } catch (IOException ignored) {}
        }
        eventSocket = socket;
        events = out;
    }

    /** POST /stop: the iPhone took the video back. */
    synchronized void stop() {
        MediaActivity.stop();
        toFetch.clear();
        fetching = null;
        uriPrefix = null;
        if (eventSocket != null) {
            try { eventSocket.close(); } catch (IOException ignored) {}
            eventSocket = null;
            events = null;
        }
        notifyAll();
    }

    // MARK: Requests from the iPhone

    /** POST /play. Returns false if the request can't be played. */
    synchronized boolean play(AirPlayServer.Request r) throws IOException {
        String location = null;
        double start = 0;
        if (Bplist.isBinary(r.body)) {
            Map<String, Object> req = Bplist.dict(Bplist.parse(r.body));
            Object l = req.get("Content-Location");
            if (l instanceof String) location = (String) l;
            start = Bplist.real(req.get("Start-Position-Seconds"), 0);
            Log.i(AirPlayServer.TAG, "play from " + req.get("clientProcName") + ": " + location);
        } else {
            // Older form: "Content-Location: <url>\nStart-Position: 0.0"
            for (String line : new String(r.body, UTF8).split("\n")) {
                if (line.startsWith("Content-Location:")) location = line.substring(17).trim();
            }
        }
        if (location == null) return false;
        sessionId = r.header("x-apple-session-id");
        startSeconds = start;
        if (location.startsWith("http://") || location.startsWith("https://")) {
            MediaActivity.playVideo(context, location, start);
            return true;
        }
        int master = location.indexOf(MASTER);
        if (master < 0) return false;
        // YouTube: fetch the playlists through the iPhone first.
        uriPrefix = location.substring(0, master);
        playlists.clear();
        toFetch.clear();
        startHlsServer();
        // Show the video screen now: the iPhone stops mirroring while the playlists arrive.
        MediaActivity.showLoading(context);
        fetching = location;
        requestFromPhone(location);
        return true;
    }

    /** POST /action: a playlist the iPhone fetched for us. */
    synchronized void action(byte[] body) throws IOException {
        Map<String, Object> req = Bplist.dict(Bplist.parse(body));
        if (!"unhandledURLResponse".equals(req.get("type"))) {
            Log.i(AirPlayServer.TAG, "action " + req.get("type"));
            return;
        }
        Map<String, Object> params = Bplist.dict(req.get("params"));
        Object url = params.get("FCUP_Response_URL");
        Object data = params.get("FCUP_Response_Data");
        if (!(url instanceof String) || !(data instanceof byte[]) || uriPrefix == null) return;
        String playlist = new String((byte[]) data, UTF8);
        if (!playlist.endsWith("\n")) playlist += "\n";
        String path = ((String) url).startsWith(uriPrefix) ? ((String) url).substring(uriPrefix.length()) : (String) url;
        fetching = null;
        if (path.startsWith(MASTER)) {
            // The master is rewritten to point here. The player starts right away and asks for
            // the media playlists it wants; those are fetched first, the rest in the background.
            Matcher m = Pattern.compile(Pattern.quote(uriPrefix) + ".*?m3u8").matcher(playlist);
            while (m.find()) {
                if (!toFetch.contains(m.group())) toFetch.add(m.group());
            }
            playlists.put(MASTER, playlist.replace(uriPrefix, local()));
            Log.i(AirPlayServer.TAG, "master playlist with " + toFetch.size() + " media playlists");
            MediaActivity.playVideo(context, local() + MASTER, startSeconds);
        } else {
            playlists.put(path, expandCondensed(playlist));
        }
        notifyAll();
        fetchNext();
    }

    private void fetchNext() throws IOException {
        if (fetching != null || toFetch.isEmpty()) return;
        fetching = toFetch.removeFirst();
        requestFromPhone(fetching);
    }

    /** A playlist for the player: fetched already, or moved to the front and waited for. */
    private synchronized String playlistFor(String path) {
        String body = playlists.get(path);
        if (body != null || uriPrefix == null) return body;
        String uri = uriPrefix + path;
        if (toFetch.remove(uri)) toFetch.addFirst(uri);
        try {
            fetchNext();
            long until = System.currentTimeMillis() + 10000;
            while ((body = playlists.get(path)) == null && uriPrefix != null) {
                long left = until - System.currentTimeMillis();
                if (left <= 0) break;
                wait(left);
            }
        } catch (Exception e) {
            Log.w(AirPlayServer.TAG, "playlist fetch failed: " + e);
        }
        return body;
    }

    // MARK: Asking the iPhone (FCUP requests over the event channel)

    private void requestFromPhone(String url) throws IOException {
        OutputStream out = events;
        if (out == null) throw new IOException("no event channel");
        Map<String, Object> headers = new LinkedHashMap<String, Object>();
        headers.put("X-Playback-Session-Id", sessionId);
        headers.put("User-Agent", "AppleCoreMedia/1.0.0.11B554a (Apple TV; U; CPU OS 7_0_4 like Mac OS X; en_us");
        Map<String, Object> request = new LinkedHashMap<String, Object>();
        request.put("FCUP_Response_ClientInfo", 1L);
        request.put("FCUP_Response_ClientRef", 40030004L);
        request.put("FCUP_Response_RequestID", (long) nextRequestId++);
        request.put("FCUP_Response_URL", url);
        request.put("sessionID", 1L);
        request.put("FCUP_Response_Headers", headers);
        Map<String, Object> root = new LinkedHashMap<String, Object>();
        root.put("sessionID", 1L);
        root.put("type", "unhandledURLRequest");
        root.put("request", request);
        byte[] body = Bplist.xml(root);
        String head = "POST /event HTTP/1.1\r\n"
                + "X-Apple-Session-ID: " + sessionId + "\r\n"
                + "Content-Type: text/x-apple-plist+xml\r\n"
                + "Content-Length: " + body.length + "\r\n\r\n";
        synchronized (out) {
            out.write(head.getBytes(UTF8));
            out.write(body);
            out.flush();
        }
    }

    // MARK: Serving playlists to the TV's player

    private String local() {
        return "http://127.0.0.1:" + hls.getLocalPort();
    }

    private void startHlsServer() throws IOException {
        if (hls != null) return;
        hls = new ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"));
        new Thread("airplay-hls") {
            @Override public void run() {
                while (true) {
                    try {
                        final Socket s = hls.accept();
                        new Thread("airplay-hls-conn") {
                            @Override public void run() { serve(s); }
                        }.start();
                    } catch (IOException e) {
                        return;
                    }
                }
            }
        }.start();
    }

    private void serve(Socket s) {
        try {
            InputStream in = s.getInputStream();
            OutputStream out = s.getOutputStream();
            while (true) {
                AirPlayServer.Request r = AirPlayServer.Request.read(in);
                if (r == null) break;
                String body = playlistFor(r.path);
                byte[] data = body != null ? body.getBytes(UTF8) : new byte[0];
                String head = (body != null ? "HTTP/1.1 200 OK\r\n" : "HTTP/1.1 404 Not Found\r\n")
                        + "Content-Type: application/x-mpegURL; charset=utf-8\r\n"
                        + "Access-Control-Allow-Origin: *\r\n"
                        + "Content-Length: " + data.length + "\r\n\r\n";
                out.write(head.getBytes(UTF8));
                if (!r.method.equals("HEAD")) out.write(data);
                out.flush();
                if (body == null) Log.w(AirPlayServer.TAG, "player asked for unknown playlist " + r.path);
            }
        } catch (IOException ignored) {
        } finally {
            try { s.close(); } catch (IOException ignored) {}
        }
    }

    /**
     * YouTube shortens segment addresses with "#YT-EXT-CONDENSED-URL:BASE-URI=..,PARAMS=..,PREFIX=..".
     * Each "PREFIX v1/v2/.." line becomes "BASE-URI/param1/v1/param2/v2/..".
     */
    static String expandCondensed(String playlist) {
        Matcher tag = Pattern.compile("#YT-EXT-CONDENSED-URL:(.*)").matcher(playlist);
        if (!tag.find()) return playlist;
        String base = attribute(tag.group(1), "BASE-URI");
        String params = attribute(tag.group(1), "PARAMS");
        String prefix = attribute(tag.group(1), "PREFIX");
        if (base == null || params == null || prefix == null) return playlist;
        String[] names = params.split(",");
        StringBuilder out = new StringBuilder();
        for (String line : playlist.split("\n", -1)) {
            if (line.startsWith(prefix)) {
                String[] values = line.substring(prefix.length()).split("/", names.length);
                StringBuilder url = new StringBuilder(base);
                for (int i = 0; i < names.length; i++) {
                    url.append('/').append(names[i]).append('/').append(i < values.length ? values[i] : "");
                }
                out.append(url);
            } else {
                out.append(line);
            }
            out.append('\n');
        }
        return out.substring(0, out.length() - 1);
    }

    private static String attribute(String list, String name) {
        Matcher m = Pattern.compile(name + "=\"([^\"]*)\"").matcher(list);
        return m.find() ? m.group(1) : null;
    }
}
