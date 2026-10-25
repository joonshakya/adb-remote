package local.adbremote.viewer.airplay;

import android.annotation.TargetApi;
import android.graphics.SurfaceTexture;
import android.opengl.EGL14;
import android.opengl.EGLConfig;
import android.opengl.EGLContext;
import android.opengl.EGLDisplay;
import android.opengl.EGLSurface;
import android.opengl.GLES11Ext;
import android.opengl.GLES20;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Log;
import android.view.Surface;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.util.concurrent.CountDownLatch;

/**
 * Draws decoded video with our own YUV to RGB conversion. Some TVs' display hardware
 * assumes video uses the 16-235 range; the iPhone's mirroring uses the full 0-255 range,
 * so light greys clip to white and dark greys to black. Reading the raw YUV values
 * (GL_EXT_YUV_target) and converting them here keeps every shade.
 */
@TargetApi(21)
final class YuvRenderer implements SurfaceTexture.OnFrameAvailableListener {
    private static final int EGL_OPENGL_ES3_BIT = 0x40;

    private static final String VERTEX =
            "#version 300 es\n"
            + "in vec2 position;\n"
            + "uniform mat4 transform;\n"
            + "out vec2 uv;\n"
            + "void main() {\n"
            + "  uv = (transform * vec4(position * 0.5 + 0.5, 0.0, 1.0)).xy;\n"
            + "  gl_Position = vec4(position, 0.0, 1.0);\n"
            + "}\n";

    private static final String FRAGMENT =
            "#version 300 es\n"
            + "#extension GL_EXT_YUV_target : require\n"
            + "precision highp float;\n"
            + "uniform __samplerExternal2DY2YEXT video;\n"
            + "uniform bool fullRange;\n"
            + "uniform bool bt709;\n"
            + "in vec2 uv;\n"
            + "out vec4 color;\n"
            + "void main() {\n"
            + "  vec3 yuv = texture(video, uv).rgb;\n"
            + "  float y = yuv.r;\n"
            + "  float u = yuv.g - 0.5;\n"
            + "  float v = yuv.b - 0.5;\n"
            + "  if (!fullRange) {\n"
            + "    y = (y - 16.0 / 255.0) * (255.0 / 219.0);\n"
            + "    u *= 255.0 / 224.0;\n"
            + "    v *= 255.0 / 224.0;\n"
            + "  }\n"
            + "  vec3 rgb = bt709\n"
            + "    ? vec3(y + 1.5748 * v, y - 0.1873 * u - 0.4681 * v, y + 1.8556 * u)\n"
            + "    : vec3(y + 1.402 * v, y - 0.344136 * u - 0.714136 * v, y + 1.772 * u);\n"
            + "  color = vec4(clamp(rgb, 0.0, 1.0), 1.0);\n"
            + "}\n";

    private final HandlerThread thread = new HandlerThread("airplay-gl");
    private Handler handler;
    private EGLDisplay display = EGL14.EGL_NO_DISPLAY;
    private EGLContext context = EGL14.EGL_NO_CONTEXT;
    private EGLSurface window = EGL14.EGL_NO_SURFACE;
    private int program;
    private int texture;
    private SurfaceTexture surfaceTexture;
    private Surface decoderSurface;
    private final float[] transform = new float[16];
    private volatile boolean fullRange = true;
    private volatile boolean bt709 = true;
    private volatile int videoWidth, videoHeight;

    /** Sets up on the given output; null when this device can't do it (use the plain path then). */
    static YuvRenderer create(final Surface output) {
        final YuvRenderer r = new YuvRenderer();
        r.thread.start();
        r.handler = new Handler(r.thread.getLooper());
        final boolean[] ok = {false};
        final CountDownLatch done = new CountDownLatch(1);
        r.handler.post(new Runnable() {
            @Override public void run() {
                try {
                    ok[0] = r.setUp(output);
                } catch (RuntimeException e) {
                    Log.w(AirPlayServer.TAG, "GL setup failed: " + e);
                }
                done.countDown();
            }
        });
        try {
            done.await();
        } catch (InterruptedException ignored) {
        }
        if (!ok[0]) {
            r.release();
            return null;
        }
        return r;
    }

    /** Where the decoder should draw. */
    Surface decoderSurface() { return decoderSurface; }

    void setColour(boolean fullRange, boolean bt709) {
        this.fullRange = fullRange;
        this.bt709 = bt709;
    }

    /** The picture is fitted into the screen with this shape, black around it. */
    void setVideoSize(int width, int height) {
        videoWidth = width;
        videoHeight = height;
    }

    /**
     * A fresh target for a new decoder. Some TV decoders show nothing when a new decoder
     * takes over an old target, so each decoder gets its own.
     */
    Surface newDecoderSurface() {
        final CountDownLatch done = new CountDownLatch(1);
        handler.post(new Runnable() {
            @Override public void run() {
                if (decoderSurface != null) decoderSurface.release();
                if (surfaceTexture != null) surfaceTexture.release();
                surfaceTexture = new SurfaceTexture(texture);
                surfaceTexture.setOnFrameAvailableListener(YuvRenderer.this, handler);
                decoderSurface = new Surface(surfaceTexture);
                done.countDown();
            }
        });
        try {
            done.await();
        } catch (InterruptedException ignored) {
        }
        return decoderSurface;
    }

