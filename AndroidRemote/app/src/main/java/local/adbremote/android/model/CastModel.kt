package local.adbremote.android.model

import android.content.Context
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import local.adbremote.android.bridge.AdbConnection
import local.adbremote.android.bridge.AdbException
import local.adbremote.android.bridge.ViewerClient
import java.io.FileInputStream
import java.nio.ByteBuffer

/**
 * The "Photos from iPhone" viewer on the TV, as the Play tab uses it: connects on demand
 * (AdbKit installs/opens it), passes the TV's events on and serves video bytes it asks for.
 */
class CastModel(
    private val context: Context,
    private val adb: AdbConnection,
    private val host: String,
    private val sdk: Int,
    private val store: DeviceStore,
    private val log: (String) -> Unit,
) {
    sealed class State {
        data object Idle : State()
        data class Preparing(val message: String) : State()
        data object Ready : State()
        data class Failed(val message: String) : State()
    }

    var state by mutableStateOf<State>(State.Idle)
        private set
    var tv by mutableStateOf(ViewerClient.TV(0, 1920, false))
        private set
    /** Wi-Fi (fast) or through ADB. */
    var direct by mutableStateOf(false)
        private set
    /** Receives the TV's events on the main thread (set by the photo viewer). */
    var onEvent: ((ViewerClient.Event) -> Unit)? = null

    private var client: ViewerClient? = null
    private var connecting: CompletableDeferred<Boolean>? = null
    private var nextID = 1
    /** The video the TV may read from: id and where its bytes are. */
    @Volatile private var video: Pair<Int, Uri>? = null
    @Volatile private var videoFile: FileInputStream? = null

    fun newID(): Int = nextID++

    /** Makes sure the viewer is installed, open and connected. Safe to call repeatedly. */
    suspend fun prepare(): Boolean {
        if (client != null && state == State.Ready) return true
        connecting?.let { return it.await() }
        val done = CompletableDeferred<Boolean>()
        connecting = done
        val ok = try {
            state = State.Preparing("Checking the TV app")
            val c = ViewerClient.connect(adb, host, sdk, store.viewerApk, store.helperJar) { status ->
                store.scope.launch { if (state is State.Preparing) state = State.Preparing(status) }
            }
            client = c
            tv = c.tv
            direct = c.direct
            log("cast connected via ${if (c.direct) "Wi-Fi" else "ADB"}")
            state = State.Ready
            pump(c)
            true
        } catch (e: AdbException) {
            log("cast failed: ${e.message}")
            state = State.Failed("Couldn't open the viewer on the TV: ${e.message}")
            false
        }
        done.complete(ok)
        connecting = null
        return ok
    }

    /** Reads the TV's events on a background thread and hands them over on the main thread. */
    private fun pump(c: ViewerClient) {
        Thread({
            while (true) {
                val events = c.nextEvents()
                for (event in events) {
                    if (event is ViewerClient.Event.Read) {
                        serve(c, event)
                        continue
                    }
                    store.scope.launch { handle(c, event) }
                }
                if (events.any { it == ViewerClient.Event.Closed }) break
            }
        }, "cast-events").start()
    }

    private fun handle(c: ViewerClient, event: ViewerClient.Event) {
        if (event == ViewerClient.Event.Closed) {
            if (client === c) {
                client = null
                state = State.Idle
            }
            return
        }
        onEvent?.invoke(event)
    }

    /** Answers the TV's request for video bytes (runs on the event thread, which reads from the phone's storage). */
    private fun serve(c: ViewerClient, read: ViewerClient.Event.Read) {
        val current = video
        if (current == null || current.first != read.id) {
            c.sendData(read.request, ByteArray(0))
            return
        }
        val data = try {
            val stream = videoFile ?: context.contentResolver.openInputStream(current.second) as? FileInputStream
            videoFile = stream
            val channel = stream!!.channel
            val buffer = ByteBuffer.allocate(read.length)
            channel.position(read.offset)
            while (buffer.hasRemaining() && channel.read(buffer) > 0) { /* keep reading */ }
            buffer.array().copyOf(buffer.position())
        } catch (e: Exception) {
            log("video read failed: ${e.message}")
            ByteArray(0)
        }
        c.sendData(read.request, data)
    }

    // MARK: Commands

    fun sendPhoto(id: Int, jpeg: ByteArray) = client?.sendPhoto(id, jpeg)
    fun show(id: Int) = client?.show(id)
    fun pause() = client?.pause()
    fun resume() = client?.resume()
    fun seek(seconds: Double) = client?.seek(maxOf(0.0, seconds))
    fun zoom(id: Int, scale: Double, u: Double, v: Double) = client?.zoom(id, scale, u, v)

    fun clear() {
        stopVideo()
        client?.clear()
    }

    /** Starts playback on the TV right away; it reads the video from the phone as it plays. */
    fun playVideo(id: Int, uri: Uri, size: Long, mime: String) {
        stopVideo()
        video = id to uri
        client?.playVideo(id, size, mime)
    }

    private fun stopVideo() {
        video = null
        val file = videoFile
        videoFile = null
        runCatching { file?.close() }
    }

    /** Closes the viewer so the TV goes back to the app it was showing before. */
    suspend fun closeViewer() {
        stopVideo()
        val c = client
        if (c != null) {
            c.closeViewer()
            // Forget this connection now so opening something again starts the viewer afresh.
            client = null
            state = State.Idle
        } else {
            // Not connected (e.g. it dropped): stop the app over ADB instead.
            withContext(Dispatchers.IO) { runCatching { adb.shell("am force-stop local.adbremote.viewer") } }
        }
    }

    fun disconnect() {
        stopVideo()
        client?.disconnect()
        client = null
        state = State.Idle
    }
}
