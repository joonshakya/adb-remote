package local.adbremote.android.ui

import android.Manifest
import android.annotation.SuppressLint
import android.content.ClipboardManager
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.os.Build
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.Forward10
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay10
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import local.adbremote.android.bridge.AdbException
import local.adbremote.android.bridge.Links
import local.adbremote.android.model.CastController
import local.adbremote.android.model.CastModel
import local.adbremote.android.model.DeviceStore
import local.adbremote.android.model.MediaItem
import local.adbremote.android.model.MediaLibrary
import kotlin.math.max

/** Things to play on the TV: your photos and videos, YouTube, any link, or the whole screen. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlayScreen(store: DeviceStore, modifier: Modifier) {
    val modes = listOf("Photos", "YouTube", "Link", "Mirror")
    var mode by rememberSaveable { mutableStateOf("Photos") }
    LaunchedEffect(store.pendingLink) { if (store.pendingLink != null) mode = "Link" }
    Column(modifier.fillMaxSize()) {
        DeviceBar(store, "Play")
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) {
            modes.forEachIndexed { index, name ->
                SegmentedButton(selected = mode == name, onClick = { mode = name },
                    shape = SegmentedButtonDefaults.itemShape(index, modes.size)) { Text(name, maxLines = 1) }
            }
        }
        val session = store.selectedSession
        if (session == null || !session.isConnected) {
            NotConnected(store)
            return@Column
        }
        when (mode) {
            "Photos" -> session.castModel()?.let { PhotosPane(store, it) } ?: NotConnected(store)
            "YouTube" -> YouTubePane(store)
            "Link" -> LinkPane(store)
            else -> MirrorPane(store)
        }
    }
}

// MARK: Photos

private val mediaPermissions = if (Build.VERSION.SDK_INT >= 33)
    arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
else arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)

private fun hasMediaAccess(context: Context) =
    mediaPermissions.all { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED } ||
        (Build.VERSION.SDK_INT >= 34 &&
            context.checkSelfPermission(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) == PackageManager.PERMISSION_GRANTED)

@Composable
private fun PhotosPane(store: DeviceStore, cast: CastModel) {
    val context = LocalContext.current
    var allowed by remember { mutableStateOf(hasMediaAccess(context)) }
    var asked by rememberSaveable { mutableStateOf(false) }
    val request = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        asked = true
        allowed = hasMediaAccess(context)
    }
    LaunchedEffect(Unit) {
        if (!allowed && !asked) {
            request.launch(if (Build.VERSION.SDK_INT >= 34) mediaPermissions + Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED else mediaPermissions)
        }
    }
    if (!allowed) {
        Column(Modifier.fillMaxSize().padding(32.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
            Text("No access to photos", style = MaterialTheme.typography.titleMedium)
            Text("Allow ADB Remote to see your photos and videos to show them on the TV.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.size(12.dp))
            Button(onClick = { request.launch(mediaPermissions) }) { Text("Allow Access") }
        }
        return
    }
    val items by produceState<List<MediaItem>?>(null, allowed) { value = withContext(Dispatchers.IO) { MediaLibrary.load(context) } }
    var opened by remember { mutableStateOf<Int?>(null) }
    val list = items
    when {
        list == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        list.isEmpty() -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("No photos or videos") }
        else -> LazyVerticalGrid(GridCells.Adaptive(96.dp), Modifier.fillMaxSize(),
            horizontalArrangement = Arrangement.spacedBy(2.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            itemsIndexed(list, key = { _, item -> item.uri.toString() }) { index, item ->
                Thumbnail(item, Modifier.clickable { opened = index })
            }
        }
    }
    val index = opened
    if (list != null && index != null) {
        CastViewer(store, cast, list, index) { opened = null }
    }
}

@Composable
private fun Thumbnail(item: MediaItem, modifier: Modifier) {
    val context = LocalContext.current
    val bitmap by produceState<Bitmap?>(null, item.uri) {
        value = withContext(Dispatchers.IO) { MediaLibrary.thumbnail(context, item, 256) }
    }
    Box(modifier.aspectRatio(1f).background(MaterialTheme.colorScheme.surfaceVariant)
        .semantics { contentDescription = if (item.isVideo) "Video" else "Photo" }) {
        bitmap?.let { Image(it.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
        if (item.isVideo) {
            Text(formatTime(item.durationMs / 1000.0), Modifier.align(Alignment.BottomEnd).padding(4.dp),
                color = Color.White, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold)
        }
    }
}

/** Full-screen pager. Whatever is on screen is sent to the TV right away. */
@Composable
private fun CastViewer(store: DeviceStore, cast: CastModel, items: List<MediaItem>, start: Int, onClose: () -> Unit) {
    val context = LocalContext.current
    val controller = remember(cast) { CastController(context, cast, store) }
    var autoShow by rememberSaveable { mutableStateOf(true) }
    val pager = rememberPagerState(initialPage = start) { items.size }
    var zoomed by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    LaunchedEffect(pager) {
        snapshotFlow { pager.currentPage }.collect { controller.select(items[it]) }
    }
    LaunchedEffect(autoShow) {
        controller.autoShow = autoShow
        if (autoShow) controller.showNow()
    }
    val close = {
        controller.closeTV()
        onClose()
    }
    Dialog(onDismissRequest = close, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            HorizontalPager(pager, Modifier.fillMaxSize(), userScrollEnabled = !zoomed, beyondViewportPageCount = 1) { page ->
                ZoomablePage(items[page], isCurrent = page == pager.currentPage, onZoom = { scale, u, v ->
                    zoomed = scale > 1.01
                    controller.zoom(scale, u, v)
                })
            }
            Row(Modifier.fillMaxWidth().statusBarsPadding().padding(4.dp), verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = close) { Text("Done", color = Color.White) }
                Spacer(Modifier.weight(1f))
                Box {
                    IconButton(onClick = { menu = true }, Modifier.semantics { contentDescription = "Viewer options" }) {
                        Icon(Icons.Default.MoreVert, null, tint = Color.White)
                    }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(text = { Text("Show on TV Automatically") },
                            leadingIcon = { Checkbox(checked = autoShow, onCheckedChange = null) },
                            onClick = { autoShow = !autoShow; menu = false })
                        DropdownMenuItem(text = { Text("Clear the TV Screen") }, onClick = { controller.clearTV(); menu = false })
                    }
                }
            }
            CastBar(controller, Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 24.dp, start = 16.dp, end = 16.dp))
        }
    }
    DisposableEffect(controller) { onDispose { cast.onEvent = null } }
}

