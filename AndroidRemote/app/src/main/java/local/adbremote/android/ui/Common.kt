package local.adbremote.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.TvOff
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import local.adbremote.android.model.DeviceSession
import local.adbremote.android.model.DeviceStore

/** Title bar: the device switcher with the connection / latency dot (the title shows only with no devices). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DeviceBar(store: DeviceStore, title: String, actions: @Composable () -> Unit = {}) {
    val session = store.selectedSession
    var open by remember { mutableStateOf(false) }
    TopAppBar(
        title = {
            // Just the device switcher: the tab bar already says which tab this is.
            if (store.devices.isEmpty()) {
                Text(title, style = MaterialTheme.typography.titleLarge)
            } else {
                Box {
                    TextButton(onClick = { open = true }, contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp)) {
                        session?.let { StatusDot(it) }
                        Spacer(Modifier.width(8.dp))
                        Text(store.selectedDevice?.name ?: "Choose device", style = MaterialTheme.typography.titleMedium,
                            color = MaterialTheme.colorScheme.onSurface)
                        Icon(Icons.Default.ArrowDropDown, null, tint = MaterialTheme.colorScheme.onSurface)
                    }
                    DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                        for (device in store.devices) {
                            DropdownMenuItem(
                                text = { Text(device.name) },
                                leadingIcon = { if (device.id == store.selectedID) Icon(Icons.Default.Check, null) },
                                onClick = {
                                    store.select(device.id)
                                    open = false
                                },
                            )
                        }
                    }
                }
            }
        },
        actions = { actions() },
        expandedHeight = 52.dp,
    )
}

/** Green (with latency) when connected, orange when not answering, grey otherwise. */
@Composable
fun StatusDot(session: DeviceSession) {
    val color = when {
        session.isConnected && session.latencyTimedOut -> Color(0xFFFF9800)
        session.isConnected -> Color(0xFF34C759)
        session.isBusy -> Color(0xFFFFCC00)
        else -> Color.Gray
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(10.dp).background(color, CircleShape))
        if (session.isConnected) {
            Spacer(Modifier.width(4.dp))
            Text(
                when {
                    session.latencyTimedOut -> "No reply"
                    session.latency != null -> "${(session.latency!! * 1000).toInt()} ms"
                    else -> ""
                },
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** Shown by tabs that need a connection when there isn't one. */
@Composable
fun NotConnected(store: DeviceStore, modifier: Modifier = Modifier) {
    val session = store.selectedSession
    val scope = rememberCoroutineScope()
    Column(
        modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(Icons.Default.TvOff, null, Modifier.size(56.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.size(12.dp))
        if (session == null) {
            Text("No device yet", style = MaterialTheme.typography.titleMedium)
            Text("Add one on the Devices tab.", textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant)
            return@Column
        }
        Text("Not connected", style = MaterialTheme.typography.titleMedium)
        when (val state = session.state) {
            is DeviceSession.State.Connecting -> {
                Spacer(Modifier.size(12.dp))
                CircularProgressIndicator()
                Text(state.message, textAlign = TextAlign.Center)
            }
            DeviceSession.State.WaitingForApproval -> Text("Tap Allow on the device's screen.", textAlign = TextAlign.Center)
            is DeviceSession.State.Failed -> Text(state.message, textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.error)
            else -> {}
        }
        Spacer(Modifier.size(12.dp))
        if (!session.isBusy) Button(onClick = { scope.launch { session.connect() } }) { Text("Connect") }
    }
}

/**
 * "Working…" status, errors and confirmations, floating over the bottom of the content
 * (place it in a Box) so nothing moves when it comes and goes.
 */
@Composable
fun StatusBanner(activity: String?, error: String?, message: String?, modifier: Modifier = Modifier, onDismiss: () -> Unit) {
    val text = activity ?: error ?: message ?: return
    val isError = activity == null && error != null
    Surface(
        color = if (isError) MaterialTheme.colorScheme.errorContainer else MaterialTheme.colorScheme.secondaryContainer,
        shape = androidx.compose.foundation.shape.RoundedCornerShape(16.dp),
        shadowElevation = 6.dp,
        modifier = modifier.padding(12.dp).fillMaxWidth(),
    ) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            if (activity != null) {
                CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                Spacer(Modifier.width(10.dp))
            }
            Text(text, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
            if (activity == null) TextButton(onClick = onDismiss) { Text("OK") }
        }
    }
}
