package local.adbremote.android.model

import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import android.provider.MediaStore
import android.util.Size
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import local.adbremote.android.bridge.ViewerClient
import java.io.ByteArrayOutputStream

/** A photo or video in the phone's library. */
data class MediaItem(val uri: Uri, val isVideo: Boolean, val mime: String, val size: Long, val durationMs: Long)

object MediaLibrary {
    /** Photos and videos, newest first. */
    fun load(context: Context): List<MediaItem> {
        val collection = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
        val projection = arrayOf(
            MediaStore.Files.FileColumns._ID, MediaStore.Files.FileColumns.MEDIA_TYPE, MediaStore.Files.FileColumns.MIME_TYPE,
            MediaStore.Files.FileColumns.SIZE, MediaStore.Video.VideoColumns.DURATION,
        )
        val selection = "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (${MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE}, ${MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO})"
        val items = mutableListOf<MediaItem>()
        context.contentResolver.query(collection, projection, selection, null, "${MediaStore.Files.FileColumns.DATE_ADDED} DESC")?.use { c ->
            while (c.moveToNext()) {
                val id = c.getLong(0)
                val video = c.getInt(1) == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO
                val base = if (video) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                items.add(MediaItem(ContentUris.withAppendedId(base, id), video, c.getString(2) ?: "", c.getLong(3), c.getLong(4)))
            }
        }
        return items
    }

    fun thumbnail(context: Context, item: MediaItem, side: Int): Bitmap? =
        runCatching { context.contentResolver.loadThumbnail(item.uri, Size(side, side), null) }.getOrNull()

    /** The picture no larger than `side` on its long edge. */
    fun image(context: Context, item: MediaItem, side: Int): Bitmap? = runCatching {
        if (item.isVideo) return thumbnail(context, item, side)
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, item.uri)) { decoder, info, _ ->
            val w = info.size.width
            val h = info.size.height
            val scale = minOf(1f, side.toFloat() / maxOf(w, h))
            decoder.setTargetSize(maxOf(1, (w * scale).toInt()), maxOf(1, (h * scale).toInt()))
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
    }.getOrNull()
}

/**
 * Sends what's on screen in the phone's viewer to the TV (same behaviour as the iOS app):
 * photos are uploaded and shown when ready (or when Show is tapped); videos start playing
 * on the TV straight away and stream from the phone.
 */
class CastController(private val context: Context, val cast: CastModel, private val store: DeviceStore) {
    sealed class Status {
        data class Working(val text: String) : Status()
        data object Ready : Status()
        data object OnTV : Status()
        data class Playing(val paused: Boolean) : Status()
        data object Ended : Status()
        data class Failed(val message: String) : Status()
    }

    var autoShow = true
    var status by mutableStateOf<Status>(Status.Working("Connecting to the TV…"))
        private set
    private var item: MediaItem? = null
    private var currentID = 0
    private var readyID: Int? = null
    /** With Auto Show off, a prepared video waits here until Show is tapped. */
    private var readyVideo: Pair<Int, MediaItem>? = null
    val videoWaiting get() = readyVideo != null
    private var job: Job? = null

    init {
        cast.onEvent = ::handle
    }

    fun select(item: MediaItem) {
        this.item = item
        zoomState = Triple(1.0, 0.5, 0.5)
        job?.cancel()
        readyID = null
        readyVideo = null
        currentID = 0
        job = store.scope.launch { send(item) }
    }

    fun replay() {
        item?.let(::select)
    }

    fun showNow() {
        readyVideo?.let { (id, video) ->
            readyVideo = null
            status = Status.Working("Starting on the TV…")
            cast.playVideo(id, video.uri, video.size, video.mime.ifEmpty { "video/mp4" })
            return
        }
        readyID?.let { cast.show(it) }
    }

    fun togglePause() {
        val playing = status as? Status.Playing ?: return
        timeBase = videoPosition()
        timeBaseAt = now()
        ignoreTimeUntil = now() + 1000
        if (playing.paused) cast.resume() else cast.pause()
        status = Status.Playing(!playing.paused)
    }

    // MARK: Video position

    /** Last position the TV reported, and when; the position in between is estimated. */
    private var timeBase = 0.0
    private var timeBaseAt = now()
    var videoDuration by mutableStateOf(0.0)
        private set
    val videoPaused get() = (status as? Status.Playing)?.paused ?: true
    private var ignoreTimeUntil = 0L

    private fun now() = System.currentTimeMillis()

    fun videoPosition(): Double {
        val elapsed = if (videoPaused) 0.0 else (now() - timeBaseAt) / 1000.0
        val position = timeBase + maxOf(elapsed, 0.0)
        return if (videoDuration > 0) minOf(position, videoDuration) else position
    }