/**
 * Pinch / double-tap zoom. Reports (scale, u, v): the zoom and which point of the picture (0..1)
 * is in the middle of the screen, so the TV can show the same view.
 */
@Composable
private fun ZoomablePage(item: MediaItem, isCurrent: Boolean, onZoom: (Double, Double, Double) -> Unit) {
    val context = LocalContext.current
    val bitmap by produceState<Bitmap?>(null, item.uri) {
        val side = max(context.resources.displayMetrics.widthPixels, context.resources.displayMetrics.heightPixels)
        value = withContext(Dispatchers.IO) { MediaLibrary.image(context, item, side) }
    }
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    // Pages you swiped away from start unzoomed when you come back.
    LaunchedEffect(isCurrent) {
        if (!isCurrent) {
            scale = 1f
            offset = Offset.Zero
        }
    }
    BoxWithConstraints(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        val boxW = constraints.maxWidth.toFloat()
        val boxH = constraints.maxHeight.toFloat()
        val image = bitmap
        if (image == null) {
            CircularProgressIndicator(color = Color.White)
        } else {
            val fit = minOf(boxW / image.width, boxH / image.height)
            val fw = image.width * fit
            val fh = image.height * fit
            fun clampAndReport() {
                // Keep the picture covering the middle of the screen.
                val maxX = max(0f, (fw * scale - boxW) / 2)
                val maxY = max(0f, (fh * scale - boxH) / 2)
                offset = Offset(offset.x.coerceIn(-maxX, maxX), offset.y.coerceIn(-maxY, maxY))
                val u = (0.5 - offset.x / scale / fw).coerceIn(0.0, 1.0)
                val v = (0.5 - offset.y / scale / fh).coerceIn(0.0, 1.0)
                onZoom(scale.toDouble(), u, v)
            }
            Image(
                image.asImageBitmap(), null,
                Modifier.fillMaxSize()
                    .pointerInput(image) {
                        detectTapGestures(onDoubleTap = { tap ->
                            if (scale > 1f) {
                                scale = 1f
                                offset = Offset.Zero
                            } else {
                                scale = 2.5f
                                offset = (Offset(boxW / 2, boxH / 2) - tap) * scale
                            }
                            clampAndReport()
                        })
                    }
                    .pointerInput(image) {
                        // Pinch always; one-finger drag only while zoomed (else the pager swipes).
                        awaitEachGesture {
                            awaitFirstDown(requireUnconsumed = false)
                            do {
                                val event = awaitPointerEvent()
                                val zoom = event.calculateZoom()
                                val pan = event.calculatePan()
                                val pinching = event.changes.size > 1
                                if (pinching || scale > 1f) {
                                    scale = (scale * zoom).coerceIn(1f, 8f)
                                    offset += pan
                                    if (scale == 1f) offset = Offset.Zero
                                    clampAndReport()
                                    event.changes.forEach { if (it.positionChanged()) it.consume() }
                                }
                            } while (event.changes.any { it.pressed })
                        }
                    }
                    .graphicsLayer {
                        scaleX = scale
                        scaleY = scale
                        translationX = offset.x
                        translationY = offset.y
                    },
                contentScale = ContentScale.Fit,
            )
        }
        if (item.isVideo) Icon(Icons.Default.Tv, null, Modifier.size(44.dp), tint = Color.White.copy(alpha = 0.85f))
    }
}

