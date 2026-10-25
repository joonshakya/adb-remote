package local.adbremote.viewer.airplay;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.SurfaceView;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.ImageView;

import com.google.android.exoplayer2.C;
import com.google.android.exoplayer2.ExoPlayer;
import com.google.android.exoplayer2.MediaItem;
import com.google.android.exoplayer2.PlaybackException;
import com.google.android.exoplayer2.Player;
import com.google.android.exoplayer2.util.MimeTypes;
import com.google.android.exoplayer2.video.VideoSize;

/**
 * Shows what the iPhone hands over with AirPlay: a video it gives the address of (played by
 * the TV itself, so the phone can lock), or a full-quality photo from the Photos app.
 * Videos play in ExoPlayer: TV chips' own players often skip HLS streams whose sound is a
 * separate track, which is how YouTube sends it. Back stops it.
 */
public final class MediaActivity extends Activity {
    private static final Handler main = new Handler(Looper.getMainLooper());
    private static MediaActivity shown;
    /** What to show when the screen opens (or right away if it is open). */
    private static String pendingUrl;
    private static double pendingStart;
    private static Bitmap pendingPhoto;

    // Playback state for the iPhone's progress bar (read from network threads).
    private static volatile double duration;
    private static volatile double position;
    private static volatile boolean playing;
    private static volatile boolean ready;
    private static volatile boolean ended;

    private FrameLayout root;
    private SurfaceView video;
    private ImageView photo;
    private ExoPlayer player;

    // MARK: Called from the AirPlay connection threads

    static void playVideo(Context context, String url, double startSeconds) {
        synchronized (MediaActivity.class) {
            pendingUrl = url;
            pendingStart = startSeconds;
            pendingPhoto = null;
            ready = false;
            ended = false;
            duration = 0;
            position = startSeconds;
        }
        open(context);
    }

    /** Opens the (black) video screen while a video is being prepared. */
    static void showLoading(Context context) {
        synchronized (MediaActivity.class) {
            pendingUrl = null;
            pendingPhoto = null;
            ready = false;
            ended = false;
        }
        open(context);
    }

    static void showPhoto(Context context, byte[] jpeg) {
        DisplayMetrics m = context.getResources().getDisplayMetrics();
        Bitmap bitmap = decode(jpeg, Math.max(m.widthPixels, m.heightPixels), Math.min(m.widthPixels, m.heightPixels));
        if (bitmap == null) return;
        synchronized (MediaActivity.class) {
            pendingPhoto = bitmap;
            pendingUrl = null;
        }
        open(context);
    }

    static void seek(final double seconds) {
        main.post(new Runnable() {
            @Override public void run() {
                MediaActivity a = shown;
                if (a != null && a.player != null) a.player.seekTo((long) (seconds * 1000));
                position = seconds;
            }
        });
    }

    static void setRate(final double rate) {
        main.post(new Runnable() {
            @Override public void run() {
                MediaActivity a = shown;
                if (a == null || a.player == null) return;
                a.player.setPlayWhenReady(rate > 0);
                playing = rate > 0;
            }
        });
    }

    static void stop() {
        main.post(new Runnable() {
            @Override public void run() {
                MediaActivity a = shown;
                if (a != null) a.finish();
            }
        });
    }

    static boolean isShowing() { return shown != null; }
    static boolean ended() { return ended; }
    static boolean ready() { return ready; }
    static double duration() { return duration; }
    static double position() { return position; }
    static boolean playing() { return playing; }

    private static void open(final Context context) {
        main.post(new Runnable() {
            @Override public void run() {
                MediaActivity a = shown;
                if (a != null) {
                    a.showPending();
                } else {
                    Intent intent = new Intent(context, MediaActivity.class);
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                    context.startActivity(intent);
                }
            }
        });
    }