    fun seek(seconds: Double) {
        val target = seconds.coerceIn(0.0, maxOf(videoDuration - 0.5, 0.0))
        timeBase = target
        timeBaseAt = now()
        // Reports from before the seek would pull the scrubber back for a moment.
        ignoreTimeUntil = now() + 1000
        cast.seek(target)
    }

    private var lastScrubSeek = 0L
    private var scrubFlush: Job? = null

    /** Seeks while the scrubber is dragged: at most 4 times a second, always ending on the last spot. */
    fun scrub(seconds: Double) {
        scrubFlush?.cancel()
        val wait = 250 - (now() - lastScrubSeek)
        if (wait <= 0) {
            lastScrubSeek = now()
            seek(seconds)
        } else {
            scrubFlush = store.scope.launch {
                delay(wait)
                lastScrubSeek = now()
                seek(seconds)
            }
        }
    }

    fun skip(seconds: Double) = seek(videoPosition() + seconds)

    // MARK: Zoom

    /** Latest zoom from the phone; re-sent when a new photo appears on the TV. */
    private var zoomState = Triple(1.0, 0.5, 0.5)
    private var lastZoomSent = 0L
    private var zoomFlush: Job? = null

    /** Mirrors the phone's zoom on the TV, at most ~30 updates a second. */
    fun zoom(scale: Double, u: Double, v: Double) {
        val new = Triple(scale, u, v)
        if (new == zoomState) return
        zoomState = new
        val wait = 33 - (now() - lastZoomSent)
        if (wait <= 0) {
            sendZoom()
        } else if (zoomFlush?.isActive != true) {
            zoomFlush = store.scope.launch {
                delay(wait)
                sendZoom()
            }
        }
    }

    private fun sendZoom() {
        if (currentID == 0) return
        lastZoomSent = now()
        cast.zoom(currentID, zoomState.first, zoomState.second, zoomState.third)
    }

    fun closeTV() {
        job?.cancel()
        store.scope.launch { cast.closeViewer() }
    }

    fun clearTV() {
        job?.cancel()
        cast.clear()
        status = Status.Working("Cleared")
    }

    private suspend fun send(item: MediaItem) {
        if (cast.state != CastModel.State.Ready) status = Status.Working("Connecting to the TV…")
        if (!cast.prepare()) {
            (cast.state as? CastModel.State.Failed)?.let { status = Status.Failed(it.message) }
            return
        }
        val id = cast.newID()
        currentID = id
        if (item.isVideo) {
            if (autoShow) {
                status = Status.Working("Starting on the TV…")
                cast.playVideo(id, item.uri, item.size, item.mime.ifEmpty { "video/mp4" })
            } else {
                // Videos stream, so "ready" means ready to start; nothing plays until Show.
                readyVideo = id to item
                status = Status.Ready
            }
            return
        }
        status = Status.Working("Sending…")
        val side = cast.tv.longSide.coerceIn(1280, 1920)
        val jpeg = withContext(Dispatchers.IO) {
            val bitmap = MediaLibrary.image(context, item, side) ?: return@withContext null
            ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.JPEG, 85, it) }.toByteArray()
        }
        if (!kotlin.coroutines.coroutineContext.isActive) return
        if (jpeg == null) {
            status = Status.Failed("Couldn't load this photo")
            return
        }
        cast.sendPhoto(id, jpeg)
    }

    private fun handle(event: ViewerClient.Event) {
        when (event) {
            is ViewerClient.Event.Ready -> if (event.id == currentID) {
                readyID = event.id
                if (autoShow) cast.show(event.id) else status = Status.Ready
            }
            is ViewerClient.Event.Shown -> if (event.id == currentID) {
                status = Status.OnTV
                if (zoomState.first != 1.0) sendZoom()
            }
            is ViewerClient.Event.PhotoFailed -> if (event.id == currentID) status = Status.Failed("The TV couldn't open this photo")
            is ViewerClient.Event.Playing -> if (event.id == currentID) {
                status = Status.Playing(false)
                timeBase = 0.0
                timeBaseAt = now()
                videoDuration = 0.0
            }
            is ViewerClient.Event.Ended -> if (event.id == currentID) status = Status.Ended
            is ViewerClient.Event.VideoFailed -> if (event.id == currentID) {
                status = Status.Failed(if (item?.mime?.contains("hevc") == true || item?.mime?.contains("265") == true)
                    "The TV couldn't play this video (it may not support HEVC)" else "The TV couldn't play this video")
            }
            is ViewerClient.Event.Time -> if (event.id == currentID && status is Status.Playing) {
                videoDuration = event.duration
                if (now() < ignoreTimeUntil) return
                timeBase = event.position
                timeBaseAt = now()
                // Paused or resumed from the TV's own remote.
                if (event.playing == videoPaused) status = Status.Playing(!event.playing)
            }
            else -> {}
        }
    }
}
