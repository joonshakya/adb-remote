package local.adbremote.android.ui

import android.app.Activity
import android.content.pm.ActivityInfo
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.FullscreenExit
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import local.adbremote.android.model.DeviceStore

/** Control tab: remote buttons, trackpad, or the device's live screen (stopped as soon as you switch away). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ControlScreen(store: DeviceStore, modifier: Modifier) {
    val modes = listOf("Buttons", "Trackpad", "Screen")
    var mode by rememberSaveable { mutableStateOf("Buttons") }
    val session = store.selectedSession
    val connected = session?.isConnected == true
    // Full screen only while the screen is showing.
    LaunchedEffect(mode, connected) { if (mode != "Screen" || !connected) store.fullScreen = false }
    FullScreenWindow(store.fullScreen, store.screenIsWide)

    if (store.fullScreen && session != null) {
        BackHandler { store.fullScreen = false }
        Box(modifier.fillMaxSize()) {
            ScreenScreen(store, Modifier.fillMaxSize())
            IconButton(onClick = { store.fullScreen = false },
                Modifier.align(Alignment.TopEnd).statusBarsPadding().padding(4.dp).semantics { contentDescription = "Exit full screen" }) {
                Icon(Icons.Default.FullscreenExit, null, tint = Color.White.copy(alpha = 0.7f))
            }
        }
        return
    }
    Column(modifier.fillMaxSize()) {
        DeviceBar(store, "Control") {
            if (mode == "Screen" && connected) {
                IconButton(onClick = { store.fullScreen = true }, Modifier.semantics { contentDescription = "Full screen" }) {
                    Icon(Icons.Default.Fullscreen, null)
                }
            }
        }
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) {
            modes.forEachIndexed { index, name ->
                SegmentedButton(selected = mode == name, onClick = { mode = name },
                    shape = SegmentedButtonDefaults.itemShape(index, modes.size)) { Text(name) }
            }
        }
        when {
            mode == "Buttons" -> RemoteScreen(store, Modifier)
            mode == "Screen" -> ScreenScreen(store, Modifier)
            session == null || !connected -> NotConnected(store)
            else -> TrackpadPane(session)
        }
    }
}

/** Hides the system bars, and turns the phone sideways for a wide (TV) screen. */
@Composable
private fun FullScreenWindow(on: Boolean, wide: Boolean) {
    val activity = LocalContext.current as? Activity ?: return
    DisposableEffect(on, wide) {
        val controller = WindowCompat.getInsetsController(activity.window, activity.window.decorView)
        if (on) {
            controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.hide(WindowInsetsCompat.Type.systemBars())
            activity.requestedOrientation = if (wide) ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE else ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        }
        onDispose {
            controller.show(WindowInsetsCompat.Type.systemBars())
            activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
    }
}
