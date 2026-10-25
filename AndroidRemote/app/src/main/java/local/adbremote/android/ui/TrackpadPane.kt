package local.adbremote.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.VolumeDown
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.ViewCarousel
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import local.adbremote.android.bridge.Keycode
import local.adbremote.android.model.DeviceSession
import kotlin.math.hypot

/**
 * Phone-as-trackpad: one finger moves the TV's pointer, tap clicks, two-finger tap goes
 * back (right click), two fingers scroll, and touch-and-hold then move drags.
 */
@Composable
fun TrackpadPane(session: DeviceSession) {
    LaunchedEffect(session, session.remoteReady) { session.pointer() }
    DisposableEffect(session) { onDispose { session.pointer()?.hide() } }
    val haptic = LocalHapticFeedback.current
    val density = LocalDensity.current.density
    val press = { code: Int -> session.sendInput { it.press(code) } }

    Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        session.remoteError?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
        Box(
            Modifier.weight(1f).fillMaxWidth()
                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f), RoundedCornerShape(22.dp))
                .border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(22.dp))
                .semantics { contentDescription = "Trackpad" }
                .pointerInput(session) {
                    coroutineScope {
                        while (true) {
                            awaitPointerEventScope {
                                // One gesture: from the first finger down until every finger is up.
                                val first = awaitPointerEvent()
                                val down = first.changes.firstOrNull { it.pressed } ?: return@awaitPointerEventScope
                                val start = down.position
                                val startTime = System.currentTimeMillis()
                                var lastTime = startTime
                                var maxTouches = first.changes.count { it.pressed }
                                var moved = false
                                var dragging = false
                                // Touch and hold without moving: press the button down for dragging.
                                val hold: Job = this@coroutineScope.launch {
                                    delay(450)
                                    if (!moved && maxTouches == 1) {
                                        dragging = true
                                        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                        session.pointer()?.setButtons(1)
                                    }
                                }
                                while (true) {
                                    val event = awaitPointerEvent()
                                    val active = event.changes.filter { it.pressed }
                                    if (active.isEmpty()) break
                                    maxTouches = maxOf(maxTouches, active.size)
                                    var delta = Offset.Zero
                                    for (c in active) delta += c.position - c.previousPosition
                                    // Points, like the iOS app, so both feel the same.
                                    val dx = delta.x / active.size / density
                                    val dy = delta.y / active.size / density
                                    active.forEach { it.consume() }
                                    // A few points of wobble still count as a tap.
                                    if (!moved && (active[0].position - start).let { hypot(it.x, it.y) } / density > 8) {
                                        moved = true
                                        if (!dragging) hold.cancel()
                                    }
                                    val now = System.currentTimeMillis()
                                    val interval = maxOf(now - lastTime, 4L) / 1000.0
                                    lastTime = now
                                    if (dx == 0f && dy == 0f) continue
                                    val problem = if (active.size >= 2) {
                                        session.pointer()?.scroll(dx.toDouble(), dy.toDouble())
                                    } else {
                                        // Faster swipes travel further, like a laptop trackpad.
                                        val speed = hypot(dx, dy) / interval
                                        val gain = 1.6 + minOf(speed / 500, 3.0)
                                        session.pointer()?.move(dx * gain, dy * gain)
                                    }
                                    session.remoteError = problem
                                }
                                hold.cancel()
                                val quick = System.currentTimeMillis() - startTime < 300
                                if (dragging) {
                                    session.pointer()?.setButtons(0)
                                } else if (quick && !moved) {
                                    // Right click = Back on Android.
                                    session.pointer()?.click(if (maxTouches >= 2) 2 else 1)
                                    haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                }
                            }
                        }
                    }
                },
            contentAlignment = Alignment.BottomCenter,
        ) {
            Text("Tap to click · Two fingers to scroll · Two-finger tap = Back · Hold, then move to drag",
                Modifier.padding(10.dp), style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
            SmallKeyIcon(Icons.AutoMirrored.Filled.ArrowBack, "Back") { press(Keycode.BACK) }
            SmallKeyIcon(Icons.Default.Home, "Home") { press(Keycode.HOME) }
            SmallKeyIcon(Icons.Default.ViewCarousel, "Recents") { press(Keycode.APP_SWITCH) }
            SmallKeyIcon(Icons.Default.PlayArrow, "Play") { press(Keycode.MEDIA_PLAY_PAUSE) }
            SmallKeyIcon(Icons.AutoMirrored.Filled.VolumeDown, "Vol −") { press(Keycode.VOLUME_DOWN) }
            SmallKeyIcon(Icons.AutoMirrored.Filled.VolumeUp, "Vol +") { press(Keycode.VOLUME_UP) }
        }
    }
}

@Composable
private fun SmallKeyIcon(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    FilledTonalIconButton(onClick = onClick, modifier = Modifier.size(48.dp).semantics { contentDescription = label }) {
        Icon(icon, null)
    }
}