/** Status and buttons at the bottom of the viewer. */
@Composable
private fun CastBar(controller: CastController, modifier: Modifier) {
    Row(
        modifier.widthIn(max = 520.dp).background(Color.Black.copy(alpha = 0.65f), RoundedCornerShape(24.dp))
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        val white = Color.White
        when (val status = controller.status) {
            is CastController.Status.Working -> {
                CircularProgressIndicator(Modifier.size(18.dp), color = white, strokeWidth = 2.dp)
                Text(status.text, color = white)
            }
            CastController.Status.Ready -> {
                Icon(Icons.Default.CheckCircle, null, tint = white)
                Text(if (controller.videoWaiting) "Ready to play" else "Ready on the TV", color = white)
                Button(onClick = { controller.showNow() }) { Text(if (controller.videoWaiting) "Play on TV" else "Show") }
            }
            CastController.Status.OnTV -> {
                Icon(Icons.Default.Tv, null, tint = Color(0xFF34C759))
                Text("On the TV", color = white)
            }
            is CastController.Status.Playing -> VideoControls(controller)
            CastController.Status.Ended -> {
                Icon(Icons.Default.CheckCircle, null, tint = white)
                Text("Finished", color = white)
                OutlinedButton(onClick = { controller.replay() }) { Text("Play Again", color = white) }
            }
            is CastController.Status.Failed -> {
                Icon(Icons.Default.Warning, null, tint = Color(0xFFFFCC00))
                Text(status.message, color = white, modifier = Modifier.weight(1f, fill = false), maxLines = 3)
                OutlinedButton(onClick = { controller.replay() }) { Text("Retry", color = white) }
            }
        }
    }
}

/** Play/pause, 10-second skips and a scrubber for the video playing on the TV. */
@Composable
private fun VideoControls(controller: CastController) {
    var tick by remember { mutableLongStateOf(0L) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(250)
            tick++
        }
    }
    /** While dragging, the scrubber shows the finger's time and the TV follows. */
    var scrubbing by remember { mutableStateOf<Double?>(null) }
    var lastScrub by remember { mutableLongStateOf(0L) }
    LaunchedEffect(lastScrub) {
        delay(700)
        scrubbing = null
    }
    @Suppress("UNUSED_EXPRESSION") tick
    val duration = max(controller.videoDuration, 0.1)
    val position = scrubbing ?: controller.videoPosition()
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(formatTime(position), color = Color.White, style = MaterialTheme.typography.labelMedium, modifier = Modifier.width(48.dp))
            Slider(
                value = minOf(position, duration).toFloat(),
                onValueChange = {
                    scrubbing = it.toDouble()
                    lastScrub = System.currentTimeMillis()
                    controller.scrub(it.toDouble())
                },
                valueRange = 0f..duration.toFloat(),
                enabled = controller.videoDuration > 0,
                colors = SliderDefaults.colors(thumbColor = Color.White, activeTrackColor = Color.White, inactiveTrackColor = Color.White.copy(alpha = 0.3f)),
                modifier = Modifier.weight(1f),
            )
            Text(formatTime(controller.videoDuration), color = Color.White, style = MaterialTheme.typography.labelMedium, modifier = Modifier.width(48.dp))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(28.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { controller.skip(-10.0) }, Modifier.semantics { contentDescription = "Back 10 Seconds" }) {
                Icon(Icons.Default.Replay10, null, tint = Color.White)
            }
            IconButton(onClick = { controller.togglePause() }, Modifier.semantics { contentDescription = if (controller.videoPaused) "Play" else "Pause" }) {
                Icon(if (controller.videoPaused) Icons.Default.PlayArrow else Icons.Default.Pause, null, tint = Color.White, modifier = Modifier.size(36.dp))
            }
            IconButton(onClick = { controller.skip(10.0) }, Modifier.semantics { contentDescription = "Forward 10 Seconds" }) {
                Icon(Icons.Default.Forward10, null, tint = Color.White)
            }
        }
    }
}

fun formatTime(seconds: Double): String {
    val total = max(seconds, 0.0).toInt()
    val h = total / 3600
    val m = total / 60 % 60
    val s = total % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}

// MARK: YouTube

