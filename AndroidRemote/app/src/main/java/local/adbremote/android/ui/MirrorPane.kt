package local.adbremote.android.ui

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CastConnected
import androidx.compose.material.icons.filled.ScreenShare
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import local.adbremote.android.bridge.AdbException
import local.adbremote.android.bridge.ViewerClient
import local.adbremote.android.model.DeviceStore
import local.adbremote.android.model.MirrorService

/**
 * Play tab → Mirror: shows this phone's screen, with its sound, on the TV. The TV app's
 * receiver is started over ADB; the phone then streams to it directly over Wi-Fi.
 */
@Composable
fun MirrorPane(store: DeviceStore) {
    val context = LocalContext.current
    val session = store.selectedSession ?: return
    val device = session.device ?: return
    val tvName = device.name
    var preparing by remember { mutableStateOf<String?>(null) }
    var failure by remember { mutableStateOf<String?>(null) }

    val capture = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        preparing = null
        val data = result.data
        if (result.resultCode != Activity.RESULT_OK || data == null) {
            failure = "Screen capture wasn't allowed."
            return@rememberLauncherForActivityResult
        }
        val adb = session.connection ?: return@rememberLauncherForActivityResult
        val longSide = session.castModel()?.tv?.longSide ?: 1920
        MirrorService.start(context, result.resultCode, data, device.host, tvName, longSide, adb)
    }
    val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        // Sound needs the microphone permission; without it only the picture is sent.
        val manager = context.getSystemService(MediaProjectionManager::class.java)
        capture.launch(manager.createScreenCaptureIntent())
    }

    val start: () -> Unit = {
        failure = null
        preparing = "Preparing $tvName…"
        store.scope.launch {
            val adb = session.connection
            val sdk = session.info?.sdk ?: 0
            if (adb == null) {
                preparing = null
                failure = "Not connected"
                return@launch
            }
            try {
                ViewerClient.installIfNeeded(adb, sdk, store.viewerApk, store.helperJar) { preparing = it }
                // Lets the receiver open its screen when mirroring starts (Android 10+ blocks that otherwise).
                if (sdk >= 23) runCatching { adb.shell("appops set ${ViewerClient.PACKAGE} SYSTEM_ALERT_WINDOW allow") }
                val verb = if (sdk >= 26) "start-foreground-service" else "startservice"
                val output = adb.shell("am $verb -n ${ViewerClient.PACKAGE}/.airplay.AirPlayService --es name ${quote(tvName)}").stdout
                if (output.contains("Error")) throw AdbException(output.trim())
                preparing = "Allow screen capture on this phone"
                val wanted = buildList {
                    add(Manifest.permission.RECORD_AUDIO)
                    if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
                }.filter { context.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
                if (wanted.isEmpty()) {
                    capture.launch(context.getSystemService(MediaProjectionManager::class.java).createScreenCaptureIntent())
                } else {
                    permissions.launch(wanted.toTypedArray())
                }
            } catch (e: AdbException) {
                preparing = null
                failure = e.message
            }
        }
    }

    Column(
        Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        val mirroring = MirrorService.mirroringTo
        if (mirroring != null) {
            Icon(Icons.Default.CastConnected, null, Modifier.size(64.dp), tint = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.size(12.dp))
            Text("Mirroring to $mirroring", style = MaterialTheme.typography.titleLarge)
            Text(if (MirrorService.withSound) "Screen and sound are on the TV." else "Screen is on the TV (no sound: allow the microphone permission for sound).",
                textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.size(20.dp))
            Button(onClick = { MirrorService.stop(context) }) { Text("Stop Mirroring") }
            return@Column
        }
        Icon(Icons.Default.ScreenShare, null, Modifier.size(64.dp), tint = MaterialTheme.colorScheme.primary)
        Spacer(Modifier.size(12.dp))
        Text("Mirror this phone", style = MaterialTheme.typography.titleLarge)
        Text("Show your screen and play its sound on $tvName. Some apps (like Netflix) block capture; for YouTube, Play on TV is smoother.",
            textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.size(20.dp))
        val busy = preparing
        if (busy != null) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                Spacer(Modifier.size(8.dp))
                Text(busy)
            }
        } else {
            Button(onClick = start) { Text("Start Mirroring") }
        }
        (failure ?: MirrorService.error)?.let {
            Spacer(Modifier.size(12.dp))
            Text(it, color = MaterialTheme.colorScheme.error, textAlign = TextAlign.Center)
        }
        Spacer(Modifier.size(24.dp))
        OutlinedButton(onClick = {
            store.scope.launch {
                val sdk = session.info?.sdk ?: 0
                val verb = if (sdk >= 26) "start-foreground-service" else "startservice"
                runCatching { session.connection?.shell("am $verb -n ${ViewerClient.PACKAGE}/.airplay.AirPlayService --es action stop") }
            }
        }) { Text("Turn Off Receiver on $tvName") }
    }
}

private fun quote(s: String) = "'" + s.replace("'", "'\\''") + "'"
