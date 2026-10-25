package local.adbremote.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.graphics.Color
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.DropdownMenu
import androidx.compose.material.icons.filled.RemoveCircleOutline
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import local.adbremote.android.bridge.AdbException
import local.adbremote.android.model.DeviceSession
import local.adbremote.android.model.DeviceStore
import local.adbremote.android.model.SavedDevice

@Composable
fun DevicesScreen(store: DeviceStore, modifier: Modifier) {
    var adding by remember { mutableStateOf(false) }
    Column(modifier.fillMaxSize()) {
        DeviceBar(store, "Devices") {
            IconButton(onClick = { adding = true }, Modifier.semantics { contentDescription = "Add device" }) {
                Icon(Icons.Default.Add, null)
            }
        }
        if (store.devices.isEmpty()) {
            Column(
                Modifier.fillMaxSize().padding(32.dp),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Icon(Icons.Default.Tv, null, Modifier.size(56.dp))
                Text("Add your TV or Android device", style = MaterialTheme.typography.titleMedium)
                Text("Turn on network debugging on it (or BlueStacks: Settings → Advanced → Android Debug Bridge), then add its IP address.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.size(16.dp))
                Button(onClick = { adding = true }) { Text("Add Device") }
            }
        } else {
            LazyColumn(Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(12.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                items(store.devices, key = { it.id }) { device ->
                    DeviceCard(store, device)
                }
            }
        }
    }
    if (adding) DeviceDialog("Add Device", "Add", onDismiss = { adding = false }) { name, host, port ->
        adding = false
        val device = store.add(name, host, port)
        store.scope.launch { store.session(device).connect() }
    }
}

@Composable
private fun DeviceCard(store: DeviceStore, device: SavedDevice) {
    val session = store.session(device)
    val selected = device.id == store.selectedID
    val scope = rememberCoroutineScope()
    var removing by remember { mutableStateOf(false) }
    var pairing by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    val context = LocalContext.current
    LaunchedEffect(device.id, session.isConnected) { session.checkReachability() }

    Card(
        Modifier.fillMaxWidth().clickable { store.select(device.id) },
        colors = if (selected) CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer) else CardDefaults.cardColors(),
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(device.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    val port = device.port?.toString() ?: device.lastPort?.let { "$it (auto)" } ?: "auto"
                    Text("${device.host} · port $port", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                StatusDot(session)
                if (!session.isConnected && session.reachable != null) {
                    Spacer(Modifier.width(6.dp))
                    Text(if (session.reachable == true) "Online" else "Offline", style = MaterialTheme.typography.labelSmall)
                }
            }

            when (val state = session.state) {
                is DeviceSession.State.Connecting -> Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(8.dp))
                    Text(state.message, style = MaterialTheme.typography.bodySmall)
                }
                DeviceSession.State.WaitingForApproval -> Text("Look at ${device.name}: tap Allow to let this phone control it.",
                    color = MaterialTheme.colorScheme.primary)
                is DeviceSession.State.Failed -> Text(state.message, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                else -> {}
            }

            session.scan?.let { scan ->
                LinearProgressIndicator(progress = { scan.scanned.toFloat() / scan.total.coerceAtLeast(1) }, Modifier.fillMaxWidth())
                Text(if (scan.probing) "Checking open ports: ${scan.openPorts.joinToString()}"
                    else "Scanned ${scan.scanned} of ${scan.total} ports. Open: ${scan.openPorts.joinToString().ifEmpty { "none yet" }}",
                    style = MaterialTheme.typography.bodySmall)
                OutlinedButton(onClick = { session.cancelScan() }) { Text("Stop Scan") }
            }
            if (session.offerPortScan && session.scan == null) {
                Text("ADB isn't on the usual port. Scan ${device.host} for it?", style = MaterialTheme.typography.bodySmall)
                OutlinedButton(onClick = { session.startPortScan() }) { Text("Scan for ADB Port") }
            }
            if (session.portChoices.isNotEmpty()) {
                Text("Several ADB ports found. Pick one:", style = MaterialTheme.typography.bodySmall)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (choice in session.portChoices) {
                        OutlinedButton(onClick = {
                            session.portChoices = emptyList()
                            store.scope.launch { session.connect(choice.port) }
                        }) { Text("${choice.port}${if (choice.tls) " (pairing)" else ""}") }
                    }
                }
            }
            if (session.needsPairing) {
                Text("This device uses Wireless debugging and doesn't know this phone yet. Pair it first.", style = MaterialTheme.typography.bodySmall)
                Button(onClick = { pairing = true }) { Text("Pair with Code") }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                when {
                    session.isConnected -> OutlinedButton(onClick = { session.disconnect() }) { Text("Disconnect") }
                    !session.isBusy -> Button(onClick = {
                        store.select(device.id)
                        store.scope.launch { session.connect() }
                    }) { Text(if (session.state is DeviceSession.State.Failed) "Retry" else "Connect") }
                }
                Spacer(Modifier.weight(1f))
                Box {
                    IconButton(onClick = { menu = true }, Modifier.semantics { contentDescription = "Device options" }) {
                        Icon(Icons.Default.MoreVert, null)
                    }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(text = { Text("Edit Device") }, onClick = { menu = false; editing = true })
                        DropdownMenuItem(text = { Text("Pair with Code (Android 11+)") }, onClick = { menu = false; pairing = true })
                        DropdownMenuItem(text = { Text("Share Connection Log") }, onClick = {
                            menu = false
                            shareLog(context, device.name)
                        })
                        DropdownMenuItem(text = { Text("Remove Device", color = MaterialTheme.colorScheme.error) },
                            onClick = { menu = false; removing = true })
                    }
                }
            }

            if (session.isConnected && selected) DeviceDetails(store, session)
        }
    }

    if (removing) AlertDialog(
        onDismissRequest = { removing = false },
        title = { Text("Remove ${device.name}?") },
        confirmButton = { TextButton(onClick = { removing = false; store.remove(device.id) }) { Text("Remove") } },
        dismissButton = { TextButton(onClick = { removing = false }) { Text("Cancel") } },
    )
    if (editing) DeviceDialog("Edit Device", "Save", device.name, device.host, device.port?.toString() ?: "",
        onDismiss = { editing = false }) { name, host, port ->
        editing = false
        val changed = host != device.host || port != device.port
        store.update(device.copy(name = name.ifBlank { host }, host = host, port = port, lastPort = if (changed) null else device.lastPort))
        // A new address needs a new connection.
        if (changed && session.isConnected) {
            session.disconnect()
            store.scope.launch { session.connect() }
        }
    }
    if (pairing) PairDialog(session, onDismiss = { pairing = false }, onPaired = { store.scope.launch { session.connect() } })
}