/** m.youtube.com with a "Play on TV" button for the video you're on. */
@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun YouTubePane(store: DeviceStore) {
    val context = LocalContext.current
    var url by remember { mutableStateOf<String?>(null) }
    var canGoBack by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    var sending by remember { mutableStateOf(false) }
    // Kept across tab switches so you don't lose your place.
    val web = remember {
        store.youtubeWebView ?: WebView(context.applicationContext).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.mediaPlaybackRequiresUserGesture = true
            loadUrl("https://m.youtube.com")
        }.also { store.youtubeWebView = it }
    }
    DisposableEffect(web) {
        // YouTube is a single-page app: watch history updates rather than page loads.
        web.webViewClient = object : WebViewClient() {
            override fun doUpdateVisitedHistory(view: WebView, address: String?, isReload: Boolean) {
                url = address
                canGoBack = view.canGoBack()
            }
        }
        url = web.url
        canGoBack = web.canGoBack()
        onDispose { (web.parent as? android.view.ViewGroup)?.removeView(web) }
    }
    BackHandler(enabled = canGoBack) { web.goBack() }
    val watch = remember(url) { url?.let { Links.youtubeWatchURL(it) } }
    Box(Modifier.fillMaxSize()) {
        AndroidView(factory = { web }, modifier = Modifier.fillMaxSize())
        Column(Modifier.align(Alignment.BottomCenter).padding(bottom = 20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            message?.let {
                Text(it, Modifier.background(Color.Black.copy(alpha = 0.7f), RoundedCornerShape(12.dp)).padding(horizontal = 12.dp, vertical = 6.dp),
                    color = Color.White)
                Spacer(Modifier.size(8.dp))
            }
            if (watch != null) {
                ExtendedFloatingActionButton(
                    onClick = {
                        if (sending) return@ExtendedFloatingActionButton
                        web.evaluateJavascript("document.querySelectorAll('video').forEach(v => v.pause())", null)
                        sending = true
                        message = "Sending…"
                        store.scope.launch {
                            message = sendToTV(store, "youtube", watch) { message = it }
                            sending = false
                        }
                    },
                    icon = { Icon(Icons.Default.Tv, null) },
                    text = { Text("Play on TV") },
                )
            }
        }
    }
}

/** Opens a link (or types text) on the selected device; returns what happened. */
private suspend fun sendToTV(store: DeviceStore, kind: String, value: String, onStatus: (String) -> Unit): String {
    val adb = store.selectedSession?.connection ?: return "Not connected"
    return try {
        Links.open(adb, kind, value) { status -> store.scope.launch { onStatus(status) } }
    } catch (e: AdbException) {
        e.message ?: "Failed"
    }
}

// MARK: Link

/** Paste a link and send it. YouTube links open in the TV's YouTube app, others in its browser. */
@Composable
private fun LinkPane(store: DeviceStore) {
    val context = LocalContext.current
    var link by rememberSaveable { mutableStateOf(store.pendingLink ?: "") }
    var message by remember { mutableStateOf<String?>(null) }
    var sending by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val send = {
        sending = true
        message = "Sending…"
        val text = link.trim()
        store.scope.launch {
            val (kind, value) = classify(text)
            message = sendToTV(store, kind, value) { message = it }
            sending = false
        }
    }
    // A link shared to this app ("Send to TV") goes out right away.
    LaunchedEffect(store.pendingLink) {
        store.pendingLink?.let {
            link = it
            store.pendingLink = null
            send()
        }
    }
    Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        OutlinedTextField(link, { link = it }, Modifier.fillMaxWidth(), label = { Text("Paste a YouTube or web link") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (link.isEmpty()) OutlinedButton(onClick = {
                val clip = (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).primaryClip
                link = clip?.getItemAt(0)?.coerceToText(context)?.toString() ?: ""
            }) {
                Icon(Icons.Default.ContentPaste, null)
                Spacer(Modifier.width(6.dp))
                Text("Paste")
            }
            FilledTonalButton(enabled = link.isNotBlank() && !sending, onClick = { send() }) {
                Icon(Icons.AutoMirrored.Filled.Send, null)
                Spacer(Modifier.width(6.dp))
                Text("Send to TV")
            }
        }
        message?.let { Text(it) }
        Text("YouTube links open in the TV's YouTube app. Other links open in its browser; other text is typed into the TV. " +
            "You can also share from YouTube or Chrome and pick ADB Remote.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** First http(s) link in the text → ("youtube" | "web", url); otherwise ("text", text). */
private fun classify(text: String): Pair<String, String> {
    val url = Regex("https?://\\S+").find(text)?.value ?: return "text" to text
    Links.youtubeWatchURL(url)?.let { return "youtube" to it }
    return "web" to url
}
