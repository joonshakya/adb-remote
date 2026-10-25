package local.adbremote.android.model

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import android.view.Surface
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import local.adbremote.android.MainActivity
import local.adbremote.android.bridge.AdbConnection
import local.adbremote.android.bridge.AdbStream
import java.io.BufferedOutputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Mirrors this phone's screen and sound to the TV app's PhoneMirror receiver (port 7200):
 * the screen through the hardware H.264 encoder, the sound as 48 kHz PCM from apps that allow
 * capture. Runs as a foreground service until stopped here, on the TV (Back) or by the system.
 */
class MirrorService : Service() {
    companion object {
        const val PORT = 7200
        private const val TAG = "AdbRemote"
        private const val CHANNEL = "mirror"

        /** Name of the TV being mirrored to while running (for the UI). */
        var mirroringTo by mutableStateOf<String?>(null)
            private set
        var error by mutableStateOf<String?>(null)
        /** Whether sound is being sent too (needs the microphone permission and Android 10+). */
        var withSound by mutableStateOf(false)
            private set

        /** The ADB connection to the TV, for when its port can't be reached directly. */
        var adb: AdbConnection? = null

        fun start(context: Context, resultCode: Int, data: Intent, host: String, tvName: String, longSide: Int, adb: AdbConnection) {
            error = null
            this.adb = adb
            val intent = Intent(context, MirrorService::class.java)
                .putExtra("resultCode", resultCode).putExtra("data", data)
                .putExtra("host", host).putExtra("tv", tvName).putExtra("longSide", longSide)
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            context.startService(Intent(context, MirrorService::class.java).setAction("stop"))
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var encoder: MediaCodec? = null
    private var audio: AudioRecord? = null
    private var socket: Socket? = null
    private var tunnel: AdbStream? = null
    private var out: DataOutputStream? = null
    @Volatile private var running = false
    private var longSide = 1920
    private var width = 0
    private var height = 0
    private val startedAt = System.nanoTime()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "stop") {
            shutdown()
            return START_NOT_STICKY
        }
        if (running || intent == null) return START_NOT_STICKY
        val tv = intent.getStringExtra("tv") ?: "TV"
        // Must be in the foreground (as a media projection service) before using the projection.
        startForeground(1, notification(tv), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        val manager = getSystemService(MediaProjectionManager::class.java)
        @Suppress("DEPRECATION")
        val data = intent.getParcelableExtra<Intent>("data")
        val p = data?.let { manager.getMediaProjection(intent.getIntExtra("resultCode", 0), it) }
        if (p == null) {
            fail("Screen capture wasn't allowed")
            return START_NOT_STICKY
        }
        projection = p
        p.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                main.post { shutdown() }
            }
        }, main)
        // Rotation: re-encode at the new shape.
        getSystemService(DisplayManager::class.java).registerDisplayListener(displayListener, main)
        longSide = intent.getIntExtra("longSide", 1920).coerceIn(1280, 1920)
        running = true
        mirroringTo = tv
        val host = intent.getStringExtra("host") ?: return START_NOT_STICKY
        Thread({ connect(host) }, "mirror-connect").start()
        return START_NOT_STICKY
    }

    /** Wi-Fi straight to the TV when possible; otherwise through ADB (e.g. emulators behind NAT). */
    private fun connect(host: String) {
        val (stream, watch) = open(host) ?: return
        try {
            out = DataOutputStream(BufferedOutputStream(stream, 1 shl 16)).apply {
                write(byteArrayOf('A'.code.toByte(), 'D'.code.toByte(), 'B'.code.toByte(), 'M'.code.toByte(), 1))
                flush()
            }
        } catch (e: Exception) {
            main.post { fail("Couldn't reach the TV: ${e.message}") }
            return
        }
        main.post {
            if (!running) return@post
            startVideo()
            startSound()
        }
        // The TV closes the connection when it stops (Back on its remote).
        Thread({
            runCatching { watch() }
            main.post { shutdown() }
        }, "mirror-watch").start()
    }

    /** The connection's output, and a blocking call that returns when the TV hangs up. */
    private fun open(host: String): Pair<java.io.OutputStream, () -> Unit>? {
        try {
            val s = Socket()
            s.tcpNoDelay = true
            s.sendBufferSize = 1 shl 20
            s.connect(InetSocketAddress(host, PORT), 3000)
            socket = s
            Log.i(TAG, "mirroring over Wi-Fi")
            return s.getOutputStream() to { while (s.getInputStream().read() >= 0) { /* nothing is sent back */ } }
        } catch (e: Exception) {
            val pipe = try {
                AdbStream.open(adb ?: throw e, "tcp:$PORT")
            } catch (e2: Exception) {
                main.post { fail("Couldn't reach the TV: ${e.message}") }
                return null
            }
            tunnel = pipe
            Log.i(TAG, "mirroring through ADB")
            return AdbOutputStream(pipe) to { while (pipe.read() != null) { /* nothing is sent back */ } }
        }
    }

    /** Writes go out as ADB stream packets. */
    private class AdbOutputStream(private val pipe: AdbStream) : java.io.OutputStream() {
        override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)
        override fun write(b: ByteArray, off: Int, len: Int) {
            try {
                pipe.write(b.copyOfRange(off, off + len))
            } catch (e: Exception) {
                throw java.io.IOException(e.message)
            }
        }
    }

    // MARK: Video

    /** Screen size scaled so the long side fits the TV, rounded to even numbers for the encoder. */
    private fun captureSize(): Triple<Int, Int, Int> {
        val metrics = resources.displayMetrics
        val size = android.graphics.Point()
        @Suppress("DEPRECATION")
        getSystemService(DisplayManager::class.java).getDisplay(android.view.Display.DEFAULT_DISPLAY).getRealSize(size)
        val w = size.x
        val h = size.y
        val scale = minOf(1f, longSide.toFloat() / maxOf(w, h))
        return Triple((w * scale).toInt() and 1.inv(), (h * scale).toInt() and 1.inv(), metrics.densityDpi)
    }

    private fun startVideo() {
        val (w, h, dpi) = captureSize()
        width = w
        height = h
        val codec = newEncoder(w, h)
        val surface = codec.createInputSurface()
        codec.start()
        encoder = codec
        drain(codec)
        display = projection?.createVirtualDisplay("ADB Remote mirror", w, h, dpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, surface, null, main)
    }

    /** Rotation (or a size change): a new encoder at the new shape, the display redirected to it. */
    private fun resize() {
        if (!running || display == null) return
        val (w, h, dpi) = captureSize()
        if (w == width && h == height) return
        Log.i(TAG, "mirror resize ${w}x$h")
        width = w
        height = h
        val old = encoder
        val codec = newEncoder(w, h)
        val surface = codec.createInputSurface()
        codec.start()
        encoder = codec
        drain(codec)
        display?.resize(w, h, dpi)
        display?.surface = surface
        old?.let { runCatching { it.stop(); it.release() } }
    }

    private fun newEncoder(w: Int, h: Int): MediaCodec {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, 10_000_000)
            setInteger(MediaFormat.KEY_FRAME_RATE, 60)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
            // A still screen still sends pictures now and then, so the TV never waits long.
            setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 100_000)
            setInteger(MediaFormat.KEY_PRIORITY, 0)
            // Say which colours these are, so the TV shows greys as greys.
            setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
            setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT709)
            setInteger(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
        }
        return MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC).apply {
            configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        }
    }

    /** Sends each encoded picture as soon as it's ready. */
    private fun drain(codec: MediaCodec) {
        val w = width
        val h = height
        Thread({
            val info = MediaCodec.BufferInfo()
            try {
                while (running && encoder === codec) {
                    val index = codec.dequeueOutputBuffer(info, 50_000)
                    if (index < 0) continue
                    val buffer = codec.getOutputBuffer(index)!!
                    val bytes = ByteArray(info.size)
                    buffer.position(info.offset)
                    buffer.get(bytes)
                    codec.releaseOutputBuffer(index, false)
                    when {
                        info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0 -> {
                            val config = ByteArray(8 + bytes.size)
                            for (i in 0..3) {
                                config[i] = (w shr (24 - 8 * i)).toByte()
                                config[4 + i] = (h shr (24 - 8 * i)).toByte()
                            }
                            bytes.copyInto(config, 8)
                            send(1, config)
                        }
                        info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0 -> send(3, bytes)
                        else -> send(2, bytes)
                    }
                }
            } catch (e: Exception) {
                // Released on resize or stop.
            }
        }, "mirror-video").start()
    }

    // MARK: Sound

    private fun startSound() {
        val p = projection ?: return
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            withSound = false
            return
        }
        val config = AudioPlaybackCaptureConfiguration.Builder(p)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()
        val format = AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(48000)
            .setChannelMask(AudioFormat.CHANNEL_IN_STEREO).build()
        val record = try {
            AudioRecord.Builder().setAudioFormat(format).setAudioPlaybackCaptureConfig(config)
                .setBufferSizeInBytes(48000 * 4 / 5).build()
        } catch (e: Exception) {
            Log.w(TAG, "sound capture unavailable: ${e.message}")
            return
        }
        audio = record
        record.startRecording()
        withSound = true
        Thread({
            // 20 ms per packet.
            val buffer = ByteArray(3840)
            while (running && audio === record) {
                val n = record.read(buffer, 0, buffer.size)
                if (n > 0) send(4, buffer.copyOf(n))
            }
        }, "mirror-sound").start()
    }

    // MARK: Sending

    private val sendLock = Any()

    private fun send(type: Int, payload: ByteArray) {
        val o = out ?: return
        try {
            synchronized(sendLock) {
                o.writeByte(type)
                o.writeInt(payload.size)
                o.writeLong((System.nanoTime() - startedAt) / 1000)
                o.write(payload)
                o.flush()
            }
        } catch (e: Exception) {
            main.post { shutdown() }
        }
    }

    // MARK: Ending

    private fun fail(message: String) {
        error = message
        shutdown()
    }

    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) {}
        override fun onDisplayRemoved(displayId: Int) {}
        override fun onDisplayChanged(displayId: Int) {
            if (displayId == android.view.Display.DEFAULT_DISPLAY) resize()
        }
    }

    private fun shutdown() {
        getSystemService(DisplayManager::class.java).unregisterDisplayListener(displayListener)
        running = false
        mirroringTo = null
        withSound = false
        audio?.let { runCatching { it.stop(); it.release() } }
        audio = null
        display?.release()
        display = null
        encoder?.let { runCatching { it.stop(); it.release() } }
        encoder = null
        runCatching { socket?.close() }
        socket = null
        tunnel?.close()
        tunnel = null
        out = null
        projection?.stop()
        projection = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        if (running) shutdown()
        super.onDestroy()
    }

    private fun notification(tv: String): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Screen mirroring", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, MirrorService::class.java).setAction("stop"), PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_menu_upload)
            .setContentTitle("Mirroring to $tv")
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .setOngoing(true)
            .build()
    }
}