    void release() {
        handler.post(new Runnable() {
            @Override public void run() {
                if (decoderSurface != null) decoderSurface.release();
                if (surfaceTexture != null) surfaceTexture.release();
                if (display != EGL14.EGL_NO_DISPLAY) {
                    EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT);
                    if (window != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, window);
                    if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context);
                    EGL14.eglTerminate(display);
                }
                thread.quit();
            }
        });
    }

    private boolean setUp(Surface output) {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
        int[] version = new int[2];
        if (!EGL14.eglInitialize(display, version, 0, version, 1)) return false;
        int[] attributes = {
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL14.EGL_NONE};
        EGLConfig[] configs = new EGLConfig[1];
        int[] count = new int[1];
        if (!EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, count, 0) || count[0] == 0) return false;
        context = EGL14.eglCreateContext(display, configs[0], EGL14.EGL_NO_CONTEXT,
                new int[] {EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE}, 0);
        if (context == EGL14.EGL_NO_CONTEXT) return false;
        window = EGL14.eglCreateWindowSurface(display, configs[0], output, new int[] {EGL14.EGL_NONE}, 0);
        if (window == EGL14.EGL_NO_SURFACE) return false;
        if (!EGL14.eglMakeCurrent(display, window, window, context)) return false;
        String extensions = GLES20.glGetString(GLES20.GL_EXTENSIONS);
        if (extensions == null || !extensions.contains("GL_EXT_YUV_target")) {
            Log.i(AirPlayServer.TAG, "no GL_EXT_YUV_target; drawing video directly");
            return false;
        }
        program = link(VERTEX, FRAGMENT);
        if (program == 0) return false;

        int[] t = new int[1];
        GLES20.glGenTextures(1, t, 0);
        texture = t[0];
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture);
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);
        surfaceTexture = new SurfaceTexture(texture);
        surfaceTexture.setOnFrameAvailableListener(this, handler);
        decoderSurface = new Surface(surfaceTexture);

        float[] quad = {-1, -1, 1, -1, -1, 1, 1, 1};
        FloatBuffer vertices = ByteBuffer.allocateDirect(quad.length * 4).order(ByteOrder.nativeOrder()).asFloatBuffer();
        vertices.put(quad).position(0);
        int position = GLES20.glGetAttribLocation(program, "position");
        GLES20.glEnableVertexAttribArray(position);
        GLES20.glVertexAttribPointer(position, 2, GLES20.GL_FLOAT, false, 0, vertices);
        GLES20.glUseProgram(program);
        GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "video"), 0);
        Log.i(AirPlayServer.TAG, "drawing video through GL (own colour conversion)");
        return true;
    }

    @Override
    public void onFrameAvailable(SurfaceTexture st) {
        if (window == EGL14.EGL_NO_SURFACE) return;
        st.updateTexImage();
        st.getTransformMatrix(transform);
        int[] size = new int[2];
        EGL14.eglQuerySurface(display, window, EGL14.EGL_WIDTH, size, 0);
        EGL14.eglQuerySurface(display, window, EGL14.EGL_HEIGHT, size, 1);
        GLES20.glViewport(0, 0, size[0], size[1]);
        GLES20.glClearColor(0, 0, 0, 1);
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
        int w = size[0], h = size[1];
        if (videoWidth > 0 && videoHeight > 0) {
            float scale = Math.min((float) size[0] / videoWidth, (float) size[1] / videoHeight);
            w = Math.round(videoWidth * scale);
            h = Math.round(videoHeight * scale);
        }
        GLES20.glViewport((size[0] - w) / 2, (size[1] - h) / 2, w, h);
        GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(program, "transform"), 1, false, transform, 0);
        GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "fullRange"), fullRange ? 1 : 0);
        GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "bt709"), bt709 ? 1 : 0);
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture);
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
        EGL14.eglSwapBuffers(display, window);
    }

    private static int link(String vertex, String fragment) {
        int vs = compile(GLES20.GL_VERTEX_SHADER, vertex);
        int fs = compile(GLES20.GL_FRAGMENT_SHADER, fragment);
        if (vs == 0 || fs == 0) return 0;
        int p = GLES20.glCreateProgram();
        GLES20.glAttachShader(p, vs);
        GLES20.glAttachShader(p, fs);
        GLES20.glLinkProgram(p);
        int[] ok = new int[1];
        GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, ok, 0);
        if (ok[0] == 0) {
            Log.w(AirPlayServer.TAG, "GL link failed: " + GLES20.glGetProgramInfoLog(p));
            return 0;
        }
        return p;
    }

    private static int compile(int type, String source) {
        int s = GLES20.glCreateShader(type);
        GLES20.glShaderSource(s, source);
        GLES20.glCompileShader(s);
        int[] ok = new int[1];
        GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0);
        if (ok[0] == 0) {
            Log.w(AirPlayServer.TAG, "GL compile failed: " + GLES20.glGetShaderInfoLog(s));
            return 0;
        }
        return s;
    }
}
