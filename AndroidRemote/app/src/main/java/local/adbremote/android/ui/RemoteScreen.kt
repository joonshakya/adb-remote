package local.adbremote.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.VolumeDown
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.FastForward
import androidx.compose.material.icons.filled.FastRewind
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Input
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowLeft
import androidx.compose.material.icons.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.PowerSettingsNew
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.ViewCarousel
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import local.adbremote.android.bridge.Keycode
import local.adbremote.android.model.DeviceSession
import local.adbremote.android.model.DeviceStore

@Composable
fun RemoteScreen(store: DeviceStore, modifier: Modifier) {
    Column(modifier.fillMaxSize()) {
        val session = store.selectedSession
        if (session == null || !session.isConnected) {
            NotConnected(store)
            return@Column
        }
        LaunchedEffect(session, session.info) { session.prepareRemote() }
        val press = { code: Int -> session.sendInput { it.press(code) } }
        val longPress = { code: Int -> session.sendInput { it.press(code, longPress = true) } }

        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            if (!session.remoteReady) {
                Text(session.remoteError ?: "Starting remote…", style = MaterialTheme.typography.bodySmall,
                    color = if (session.remoteError != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
            } else session.remoteError?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
            }

            KeyRow {
                KeyButton(Icons.Default.PowerSettingsNew, "Power") { press(Keycode.POWER) }
                KeyButton(Icons.Default.Input, "Input") { press(Keycode.TV_INPUT) }
                KeyButton(Icons.Default.Settings, "Settings") { press(Keycode.SETTINGS) }
                KeyButton(Icons.AutoMirrored.Filled.VolumeOff, "Mute") { press(Keycode.MUTE) }
            }

            DPad(onDirection = press, onSelect = { press(Keycode.DPAD_CENTER) }, onLongSelect = { longPress(Keycode.DPAD_CENTER) })

            KeyRow {
                KeyButton(Icons.AutoMirrored.Filled.ArrowBack, "Back") { press(Keycode.BACK) }
                KeyButton(Icons.Default.Home, "Home") { press(Keycode.HOME) }
                KeyButton(Icons.Default.Menu, "Menu") { press(Keycode.MENU) }
                KeyButton(Icons.Default.ViewCarousel, "Recents") { press(Keycode.APP_SWITCH) }
            }
            KeyRow {
                KeyButton(Icons.AutoMirrored.Filled.VolumeDown, "Vol −") { press(Keycode.VOLUME_DOWN) }
                KeyButton(Icons.AutoMirrored.Filled.VolumeUp, "Vol +") { press(Keycode.VOLUME_UP) }
                KeyButton(Icons.Default.KeyboardArrowDown, "Ch −") { press(Keycode.CHANNEL_DOWN) }
                KeyButton(Icons.Default.KeyboardArrowUp, "Ch +") { press(Keycode.CHANNEL_UP) }
            }
            KeyRow {
                KeyButton(Icons.Default.SkipPrevious, "Prev") { press(Keycode.MEDIA_PREVIOUS) }
                KeyButton(Icons.Default.FastRewind, "Rewind") { press(Keycode.MEDIA_REWIND) }
                KeyButton(Icons.Default.PlayArrow, "Play") { press(Keycode.MEDIA_PLAY_PAUSE) }
                KeyButton(Icons.Default.FastForward, "Forward") { press(Keycode.MEDIA_FAST_FORWARD) }
                KeyButton(Icons.Default.SkipNext, "Next") { press(Keycode.MEDIA_NEXT) }
            }

            TypeOnDevice(session)
            SpecialKeys(press)
            SendText(session)
        }
    }
}

@Composable
private fun KeyRow(content: @Composable () -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) { content() }
}

@Composable
private fun KeyButton(icon: ImageVector, label: String, onClick: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        FilledTonalIconButton(onClick = onClick, modifier = Modifier.size(56.dp).semantics { contentDescription = label }) {
            Icon(icon, null)
        }
        Text(label, style = MaterialTheme.typography.labelSmall)
    }
}

