package local.adbremote.android.ui

import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.ViewCarousel
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import local.adbremote.android.bridge.Keycode
import local.adbremote.android.bridge.ScreenSession
import local.adbremote.android.model.DeviceStore
import local.adbremote.android.model.ScreenModel

@Composable
fun ScreenScreen(store: DeviceStore, modifier: Modifier) {
    Column(modifier.fillMaxSize()) {
        val session = store.selectedSession
        val connection = session?.connection
        if (session == null || connection == null || !session.isConnected) {
            NotConnected(store)
            return@Column
        }
        // One model per connection; stopped (scrcpy killed on the device) when this tab goes.
        val model = remember(connection) { ScreenModel(connection, store) }
        DisposableEffect(model) { onDispose { model.close() } }

        BoxWithConstraints(Modifier.weight(1f).fillMaxWidth().background(Color.Black), contentAlignment = Alignment.Center) {
            val w = model.videoWidth
            val h = model.videoHeight
            val density = LocalDensity.current
            // Largest box with the video's shape that fits.
            val boxModifier = if (w > 0 && h > 0) {
                val scale = minOf(constraints.maxWidth.toFloat() / w, constraints.maxHeight.toFloat() / h)
                with(density) { Modifier.size((w * scale).toDp(), (h * scale).toDp()) }
            } else Modifier.fillMaxSize()
            Box(boxModifier.semantics { contentDescription = "Device screen" }.pointerInput(model, w, h) {
                awaitEachGesture {
                    fun send(action: Int, x: Float, y: Float) {
                        if (size.width == 0 || size.height == 0) return
                        model.touch(action, (x / size.width * w).toInt(), (y / size.height * h).toInt())
                    }
                    val down = awaitFirstDown()
                    send(ScreenSession.Touch.DOWN, down.position.x, down.position.y)
                    var last = down.position
                    while (true) {
                        val event = awaitPointerEvent()
                        val change = event.changes.firstOrNull { it.id == down.id } ?: break
                        if (!change.pressed) {
                            send(ScreenSession.Touch.UP, change.position.x, change.position.y)
                            break
                        }
                        if (change.positionChange() != androidx.compose.ui.geometry.Offset.Zero) {
                            last = change.position
                            send(ScreenSession.Touch.MOVE, last.x, last.y)
                        }
                        change.consume()
                    }
                }
            }) {
                AndroidView(
                    factory = { context ->
                        SurfaceView(context).apply {
                            holder.addCallback(object : SurfaceHolder.Callback {
                                override fun surfaceCreated(holder: SurfaceHolder) = model.start(holder.surface)
                                override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
                                override fun surfaceDestroyed(holder: SurfaceHolder) = model.stop()
                            })
                        }
                    },
                    modifier = Modifier.fillMaxSize(),
                )
            }
            if (model.videoWidth == 0 && model.error == null) CircularProgressIndicator()
            model.error?.let { message ->
                Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.padding(24.dp)) {
                    Text(message, color = Color.White)
                }
            }
        }
        if (!store.fullScreen) Row(Modifier.fillMaxWidth().padding(8.dp), horizontalArrangement = Arrangement.SpaceEvenly) {
            IconButton(onClick = { model.key(Keycode.BACK) }, Modifier.semantics { contentDescription = "Back" }) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, null)
            }
            IconButton(onClick = { model.key(Keycode.HOME) }, Modifier.semantics { contentDescription = "Home" }) {
                Icon(Icons.Default.Home, null)
            }
            IconButton(onClick = { model.key(Keycode.APP_SWITCH) }, Modifier.semantics { contentDescription = "Recents" }) {
                Icon(Icons.Default.ViewCarousel, null)
            }
        }
    }
}
