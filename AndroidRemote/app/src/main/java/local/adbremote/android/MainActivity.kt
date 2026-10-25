package local.adbremote.android

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Apps
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Gamepad
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import android.os.Build
import androidx.compose.foundation.layout.padding
import local.adbremote.android.model.DeviceStore
import local.adbremote.android.ui.AppsScreen
import local.adbremote.android.ui.DevicesScreen
import local.adbremote.android.ui.FilesScreen
import local.adbremote.android.ui.ControlScreen
import local.adbremote.android.ui.PlayScreen

class MainActivity : ComponentActivity() {
    private val store: DeviceStore get() = (application as AdbRemoteApplication).store

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        handleShare(intent)
        setContent { AppTheme { Root(store) } }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleShare(intent)
    }

    /** "Send to TV" from another app's share menu: a link or some text. */
    private fun handleShare(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND) return
        intent.getStringExtra(Intent.EXTRA_TEXT)?.takeIf { it.isNotBlank() }?.let { store.pendingLink = it }
    }

    override fun onStart() {
        super.onStart()
        store.connectSelected()
        store.reconnectDropped()
    }

    override fun onStop() {
        super.onStop()
        store.lastBackgrounded = System.currentTimeMillis()
    }
}

enum class Tab(val title: String, val icon: ImageVector) {
    Devices("Devices", Icons.Default.Tv),
    Control("Control", Icons.Default.Gamepad),
    Play("Play", Icons.Default.PhotoLibrary),
    Apps("Apps", Icons.Default.Apps),
    Files("Files", Icons.Default.Folder),
}

@Composable
fun Root(store: DeviceStore) {
    var tab by rememberSaveable { mutableStateOf(Tab.Devices) }
    // A shared link opens the Play tab, which sends it.
    androidx.compose.runtime.LaunchedEffect(store.pendingLink) { if (store.pendingLink != null) tab = Tab.Play }
    Scaffold(
        bottomBar = {
            if (!store.fullScreen) NavigationBar {
                for (t in Tab.entries) {
                    NavigationBarItem(
                        selected = tab == t,
                        onClick = { tab = t },
                        icon = { Icon(t.icon, contentDescription = null) },
                        label = { Text(t.title) },
                        modifier = Modifier.semantics { contentDescription = "tab-${t.title}" },
                    )
                }
            }
        },
    ) { padding ->
        val modifier = Modifier.padding(padding)
        // Each tab is only composed while shown, so leaving Screen stops its video.
        when (tab) {
            Tab.Devices -> DevicesScreen(store, modifier)
            Tab.Control -> ControlScreen(store, modifier)
            Tab.Play -> PlayScreen(store, modifier)
            Tab.Apps -> AppsScreen(store, modifier)
            Tab.Files -> FilesScreen(store, modifier)
        }
    }
}

@Composable
fun AppTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val context = LocalContext.current
    val colors = when {
        Build.VERSION.SDK_INT >= 31 -> if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> darkColorScheme()
        else -> lightColorScheme()
    }
    MaterialTheme(colorScheme = colors, content = content)
}
