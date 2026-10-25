package local.adbremote.android.model

import android.media.MediaCodec
import android.media.MediaFormat
import android.util.Log
import android.view.Surface
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import local.adbremote.android.bridge.AdbConnection
import local.adbremote.android.bridge.AdbException
import local.adbremote.android.bridge.ScreenSession
import java.nio.ByteBuffer

/**
 * Live view of a device's screen: scrcpy streams H.264, MediaCodec draws it on the given
 * Surface, and touches go back through scrcpy's control channel. Stopped when the view goes.
 */
class ScreenModel(private val adb: AdbConnection, private val store: DeviceStore) {
    var videoWidth by mutableStateOf(0)
        private set
    var videoHeight by mutableStateOf(0)
        private set
    var error by mutableStateOf<String?>(null)
        private set
    var isRunning by mutableStateOf(false)
        private set

    private var session: ScreenSession? = null
    private var startJob: Job? = null
    private var reader: Thread? = null
    private var surface: Surface? = null
    /** Bumped by start/stop so a slow start that was stopped meanwhile cleans up after itself. */
    @Volatile private var generation = 0
    private val touches = Channel<suspend (ScreenSession) -> Unit>(Channel.UNLIMITED)

    init {
        store.scope.launch {
            for (touch in touches) {
                val s = session ?: continue
                try {
                    touch(s)
                } catch (e: AdbException) {
                    Log.w("AdbRemote", "touch failed: ${e.message}")
                }
            }
        }
    }

    fun start(surface: Surface) {
        stop()
        this.surface = surface
        val mine = ++generation
        error = null
        isRunning = true
        startJob = store.scope.launch {
            try {
                val s = ScreenSession.start(adb, store.scrcpyServer, maxSize = 1600, bitRate = 8_000_000, maxFps = 60)
                if (generation != mine) {
                    s.close()
                    return@launch
                }
                session = s
                reader = Thread({ decode(s, surface, mine) }, "screen-video").also { it.start() }
            } catch (e: AdbException) {
                if (generation == mine) {
                    error = e.message
                    isRunning = false
                }
            }
        }
    }

    fun stop() {
        generation++
        startJob?.cancel()
        startJob = null
        session?.close()
        session = null
        reader?.interrupt()
        reader = null
        isRunning = false
    }

    fun close() {
        stop()
        touches.close()
    }

    /** Reads video events and feeds the decoder; runs on its own thread until the session ends. */
    private fun decode(s: ScreenSession, surface: Surface, mine: Int) {
        var codec: MediaCodec? = null
        var width = 0
        var height = 0
        val info = MediaCodec.BufferInfo()
        try {
            while (generation == mine) {
                when (val event = s.next()) {
                    is ScreenSession.Event.Size -> {
                        width = event.width
                        height = event.height
                        store.scope.launch {
                            videoWidth = event.width
                            videoHeight = event.height
                            store.screenIsWide = event.width >= event.height
                        }
                    }
                    is ScreenSession.Event.Config -> {
                        // New size or new stream parameters: start a fresh decoder with them.
                        codec?.let { runCatching { it.stop(); it.release() } }
                        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
                        format.setByteBuffer("csd-0", ByteBuffer.wrap(event.data))
                        codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC).apply {
                            configure(format, surface, null, 0)
                            start()
                        }
                    }
                    is ScreenSession.Event.Frame -> {
                        val c = codec ?: continue
                        val index = c.dequeueInputBuffer(100_000)
                        if (index >= 0) {
                            c.getInputBuffer(index)!!.apply { clear(); put(event.data) }
                            c.queueInputBuffer(index, 0, event.data.size, event.pts, 0)
                        }
                        while (true) {
                            val out = c.dequeueOutputBuffer(info, 0)
                            if (out >= 0) c.releaseOutputBuffer(out, true) else if (out == MediaCodec.INFO_TRY_AGAIN_LATER) break
                        }
                    }
                    ScreenSession.Event.End -> break
                }
            }
        } catch (e: Exception) {
            if (generation == mine) {
                Log.w("AdbRemote", "screen video stopped: ${e.message}")
                store.scope.launch { if (generation == mine) error = e.message }
            }
        } finally {
            codec?.let { runCatching { it.stop(); it.release() } }
            store.scope.launch { if (generation == mine) isRunning = false }
        }
    }

    /** Touch in video pixels (scrcpy maps them to the device screen). */
    fun touch(action: Int, x: Int, y: Int) {
        val w = videoWidth
        val h = videoHeight
        if (w == 0 || h == 0) return
        touches.trySend { it.touch(action, x.coerceIn(0, w - 1), y.coerceIn(0, h - 1), w, h) }
    }

    fun key(keycode: Int) {
        touches.trySend { it.key(keycode) }
    }
}