@Composable
private fun DeviceDetails(store: DeviceStore, session: DeviceSession) {
    var more by remember { mutableStateOf(false) }
    HorizontalDivider()
    val info = session.info
    if (info == null) {
        Text("Reading device info…", style = MaterialTheme.typography.bodySmall)
        return
    }
    SectionTitle("About This Device")
    for ((label, value) in info.rows) InfoRow(label, value)
    session.extras?.let { extras ->
        SectionTitle("What Works on This Device")
        for (capability in extras.capabilities) {
            Row(verticalAlignment = Alignment.Top) {
                Icon(if (capability.supported) Icons.Default.CheckCircle else Icons.Default.RemoveCircleOutline, null,
                    Modifier.size(18.dp).padding(top = 2.dp),
                    tint = if (capability.supported) Color(0xFF34C759) else MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.width(8.dp))
                Column {
                    Text(capability.name, style = MaterialTheme.typography.bodyMedium)
                    Text(capability.note, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        SectionTitle("Root Access")
        InfoRow("Rooted", extras.rootAnswer)
        Note(extras.rootExplanation)
        SectionTitle("Google Play")
        InfoRow("Play Store", extras.playStore.ifEmpty { null }?.let { "Installed ($it)" } ?: "Not installed")
        InfoRow("Google services", if (extras.playServices) "Installed" else "Not installed")
        if (extras.playStore.isEmpty()) Note("Without the Play Store, install apps from files using the Apps tab.")
    }
    SectionTitle("Transfer Speed")
    session.speedTest?.let {
        InfoRow("Phone → device", mbps(it.upload))
        InfoRow("Device → phone", mbps(it.download))
        InfoRow("Response time", "${(it.latency * 1000).toInt()} ms")
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        val status = session.speedTestStatus
        if (status == null) {
            OutlinedButton(onClick = { store.scope.launch { session.runSpeedTest() } }) {
                Text(if (session.speedTest == null) "Test Speed" else "Test Again")
            }
        } else {
            if (!status.startsWith("Failed")) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
            Spacer(Modifier.width(8.dp))
            Text(status, style = MaterialTheme.typography.bodySmall)
        }
    }
    Note("How fast files, apps and photos move between your phone and this device.")
    TextButton(onClick = { more = !more }) { Text(if (more) "Hide details" else "More details") }
    if (more) {
        for ((label, value) in info.advanced) InfoRow(label, value)
        session.extras?.let { extras ->
            for ((label, value) in extras.rootDetails) InfoRow(label, value)
            if (extras.googlePackages.isNotEmpty()) InfoRow("Google packages", extras.googlePackages.joinToString("\n"))
            InfoRow("ADB features", extras.adbFeatures.ifEmpty { listOf("None (older Android)") }.joinToString(", "))
        }
        Note("Technical information, useful when troubleshooting.")
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(text, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(top = 8.dp))
}

@Composable
private fun Note(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

private fun mbps(bytesPerSecond: Double) = "%.1f MB/s".format(bytesPerSecond / 1_000_000)

@Composable
fun InfoRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth()) {
        Text(label, Modifier.weight(0.4f), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, Modifier.weight(0.6f), style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
private fun DeviceDialog(
    title: String, action: String, initialName: String = "", initialHost: String = "", initialPort: String = "",
    onDismiss: () -> Unit, onDone: (String, String, Int?) -> Unit,
) {
    var name by remember { mutableStateOf(initialName) }
    var host by remember { mutableStateOf(initialHost) }
    var port by remember { mutableStateOf(initialPort) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(name, { name = it }, label = { Text("Name (optional)") }, singleLine = true)
                OutlinedTextField(host, { host = it.trim() }, label = { Text("IP address") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
                OutlinedTextField(port, { port = it.filter(Char::isDigit) }, label = { Text("Port (blank = find it)") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
            }
        },
        confirmButton = {
            TextButton(enabled = host.isNotEmpty(), onClick = { onDone(name, host, port.toIntOrNull()) }) { Text(action) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun PairDialog(session: DeviceSession, onDismiss: () -> Unit, onPaired: () -> Unit) {
    var port by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Pair with Code") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("On the device: Developer options → Wireless debugging → Pair device with pairing code. Enter the port and code it shows.",
                    style = MaterialTheme.typography.bodySmall)
                OutlinedTextField(port, { port = it.filter(Char::isDigit) }, label = { Text("Pairing port") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                OutlinedTextField(code, { code = it.filter(Char::isDigit) }, label = { Text("6-digit code") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                if (busy) CircularProgressIndicator()
            }
        },
        confirmButton = {
            TextButton(enabled = !busy && port.isNotEmpty() && code.length >= 6, onClick = {
                busy = true
                scope.launch {
                    try {
                        session.pair(port.toInt(), code)
                        onPaired()
                        onDismiss()
                    } catch (e: AdbException) {
                        error = e.message
                    } finally {
                        busy = false
                    }
                }
            }) { Text("Pair") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** Shares the device's connection log (pings, inputs, connects) as a text file. */
private fun shareLog(context: android.content.Context, device: String) {
    val file = local.adbremote.android.model.EventLog.file(device)
    if (!file.exists()) {
        android.widget.Toast.makeText(context, "No log yet for $device", android.widget.Toast.LENGTH_SHORT).show()
        return
    }
    val uri = androidx.core.content.FileProvider.getUriForFile(context, context.packageName + ".files", file)
    val send = android.content.Intent(android.content.Intent.ACTION_SEND).setType("text/plain")
        .putExtra(android.content.Intent.EXTRA_STREAM, uri)
        .addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
    context.startActivity(android.content.Intent.createChooser(send, "Connection log for $device"))
}
