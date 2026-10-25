package local.adbremote.viewer;

import android.app.Activity;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.Matrix;
import android.graphics.SurfaceTexture;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaPlayer;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.DisplayMetrics;
import android.view.Gravity;
import android.view.Surface;
import android.view.TextureView;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.io.DataInputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Full-screen viewer for photos and videos sent from the iPhone app.
 *
 * The phone connects to TCP port 38790 (over Wi-Fi, or through adb's "tcp:" service) and
 * sends one text line per command, some followed by binary data:
 *   HELLO                    -> VIEWER 1 sdk width height hevc(0/1)
 *   PHOTO id length + JPEG   -> READY id          (decoded and kept, not shown yet)
 *   SHOW id                  -> SHOWN id          (crossfades to that photo)
 *   VIDEO id size mime       -> PLAYING id / ENDED id / VERR id what
 *       while playing, the TV asks for bytes:  READ id request offset length
 *       and the phone answers:                 DATA request length + bytes
 *   PAUSE / RESUME / SEEK ms
 *       while a video is loaded:  TIME id positionMs durationMs playing(0/1)  (twice a second)
 *   ZOOM id scale u v        zoom the shown photo/video; (u, v) = point of the picture
 *                            (0..1) to put in the middle of the screen
 *   CLEAR                    -> back to the waiting screen
 *   CLOSE                    closes the viewer (the TV returns to the previous app)
 *   PING                     -> PONG
 */
public final class ViewerActivity extends Activity {
    static final int PORT = 38790;
    private static final int FADE_MS = 450;
    private static final String WAITING = "Ready for photos and videos from your iPhone.";

    private final Handler main = new Handler(Looper.getMainLooper());
    private FrameLayout root;
    private ImageView front;
    private ImageView back;
    private TextureView videoView;
    private Surface videoSurface;
    private MediaPlayer player;
    /** The player has the video open, so position and duration can be asked. */
    private boolean prepared;
    private TextView hint;
    private LinearLayout hintPanel;
    private ServerThread server;

    /** Decoded photos waiting to be shown, oldest first. */
    private final Map<Integer, Bitmap> pending = new LinkedHashMap<Integer, Bitmap>();
    private Bitmap shown;

    /** What is on screen (photo or video id) and its zoom. */
    private int currentId = -1;
    private boolean currentIsVideo;
    private int videoWidth;
    private int videoHeight;
    private float zoom = 1f;
    private float zoomU = 0.5f;
    private float zoomV = 0.5f;
    /** Latest zoom from the phone; the shown zoom glides towards it every frame. */
    private float targetZoom = 1f;
    private float targetU = 0.5f;
    private float targetV = 0.5f;
    private boolean gliding;
    private long lastFrame;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                | WindowManager.LayoutParams.FLAG_FULLSCREEN);

        root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        FrameLayout.LayoutParams fill = new FrameLayout.LayoutParams(-1, -1);

        // TextureView (not VideoView) so the video can be zoomed with a matrix.
        videoView = new TextureView(this);
        videoView.setSurfaceTextureListener(new TextureView.SurfaceTextureListener() {
            @Override public void onSurfaceTextureAvailable(SurfaceTexture texture, int w, int h) {
                videoSurface = new Surface(texture);
                if (player != null) player.setSurface(videoSurface);
                applyZoom();
            }
            @Override public void onSurfaceTextureSizeChanged(SurfaceTexture texture, int w, int h) { applyZoom(); }
            @Override public boolean onSurfaceTextureDestroyed(SurfaceTexture texture) {
                if (player != null) player.setSurface(null);
                if (videoSurface != null) videoSurface.release();
                videoSurface = null;
                return true;
            }
            @Override public void onSurfaceTextureUpdated(SurfaceTexture texture) {}
        });
        root.addView(videoView, fill);
        videoView.setVisibility(View.GONE);

        back = newImageView();
        front = newImageView();
        root.addView(back, fill);
        root.addView(front, fill);

        // Waiting / status screen: icon above one line of text, padded from every edge.
        float dp = getResources().getDisplayMetrics().density;
        hintPanel = new LinearLayout(this);
        hintPanel.setOrientation(LinearLayout.VERTICAL);
        hintPanel.setGravity(Gravity.CENTER);
        int pad = (int) (48 * dp);
        hintPanel.setPadding(pad, pad, pad, pad);
        ImageView icon = new ImageView(this);
        icon.setImageResource(getResources().getIdentifier("ic_photos", "drawable", getPackageName()));
        icon.setAlpha(0.7f);
        LinearLayout.LayoutParams iconSize = new LinearLayout.LayoutParams((int) (96 * dp), (int) (96 * dp));
        iconSize.bottomMargin = (int) (24 * dp);
        hintPanel.addView(icon, iconSize);
        hint = new TextView(this);
        hint.setTextColor(0xFFBBBBBB);
        hint.setTextSize(24);
        hint.setGravity(Gravity.CENTER);
        hint.setLineSpacing(0, 1.2f);
        hint.setText(WAITING);
        hintPanel.addView(hint, new LinearLayout.LayoutParams(-2, -2));
        root.addView(hintPanel, fill);

        root.addOnLayoutChangeListener(new View.OnLayoutChangeListener() {
            @Override public void onLayoutChange(View v, int l, int t, int r, int b, int ol, int ot, int or, int ob) {
                applyZoom();
            }
        });
        setContentView(root);
        hideSystemUi(root);
    }

    private ImageView newImageView() {
        ImageView view = new ImageView(this);
        view.setScaleType(ImageView.ScaleType.MATRIX);
        view.setBackgroundColor(Color.TRANSPARENT);
        return view;
    }

    private void hideSystemUi(View root) {
        if (Build.VERSION.SDK_INT >= 19) {
            root.setSystemUiVisibility(View.SYSTEM_UI_FLAG_FULLSCREEN
                    | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                    | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                    | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                    | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
        }
    }

    @Override
    protected void onStart() {
        super.onStart();
        server = new ServerThread();
        server.start();
    }

    @Override
    protected void onStop() {
        super.onStop();
        if (server != null) server.shutdown();
        server = null;
        stopVideo();
    }

    // MARK: Zoom (main thread)

    /**
     * Where the content goes on screen: fitted, scaled by `zoom`, with point (u, v) of the
     * content in the middle — but never leaving empty space at an edge that could be filled.
     * Returns {left, top, width, height}.
     */
    private float[] placement(float contentW, float contentH) {
        float w = root.getWidth();
        float h = root.getHeight();
        if (w <= 0 || h <= 0 || contentW <= 0 || contentH <= 0) return null;
        float fit = Math.min(w / contentW, h / contentH);
        float dw = contentW * fit * zoom;
        float dh = contentH * fit * zoom;
        float left = w / 2 - zoomU * dw;
        float top = h / 2 - zoomV * dh;
        left = dw <= w ? (w - dw) / 2 : Math.max(w - dw, Math.min(0, left));
        top = dh <= h ? (h - dh) / 2 : Math.max(h - dh, Math.min(0, top));
        return new float[] {left, top, dw, dh};
    }

    private void applyZoom() {
        if (root == null) return;
        if (currentIsVideo) {
            float[] p = placement(videoWidth, videoHeight);
            if (p == null) return;
            // A TextureView stretches the video over the whole view; map that onto the placement.
            Matrix m = new Matrix();
            m.setScale(p[2] / root.getWidth(), p[3] / root.getHeight());
            m.postTranslate(p[0], p[1]);
            videoView.setTransform(m);
            videoView.invalidate();
        } else if (shown != null) {
            fitImage(front, shown);
        }
    }

    private void fitImage(ImageView view, Bitmap bitmap) {
        float[] p = placement(bitmap.getWidth(), bitmap.getHeight());
        if (p == null) return;
        Matrix m = new Matrix();
        m.setScale(p[2] / bitmap.getWidth(), p[3] / bitmap.getHeight());
        m.postTranslate(p[0], p[1]);
        view.setImageMatrix(m);
        view.invalidate();
    }

    private void setZoom(int id, float scale, float u, float v) {
        if (id != currentId) return;
        targetZoom = Math.max(1f, Math.min(8f, scale));
        targetU = Math.max(0f, Math.min(1f, u));
        targetV = Math.max(0f, Math.min(1f, v));
        if (!gliding && root != null) {
            gliding = true;
            lastFrame = System.nanoTime();
            root.postOnAnimation(glide);
        }
    }

    /**
     * Updates from the phone arrive about 30 times a second, in uneven bursts over Wi-Fi.
     * Easing towards the latest one on every screen frame fills in the frames between them.
     */
    private final Runnable glide = new Runnable() {
        @Override public void run() {
            if (!gliding) return;
            long now = System.nanoTime();
            float dt = Math.min((now - lastFrame) / 1e9f, 0.1f);
            lastFrame = now;
            // Covers ~63% of the remaining distance every 50 ms, whatever the frame rate.
            float k = 1f - (float) Math.exp(-dt / 0.05f);
            // Zoom eases in log space so zooming in and out feel equally fast.
            zoom = (float) Math.exp(Math.log(zoom) + (Math.log(targetZoom) - Math.log(zoom)) * k);
            zoomU += (targetU - zoomU) * k;
            zoomV += (targetV - zoomV) * k;
            boolean done = Math.abs(targetZoom - zoom) < 0.001f * targetZoom
                    && Math.abs(targetU - zoomU) < 0.0005f && Math.abs(targetV - zoomV) < 0.0005f;
            if (done) {
                zoom = targetZoom;
                zoomU = targetU;
                zoomV = targetV;
                gliding = false;
            }
            applyZoom();
            if (gliding) root.postOnAnimation(this);
        }
    };

    private void resetZoom() {
        gliding = false;
        zoom = targetZoom = 1f;
        zoomU = targetU = 0.5f;
        zoomV = targetV = 0.5f;
    }

    // MARK: Display (main thread)

    private void showPhoto(final int id) {
        final Bitmap bitmap;
        synchronized (pending) {
            bitmap = pending.remove(id);
        }
        if (bitmap == null) return;
        stopVideo();
        hintPanel.setVisibility(View.GONE);
        currentId = id;
        currentIsVideo = false;
        resetZoom();
        // Crossfade: the new photo fades in on the back view while the one showing fades out
        // (from wherever it is, if the last fade is still running), then the two swap roles.
        final ImageView incoming = back;
        final ImageView outgoing = front;
        incoming.animate().cancel();
        outgoing.animate().cancel();
        release(incoming, bitmap);
        incoming.setImageBitmap(bitmap);
        incoming.setTag(bitmap);
        fitImage(incoming, bitmap);
        incoming.setAlpha(0f);
        incoming.bringToFront();
        incoming.animate().alpha(1f).setDuration(FADE_MS).start();
        outgoing.animate().alpha(0f).setDuration(FADE_MS).withEndAction(new Runnable() {
            @Override public void run() {
                // Still the hidden one (no newer photo reused it): let its picture go.
                if (outgoing == back) release(outgoing, null);
            }
        }).start();
        front = incoming;
        back = outgoing;
        shown = bitmap;
    }

    /** Empties a photo view, recycling its picture unless it is still needed. */
    private void release(ImageView view, Bitmap keep) {
        Object old = view.getTag();
        view.setImageDrawable(null);
        view.setTag(null);
        if (old instanceof Bitmap && old != keep && old != shown) ((Bitmap) old).recycle();
    }

    private void playVideo(final int id, String url) {
        stopVideo();
        message("Loading video…");
        currentId = id;
        currentIsVideo = true;
        videoWidth = 0;
        videoHeight = 0;
        resetZoom();
        front.animate().alpha(0f).setDuration(FADE_MS).start();
        back.setAlpha(0f);
        videoView.setVisibility(View.VISIBLE);

        final MediaPlayer mp = new MediaPlayer();
        player = mp;
        if (videoSurface != null) mp.setSurface(videoSurface);
        mp.setOnPreparedListener(new MediaPlayer.OnPreparedListener() {
            @Override public void onPrepared(MediaPlayer p) {
                if (player != mp) return;
                hintPanel.setVisibility(View.GONE);
                p.start();
                prepared = true;
                send("PLAYING " + id);
                main.removeCallbacks(ticker);
                main.post(ticker);
            }
        });
        mp.setOnVideoSizeChangedListener(new MediaPlayer.OnVideoSizeChangedListener() {
            @Override public void onVideoSizeChanged(MediaPlayer p, int w, int h) {
                if (player != mp) return;
                videoWidth = w;
                videoHeight = h;
                applyZoom();
            }
        });
        mp.setOnSeekCompleteListener(new MediaPlayer.OnSeekCompleteListener() {
            @Override public void onSeekComplete(MediaPlayer p) {
                if (player == mp) reportTime();
            }
        });
        mp.setOnCompletionListener(new MediaPlayer.OnCompletionListener() {
            @Override public void onCompletion(MediaPlayer p) {
                if (player == mp) send("ENDED " + id);
            }
        });
        mp.setOnErrorListener(new MediaPlayer.OnErrorListener() {
            @Override public boolean onError(MediaPlayer p, int what, int extra) {
                if (player != mp) return true;
                // Never leave a silent black screen: say what happened.
                stopVideo();
                message(extra == MediaPlayer.MEDIA_ERROR_IO || what == MediaPlayer.MEDIA_ERROR_IO
                        ? "Couldn't load the video from the iPhone.\nCheck that both are on the same Wi-Fi."
                        : "This TV can't play this video.");
                send("VERR " + id + " " + what + "/" + extra);
                return true;
            }
        });
        try {
            mp.setDataSource(url);
            mp.prepareAsync();
        } catch (Exception e) {
            stopVideo();
            message("This TV can't play this video.");
            send("VERR " + id + " " + e);
        }
    }

    /** Tells the phone where playback is, for its scrubber. */
    private void reportTime() {
        if (player == null || !prepared) return;
        try {
            send("TIME " + currentId + " " + player.getCurrentPosition() + " " + player.getDuration()
                    + " " + (player.isPlaying() ? 1 : 0));
        } catch (IllegalStateException ignored) {
        }
    }

    private final Runnable ticker = new Runnable() {
        @Override public void run() {
            reportTime();
            if (player != null && prepared) main.postDelayed(this, 500);
        }
    };

    private void stopVideo() {
        prepared = false;
        main.removeCallbacks(ticker);
        if (player != null) {
            try { player.reset(); } catch (Exception ignored) {}
            player.release();
            player = null;
        }
        videoView.setVisibility(View.GONE);
    }

    private void message(String text) {
        hint.setText(text);
        hintPanel.setVisibility(View.VISIBLE);
        hintPanel.bringToFront();
    }

    private void clear() {
        stopVideo();
        currentId = -1;
        front.setImageDrawable(null);
        back.setImageDrawable(null);
        message(WAITING);
    }

    // MARK: Network

    private void send(String line) {
        ServerThread s = server;
        if (s != null) s.reply(line);
    }

    private final class ServerThread extends Thread {
        private ServerSocket listener;
        private Socket client;
        private volatile boolean running = true;
        private VideoProxy proxy;
        /** Replies are written off the main thread (Android forbids network I/O there). */
        private final ExecutorService writer = Executors.newSingleThreadExecutor();

        ServerThread() {
            super("viewer-server");
        }

        @Override public void run() {
            try {
                listener = bindWithRetry();
                proxy = new VideoProxy(new VideoProxy.Requester() {
                    @Override public void request(int video, int request, long offset, int length) {
                        reply("READ " + video + " " + request + " " + offset + " " + length);
                    }
                });
                proxy.start();
                while (running) {
                    Socket socket = listener.accept();
                    synchronized (this) {
                        // A new connection replaces the old one (e.g. the phone reconnected).
                        if (client != null) try { client.close(); } catch (IOException ignored) {}
                        client = socket;
                    }
                    handle(socket);
                }
            } catch (IOException e) {
                // Closed by shutdown(), or the port is busy.
            }
        }

        /** A viewer that is just closing may still hold the port for a moment. */
        private ServerSocket bindWithRetry() throws IOException {
            for (int attempt = 0; ; attempt++) {
                ServerSocket socket = new ServerSocket();
                socket.setReuseAddress(true);
                try {
                    socket.bind(new InetSocketAddress(PORT));
                    return socket;
                } catch (IOException e) {
                    socket.close();
                    if (attempt >= 20 || !running) throw e;
                    try { Thread.sleep(250); } catch (InterruptedException ignored) {}
                }
            }
        }

        void shutdown() {
            running = false;
            writer.shutdown();
            if (proxy != null) proxy.close();
            try { if (listener != null) listener.close(); } catch (IOException ignored) {}
            synchronized (this) {
                try { if (client != null) client.close(); } catch (IOException ignored) {}
            }
        }

        void reply(final String line) {
            if (writer.isShutdown()) return;
            writer.execute(new Runnable() {
                @Override public void run() {
                    Socket socket;
                    synchronized (ServerThread.this) {
                        socket = client;
                    }
                    if (socket == null) return;
                    try {
                        OutputStream out = socket.getOutputStream();
                        out.write((line + "\n").getBytes("UTF-8"));
                        out.flush();
                    } catch (IOException ignored) {
                    }
                }
            });
        }

        private void handle(Socket socket) {
            try {
                socket.setTcpNoDelay(true);
                DataInputStream in = new DataInputStream(socket.getInputStream());
                String line;
                while ((line = readLine(in)) != null) {
                    command(line.trim(), in);
                }
            } catch (IOException ignored) {
            } finally {
                try { socket.close(); } catch (IOException ignored) {}
            }
        }

        private void command(String line, DataInputStream in) throws IOException {
            String[] f = line.split(" ", 3);
            String name = f[0];
            if (name.equals("HELLO")) {
                DisplayMetrics m = getResources().getDisplayMetrics();
                reply("VIEWER 1 " + Build.VERSION.SDK_INT + " " + Math.max(m.widthPixels, m.heightPixels)
                        + " " + Math.min(m.widthPixels, m.heightPixels) + " " + (hasHevc() ? 1 : 0));
            } else if (name.equals("PING")) {
                reply("PONG");
            } else if (name.equals("PHOTO")) {
                final int id = Integer.parseInt(f[1]);
                byte[] data = new byte[Integer.parseInt(f[2])];
                in.readFully(data);
                Bitmap bitmap = decode(data);
                if (bitmap == null) {
                    reply("PERR " + id);
                    return;
                }
                synchronized (pending) {
                    pending.put(id, bitmap);
                    // Keep memory bounded if the phone sends faster than it shows.
                    while (pending.size() > 4) {
                        Integer oldest = pending.keySet().iterator().next();
                        pending.remove(oldest).recycle();
                    }
                }
                reply("READY " + id);
            } else if (name.equals("SHOW")) {
                final int id = Integer.parseInt(f[1]);
                main.post(new Runnable() {
                    @Override public void run() {
                        showPhoto(id);
                        reply("SHOWN " + id);
                    }
                });
            } else if (name.equals("DATA")) {
                String[] d = line.split(" ");
                byte[] data = new byte[Integer.parseInt(d[2])];
                in.readFully(data);
                if (proxy != null) proxy.deliver(Integer.parseInt(d[1]), data);
            } else if (name.equals("VIDEO")) {
                String[] v = line.split(" ");
                final int id = Integer.parseInt(v[1]);
                if (proxy == null) return;
                final String url = proxy.url(id, Long.parseLong(v[2]), v.length > 3 ? v[3] : "video/mp4");
                main.post(new Runnable() {
                    @Override public void run() { playVideo(id, url); }
                });
            } else if (name.equals("PAUSE")) {
                main.post(new Runnable() {
                    @Override public void run() {
                        if (player != null && prepared) player.pause();
                        reportTime();
                    }
                });
            } else if (name.equals("RESUME")) {
                main.post(new Runnable() {
                    @Override public void run() {
                        if (player != null && prepared) player.start();
                        reportTime();
                    }
                });
            } else if (name.equals("SEEK")) {
                final int ms = Integer.parseInt(f[1]);
                main.post(new Runnable() {
                    @Override public void run() { if (player != null && prepared) player.seekTo(ms); }
                });
            } else if (name.equals("ZOOM")) {
                String[] z = line.split(" ");
                final int id = Integer.parseInt(z[1]);
                final float scale = Float.parseFloat(z[2]);
                final float u = Float.parseFloat(z[3]);
                final float v = Float.parseFloat(z[4]);
                main.post(new Runnable() {
                    @Override public void run() { setZoom(id, scale, u, v); }
                });
            } else if (name.equals("CLOSE")) {
                main.post(new Runnable() {
                    @Override public void run() { finish(); }
                });
            } else if (name.equals("CLEAR")) {
                main.post(new Runnable() {
                    @Override public void run() { clear(); }
                });
            }
        }
    }

    private Bitmap decode(byte[] data) {
        DisplayMetrics m = getResources().getDisplayMetrics();
        int max = Math.max(1920, Math.max(m.widthPixels, m.heightPixels));
        BitmapFactory.Options bounds = new BitmapFactory.Options();
        bounds.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(data, 0, data.length, bounds);
        BitmapFactory.Options options = new BitmapFactory.Options();
        options.inSampleSize = 1;
        while (Math.max(bounds.outWidth, bounds.outHeight) / (options.inSampleSize * 2) >= max) {
            options.inSampleSize *= 2;
        }
        try {
            return BitmapFactory.decodeByteArray(data, 0, data.length, options);
        } catch (OutOfMemoryError e) {
            options.inSampleSize *= 2;
            return BitmapFactory.decodeByteArray(data, 0, data.length, options);
        }
    }

    @SuppressWarnings("deprecation")
    private static boolean hasHevc() {
        try {
            for (int i = 0; i < MediaCodecList.getCodecCount(); i++) {
                MediaCodecInfo info = MediaCodecList.getCodecInfoAt(i);
                if (info.isEncoder()) continue;
                for (String type : info.getSupportedTypes()) {
                    if (type.equalsIgnoreCase("video/hevc")) return true;
                }
            }
        } catch (Throwable ignored) {
        }
        return false;
    }

    private static String readLine(DataInputStream in) throws IOException {
        StringBuilder sb = new StringBuilder();
        int c;
        while ((c = in.read()) != -1) {
            if (c == '\n') return sb.toString();
            sb.append((char) c);
        }
        return sb.length() > 0 ? sb.toString() : null;
    }
}