    // MARK: Screen

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON | WindowManager.LayoutParams.FLAG_FULLSCREEN);
        root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        video = new SurfaceView(this);
        root.addView(video, new FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER));
        photo = new ImageView(this);
        photo.setScaleType(ImageView.ScaleType.FIT_CENTER);
        photo.setBackgroundColor(Color.BLACK);
        root.addView(photo, new FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT));
        setContentView(root);
        shown = this;
        showPending();
    }

    @Override
    protected void onDestroy() {
        if (shown == this) shown = null;
        releasePlayer();
        ended = true;
        super.onDestroy();
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if ((keyCode == KeyEvent.KEYCODE_DPAD_CENTER || keyCode == KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE) && player != null) {
            player.setPlayWhenReady(!player.getPlayWhenReady());
            return true;
        }
        return super.onKeyDown(keyCode, event);
    }

    private void showPending() {
        String url;
        double start;
        Bitmap bitmap;
        synchronized (MediaActivity.class) {
            url = pendingUrl;
            start = pendingStart;
            bitmap = pendingPhoto;
            pendingUrl = null;
            pendingPhoto = null;
        }
        if (bitmap != null) {
            releasePlayer();
            photo.setImageBitmap(bitmap);
            photo.setVisibility(View.VISIBLE);
        } else if (url != null) {
            photo.setVisibility(View.GONE);
            photo.setImageBitmap(null);
            startPlayer(url, start);
        }
    }

    private void startPlayer(String url, double start) {
        releasePlayer();
        Log.i(AirPlayServer.TAG, "playing " + url);
        final ExoPlayer p = new ExoPlayer.Builder(this).build();
        player = p;
        p.setVideoSurfaceView(video);
        p.addListener(new Player.Listener() {
            @Override public void onPlaybackStateChanged(int state) {
                if (player != p) return;
                if (state == Player.STATE_READY) {
                    ready = true;
                    main.removeCallbacks(tick);
                    main.post(tick);
                } else if (state == Player.STATE_ENDED) {
                    ended = true;
                    playing = false;
                    finish();
                }
            }

            @Override public void onIsPlayingChanged(boolean isPlaying) {
                playing = isPlaying;
            }

            @Override public void onVideoSizeChanged(VideoSize size) {
                fit(Math.round(size.width * size.pixelWidthHeightRatio), size.height);
            }

            @Override public void onPlayerError(PlaybackException error) {
                Log.w(AirPlayServer.TAG, "player error: " + error.getErrorCodeName() + " " + error.getMessage(), error);
                ended = true;
                finish();
            }
        });
        MediaItem.Builder item = new MediaItem.Builder().setUri(url);
        // HLS addresses don't always end in .m3u8 (query strings), so say so when it's clear.
        if (url.contains(".m3u8")) item.setMimeType(MimeTypes.APPLICATION_M3U8);
        p.setMediaItem(item.build(), start > 0 ? (long) (start * 1000) : C.TIME_UNSET);
        p.setPlayWhenReady(true);
        p.prepare();
    }

    /** Keeps the position fresh for the iPhone's progress bar (the player is only read on this thread). */
    private final Runnable tick = new Runnable() {
        @Override public void run() {
            ExoPlayer p = player;
            if (p == null) return;
            position = p.getCurrentPosition() / 1000.0;
            long d = p.getDuration();
            if (d != C.TIME_UNSET && d > 0) duration = d / 1000.0;
            main.postDelayed(this, 250);
        }
    };

    private void releasePlayer() {
        main.removeCallbacks(tick);
        if (player != null) {
            player.release();
            player = null;
        }
        ready = false;
        playing = false;
    }

    /** The video's shape, as large as fits, black around it. */
    private void fit(int w, int h) {
        if (w <= 0 || h <= 0 || root.getWidth() == 0) return;
        float scale = Math.min((float) root.getWidth() / w, (float) root.getHeight() / h);
        video.setLayoutParams(new FrameLayout.LayoutParams(Math.round(w * scale), Math.round(h * scale), Gravity.CENTER));
    }

    /** Decodes no larger than needed for the screen (phone photos can be 48 megapixels). */
    private static Bitmap decode(byte[] jpeg, int maxW, int maxH) {
        BitmapFactory.Options o = new BitmapFactory.Options();
        o.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(jpeg, 0, jpeg.length, o);
        if (o.outWidth <= 0 || o.outHeight <= 0) return null;
        float fit = Math.min((float) maxW / o.outWidth, (float) maxH / o.outHeight);
        int fitW = Math.round(o.outWidth * fit), fitH = Math.round(o.outHeight * fit);
        int sample = 1;
        while (o.outWidth / (sample * 2) >= fitW && o.outHeight / (sample * 2) >= fitH) sample *= 2;
        o = new BitmapFactory.Options();
        o.inSampleSize = sample;
        return BitmapFactory.decodeByteArray(jpeg, 0, jpeg.length, o);
    }
}
