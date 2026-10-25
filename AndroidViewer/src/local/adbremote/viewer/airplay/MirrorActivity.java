package local.adbremote.viewer.airplay;

import android.app.Activity;
import android.graphics.Color;
import android.media.MediaCodec;
import android.media.MediaFormat;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.WindowManager;
import android.widget.FrameLayout;

import java.nio.ByteBuffer;

/**
 * Shows the iPhone's (AirPlay) or Android phone's (PhoneMirror) screen. The TV's hardware decoder draws straight onto a SurfaceView,
 * which keeps colours as the iPhone sent them and adds no copies (lowest delay).
 * Back stops mirroring.
 */
public final class MirrorActivity extends Activity implements SurfaceHolder.Callback, MirrorStream.Sink {
    private static MirrorActivity shown;

    private FrameLayout root;
    private SurfaceView view;
    private Surface surface;
    private YuvRenderer renderer;
    /** Repeated SPS and PPS, sent ahead of the next picture. */
    private byte[] inlineConfig;
    private MediaCodec codec;
    private final Object lock = new Object();
    private int videoWidth, videoHeight;
    private volatile boolean draining;

    /** Closes the screen when mirroring ends. */
    static void close() {
        final MirrorActivity activity = shown;
        if (activity != null) {
            activity.runOnUiThread(new Runnable() {
                @Override public void run() { activity.finish(); }
            });
        }
    }

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                | WindowManager.LayoutParams.FLAG_FULLSCREEN);
        root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        view = new SurfaceView(this);
        view.getHolder().addCallback(this);
        root.addView(view, new FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER));
        setContentView(root);
        shown = this;
    }

    @Override
    protected void onDestroy() {
        if (shown == this) shown = null;
        super.onDestroy();
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_BACK) {
            AirPlayService.stopMirroring();
            finish();
            return true;
        }
        return super.onKeyDown(keyCode, event);
    }

    // MARK: Surface

    @Override public void surfaceCreated(SurfaceHolder holder) {
        // Our own colour conversion when the GPU allows it; otherwise the decoder draws directly.
        YuvRenderer r = Build.VERSION.SDK_INT >= 21 ? YuvRenderer.create(holder.getSurface()) : null;
        synchronized (lock) {
            renderer = r;
            surface = r != null ? r.decoderSurface() : holder.getSurface();
        }
        MirrorSource stream = AirPlayService.currentStream();
        if (stream != null) stream.setSink(this);
    }

    @Override public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {}

    @Override public void surfaceDestroyed(SurfaceHolder holder) {
        MirrorSource stream = AirPlayService.currentStream();
        if (stream != null) stream.setSink(null);
        synchronized (lock) {
            releaseCodec();
            surface = null;
            if (renderer != null) {
                renderer.release();
                renderer = null;
            }
        }
    }

    // MARK: Decoding (called on the stream's thread)

    @Override
    public void configure(byte[] sps, byte[] pps, final int width, final int height) {
        boolean resized = width != videoWidth || height != videoHeight;
        synchronized (lock) {
            if (surface == null) return;
            if (codec != null && !resized) {
                // The iPhone resends its settings after sleeping or switching apps. Some TV
                // decoders show nothing once recreated, so these go in with the next picture.
                inlineConfig = AirPlayServer.concat(sps, pps);
            } else {
                // New picture size (rotation): a new decoder, on a new target when drawing through GL.
                releaseCodec();
                if (renderer != null) {
                    surface = renderer.newDecoderSurface();
                    renderer.setVideoSize(width, height);
                }
                startCodec(sps, pps, width, height);
            }
        }
        if (width > 0 && height > 0 && resized) {
            videoWidth = width;
            videoHeight = height;
            // Without GL the video area itself takes the picture's shape.
            if (renderer == null) {
                runOnUiThread(new Runnable() {
                    @Override public void run() { fit(); }
                });
            }
        }
    }

    private void startCodec(byte[] sps, byte[] pps, int width, int height) {
        try {
            MediaFormat format = MediaFormat.createVideoFormat("video/avc", Math.max(width, 16), Math.max(height, 16));
            format.setByteBuffer("csd-0", ByteBuffer.wrap(sps));
            format.setByteBuffer("csd-1", ByteBuffer.wrap(pps));
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 2 * 1024 * 1024);
            // The iPhone sends full-range (0-255) video. Display hardware that assumes the usual
            // 16-235 range stretches it: light greys turn white and dark greys black.
            Sps info = Sps.parse(sps);
            boolean full = !(info.hasSignalType && !info.fullRange);
            if (renderer != null) renderer.setColour(full, info.matrix != 5 && info.matrix != 6);
            Log.i(AirPlayServer.TAG, "video colour: signal=" + info.hasSignalType + " full=" + info.fullRange + " matrix=" + info.matrix);
            if (Build.VERSION.SDK_INT >= 24) {
                format.setInteger(MediaFormat.KEY_COLOR_RANGE, full ? MediaFormat.COLOR_RANGE_FULL : MediaFormat.COLOR_RANGE_LIMITED);
                format.setInteger(MediaFormat.KEY_COLOR_STANDARD, info.matrix == 5 || info.matrix == 6
                        ? MediaFormat.COLOR_STANDARD_BT601_NTSC : MediaFormat.COLOR_STANDARD_BT709);
                format.setInteger(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_SDR_VIDEO);
            }
            MediaCodec c = MediaCodec.createDecoderByType("video/avc");
            c.configure(format, surface, null, 0);
            c.start();
            codec = c;
            startDraining(c);
        } catch (Exception e) {
            Log.w(AirPlayServer.TAG, "decoder failed: " + e);
        }
    }

    @Override
    @SuppressWarnings("deprecation")
    public void frame(byte[] annexB, boolean keyFrame) {
        synchronized (lock) {
            MediaCodec c = codec;
            if (c == null) return;
            try {
                int index = c.dequeueInputBuffer(50000);
                if (index < 0) return; // decoder is behind: drop rather than add delay
                byte[] data = inlineConfig != null ? AirPlayServer.concat(inlineConfig, annexB) : annexB;
                ByteBuffer buffer = c.getInputBuffers()[index];
                buffer.clear();
                if (data.length > buffer.capacity()) {
                    c.queueInputBuffer(index, 0, 0, 0, 0);
                    return;
                }
                buffer.put(data);
                c.queueInputBuffer(index, 0, data.length, System.nanoTime() / 1000, 0);
                inlineConfig = null;
            } catch (Exception e) {
                Log.w(AirPlayServer.TAG, "decode failed: " + e);
            }
        }
    }

    /** Shows each decoded picture as soon as it is ready. */
    private void startDraining(final MediaCodec c) {
        draining = true;
        new Thread("airplay-video-out") {
            @Override public void run() {
                MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
                while (draining && codec == c) {
                    try {
                        int index = c.dequeueOutputBuffer(info, 20000);
                        if (index >= 0) {
                            c.releaseOutputBuffer(index, true);
                        } else if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                            Log.i(AirPlayServer.TAG, "decoder output: " + c.getOutputFormat());
                        }
                    } catch (Exception e) {
                        return; // released
                    }
                }
            }
        }.start();
    }

    private void releaseCodec() {
        MediaCodec c = codec;
        codec = null;
        inlineConfig = null;
        draining = false;
        if (c == null) return;
        try { c.stop(); } catch (Exception ignored) {}
        try { c.release(); } catch (Exception ignored) {}
    }

    /** Largest picture with the iPhone's shape, centred; black around it. */
    private void fit() {
        int w = root.getWidth(), h = root.getHeight();
        if (videoWidth == 0 || videoHeight == 0) return;
        if (w == 0 || h == 0) {
            root.post(new Runnable() {
                @Override public void run() { fit(); }
            });
            return;
        }
        float scale = Math.min((float) w / videoWidth, (float) h / videoHeight);
        FrameLayout.LayoutParams params = new FrameLayout.LayoutParams(
                Math.round(videoWidth * scale), Math.round(videoHeight * scale), Gravity.CENTER);
        view.setLayoutParams(params);
    }
}
