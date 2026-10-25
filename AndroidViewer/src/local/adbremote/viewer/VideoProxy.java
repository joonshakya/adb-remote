package local.adbremote.viewer;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.TimeUnit;

/**
 * Local HTTP server the video player reads from. Byte ranges are fetched from the phone
 * over the viewer's control connection (READ ... / DATA ...), so the TV never has to
 * connect to the phone itself and playback starts as soon as the first bytes arrive.
 */
final class VideoProxy extends Thread {
    interface Requester {
        /** Asks the phone for bytes; the answer arrives through deliver(). */
        void request(int video, int request, long offset, int length);
    }

    private static final int CHUNK = 512 * 1024;

    private final Requester requester;
    private final ServerSocket listener;
    private final Map<Integer, BlockingQueue<byte[]>> waiting = new HashMap<Integer, BlockingQueue<byte[]>>();
    private int nextRequest = 1;
    private volatile int videoId = -1;
    private volatile long videoSize;
    private volatile String videoType = "video/mp4";

    VideoProxy(Requester requester) throws IOException {
        super("video-proxy");
        this.requester = requester;
        listener = new ServerSocket();
        listener.bind(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0));
        setDaemon(true);
    }

    String url(int id, long size, String type) {
        videoId = id;
        videoSize = size;
        videoType = type;
        return "http://127.0.0.1:" + listener.getLocalPort() + "/v/" + id;
    }

    void close() {
        try { listener.close(); } catch (IOException ignored) {}
    }

    /** Bytes for an earlier request (empty array = phone couldn't read). */
    void deliver(int request, byte[] data) {
        BlockingQueue<byte[]> queue;
        synchronized (waiting) {
            queue = waiting.get(request);
        }
        if (queue != null) queue.offer(data);
    }

    @Override public void run() {
        while (true) {
            final Socket socket;
            try {
                socket = listener.accept();
            } catch (IOException e) {
                return;
            }
            new Thread("video-http") {
                @Override public void run() { serve(socket); }
            }.start();
        }
    }

    private void serve(Socket socket) {
        try {
            BufferedReader in = new BufferedReader(new InputStreamReader(socket.getInputStream(), "ISO-8859-1"));
            String requestLine = in.readLine();
            if (requestLine == null) return;
            long start = 0;
            long end = -1;
            String line;
            while ((line = in.readLine()) != null && line.length() > 0) {
                String lower = line.toLowerCase();
                if (lower.startsWith("range:") && lower.contains("bytes=")) {
                    String spec = lower.substring(lower.indexOf("bytes=") + 6).trim();
                    int dash = spec.indexOf('-');
                    if (dash > 0) start = Long.parseLong(spec.substring(0, dash).trim());
                    String tail = spec.substring(dash + 1).trim();
                    if (tail.length() > 0 && tail.indexOf(',') < 0) end = Long.parseLong(tail);
                }
            }
            final int id = videoId;
            final long size = videoSize;
            String[] parts = requestLine.split(" ");
            boolean head = parts[0].equals("HEAD");
            OutputStream out = socket.getOutputStream();
            if (parts.length < 2 || !parts[1].equals("/v/" + id) || size <= 0) {
                out.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".getBytes("ISO-8859-1"));
                return;
            }
            if (end < 0 || end >= size) end = size - 1;
            if (start >= size) {
                out.write(("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */" + size
                        + "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").getBytes("ISO-8859-1"));
                return;
            }
            boolean partial = start > 0 || end < size - 1;
            StringBuilder h = new StringBuilder();
            h.append(partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n");
            h.append("Content-Type: ").append(videoType).append("\r\n");
            h.append("Accept-Ranges: bytes\r\n");
            h.append("Content-Length: ").append(end - start + 1).append("\r\n");
            if (partial) h.append("Content-Range: bytes ").append(start).append('-').append(end).append('/').append(size).append("\r\n");
            h.append("Connection: close\r\n\r\n");
            out.write(h.toString().getBytes("ISO-8859-1"));
            if (head) return;

            long offset = start;
            while (offset <= end && id == videoId) {
                int length = (int) Math.min(CHUNK, end - offset + 1);
                byte[] data = fetch(id, offset, length);
                if (data == null || data.length == 0) return;
                out.write(data);
                offset += data.length;
            }
            out.flush();
        } catch (IOException ignored) {
            // The player closed the connection (seek, stop) — normal.
        } finally {
            try { socket.close(); } catch (IOException ignored) {}
        }
    }

    private byte[] fetch(int id, long offset, int length) {
        BlockingQueue<byte[]> queue = new ArrayBlockingQueue<byte[]>(1);
        int request;
        synchronized (waiting) {
            request = nextRequest++;
            waiting.put(request, queue);
        }
        try {
            requester.request(id, request, offset, length);
            return queue.poll(30, TimeUnit.SECONDS);
        } catch (InterruptedException e) {
            return null;
        } finally {
            synchronized (waiting) {
                waiting.remove(request);
            }
        }
    }
}