/** Arrow ring with OK in the middle (long press OK = long press on the device). */
@Composable
private fun DPad(onDirection: (Int) -> Unit, onSelect: () -> Unit, onLongSelect: () -> Unit) {
    Box(
        Modifier.widthIn(max = 280.dp).fillMaxWidth().aspectRatio(1f)
            .background(MaterialTheme.colorScheme.surfaceVariant, CircleShape),
    ) {
        @Composable
        fun arrow(icon: ImageVector, label: String, code: Int, alignment: Alignment) {
            TextButton(onClick = { onDirection(code) }, modifier = Modifier.align(alignment).size(88.dp)
                .semantics { contentDescription = label }) {
                Icon(icon, null, Modifier.size(40.dp))
            }
        }
        arrow(Icons.Default.KeyboardArrowUp, "Up", Keycode.DPAD_UP, Alignment.TopCenter)
        arrow(Icons.Default.KeyboardArrowDown, "Down", Keycode.DPAD_DOWN, Alignment.BottomCenter)
        arrow(Icons.Default.KeyboardArrowLeft, "Left", Keycode.DPAD_LEFT, Alignment.CenterStart)
        arrow(Icons.Default.KeyboardArrowRight, "Right", Keycode.DPAD_RIGHT, Alignment.CenterEnd)
        Box(
            Modifier.align(Alignment.Center).size(104.dp)
                .background(MaterialTheme.colorScheme.primary, CircleShape)
                .semantics { contentDescription = "OK" }
                .pointerInput(Unit) { detectTapGestures(onTap = { onSelect() }, onLongPress = { onLongSelect() }) },
            contentAlignment = Alignment.Center,
        ) {
            Text("OK", color = MaterialTheme.colorScheme.onPrimary, style = MaterialTheme.typography.titleLarge)
        }
    }
}

/**
 * Typing goes to the device as you type: new characters are sent as text, deleted ones as
 * Backspace. The field keeps a little filler text so Backspace still works when it looks empty.
 */
@Composable
private fun TypeOnDevice(session: DeviceSession) {
    val filler = "  "
    var value by remember { mutableStateOf(TextFieldValue(filler, TextRange(filler.length))) }
    OutlinedTextField(
        value = value,
        onValueChange = { new ->
            val old = value.text
            val common = old.commonPrefixWith(new.text).length
            val deleted = old.length - common
            val added = new.text.substring(common)
            repeat(deleted) { session.sendInput { it.press(Keycode.DEL) } }
            if (added.isNotEmpty()) {
                val text = added.replace("\n", "")
                if (text.isNotEmpty()) session.sendInput { it.type(text) }
                if (added.contains('\n')) session.sendInput { it.press(Keycode.ENTER) }
            }
            // Keep the field short and refill it so there is always something to delete.
            value = if (new.text.length > 40 || new.text.length < filler.length) TextFieldValue(filler, TextRange(filler.length)) else new
        },
        label = { Text("Type on device (live)") },
        singleLine = true,
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
        keyboardActions = KeyboardActions(onSend = { session.sendInput { it.press(Keycode.ENTER) } }),
        modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Type on device" },
    )
}

@Composable
private fun SpecialKeys(press: (Int) -> Unit) {
    // Equal-width keys filling each row, so the last one isn't squeezed.
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        KeyGrid(listOf("Esc" to Keycode.ESCAPE, "Tab" to Keycode.TAB, "⌫" to Keycode.DEL,
            "⌦" to Keycode.FORWARD_DEL, "Enter" to Keycode.ENTER, "Search" to Keycode.SEARCH), press)
        Text("Function keys", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        KeyGrid((1..6).map { "F$it" to Keycode.function(it) }, press)
        KeyGrid((7..12).map { "F$it" to Keycode.function(it) }, press)
    }
}

@Composable
private fun KeyGrid(keys: List<Pair<String, Int>>, press: (Int) -> Unit) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        for ((label, code) in keys) {
            OutlinedButton(
                onClick = { press(code) },
                modifier = Modifier.weight(1f).semantics { contentDescription = label },
                contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 2.dp),
            ) {
                Text(label, style = MaterialTheme.typography.labelMedium, maxLines = 1, softWrap = false)
            }
        }
    }
}

/** Sends a whole piece of text at once (e.g. a password or a link). */
@Composable
private fun SendText(session: DeviceSession) {
    var text by remember { mutableStateOf("") }
    Column(Modifier.fillMaxWidth()) {
        Text("Send text", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(text, { text = it }, Modifier.weight(1f), singleLine = true)
            Spacer(Modifier.size(8.dp))
            FilledTonalButton(enabled = text.isNotEmpty(), onClick = {
                val sending = text
                session.sendInput { it.type(sending) }
                text = ""
            }) { Text("Send") }
        }
    }
}
