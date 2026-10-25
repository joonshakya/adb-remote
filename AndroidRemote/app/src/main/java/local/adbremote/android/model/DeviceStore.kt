package local.adbremote.android.model

import android.content.Context
import android.os.Build
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import local.adbremote.android.bridge.Adb
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

data class SavedDevice(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val host: String,
    /** Fixed port; null = automatic (last working port, then 5555, then scan). */
    val port: Int? = null,
    val lastPort: Int? = null,
) {
    fun toJson(): JSONObject = JSONObject().put("id", id).put("name", name).put("host", host)
        .put("port", port ?: JSONObject.NULL).put("lastPort", lastPort ?: JSONObject.NULL)

    companion object {
        fun from(json: JSONObject) = SavedDevice(
            json.getString("id"), json.getString("name"), json.getString("host"),
            if (json.isNull("port")) null else json.getInt("port"),
            if (json.isNull("lastPort")) null else json.getInt("lastPort"),
        )
    }
}

/** Saved devices, live sessions and which one is selected. */
class DeviceStore(val context: Context) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val prefs = context.getSharedPreferences("devices", Context.MODE_PRIVATE)

    val devices = mutableStateListOf<SavedDevice>()
    private val sessions = mutableMapOf<String, DeviceSession>()
    var selectedID by mutableStateOf<String?>(null)
        private set

    /** "<base64 key> <name>": what the device stores when the user allows this phone. */
    val publicKey: String
    /** Helper files from the app's assets, copied out so AdbKit can read them. */
    val scrcpyServer: String
    val helperJar: String
    val viewerApk: String

    /** Control → Screen filling the whole phone (tab bar and system bars hidden). */
    var fullScreen by mutableStateOf(false)
    /** The live screen's shape, for turning the phone sideways in full screen. */
    var screenIsWide by mutableStateOf(true)

    /** Text or a link shared to the app ("Send to TV"); the Play tab's Link pane sends it. */
    var pendingLink by mutableStateOf<String?>(null)
    /** The YouTube page, kept across tab switches so you don't lose your place. */
    var youtubeWebView: android.webkit.WebView? = null

    /** When the app last went to the background (connections may pause there). */
    var lastBackgrounded = 0L

    init {
        EventLog.init(context)
        publicKey = Adb.init(File(context.filesDir, "adbkey").path, "AdbRemote@${Build.MODEL}")
        scrcpyServer = asset("scrcpy-server-v5.0.1")
        helperJar = asset("adbremote-helper.jar")
        viewerApk = asset("adbremote-viewer.apk")
        val saved = runCatching { JSONArray(prefs.getString("list", "[]")) }.getOrDefault(JSONArray())
        for (i in 0 until saved.length()) devices.add(SavedDevice.from(saved.getJSONObject(i)))
        selectedID = prefs.getString("selected", null)?.takeIf { id -> devices.any { it.id == id } } ?: devices.firstOrNull()?.id
    }

    /** Copies an asset out once per app install/update. */
    private fun asset(name: String): String {
        val out = File(context.filesDir, "assets/$name")
        val installed = context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime
        if (out.exists() && out.lastModified() == installed) return out.path
        out.parentFile?.mkdirs()
        context.assets.open(name).use { input -> out.outputStream().use { input.copyTo(it) } }
        out.setLastModified(installed)
        return out.path
    }

    fun cacheDir(name: String): File = File(context.cacheDir, name).apply { mkdirs() }

    val selectedDevice: SavedDevice? get() = devices.firstOrNull { it.id == selectedID }
    val selectedSession: DeviceSession? get() = selectedDevice?.let(::session)

    fun session(device: SavedDevice): DeviceSession = sessions.getOrPut(device.id) { DeviceSession(device.id, this) }

    fun device(id: String): SavedDevice? = devices.firstOrNull { it.id == id }

    fun select(id: String) {
        selectedID = id
        prefs.edit().putString("selected", id).apply()
        connectSelected()
    }

    fun add(name: String, host: String, port: Int?): SavedDevice {
        val device = SavedDevice(name = name.ifBlank { host }, host = host, port = port)
        devices.add(device)
        select(device.id)
        save()
        return device
    }

    fun update(device: SavedDevice) {
        val i = devices.indexOfFirst { it.id == device.id }
        if (i < 0) return
        devices[i] = device
        save()
    }

    fun remove(id: String) {
        sessions.remove(id)?.disconnect()
        devices.removeAll { it.id == id }
        if (selectedID == id) devices.firstOrNull()?.let { select(it.id) } ?: run { selectedID = null }
        save()
    }

    /** Connects the selected device when the app opens (unless the user disconnected it). */
    fun connectSelected() {
        val session = selectedSession ?: return
        if (session.state == DeviceSession.State.Disconnected && !session.userDisconnected) scope.launch { session.connect() }
    }

    /** Reconnects sessions that dropped while the app was in the background. */
    fun reconnectDropped() {
        for (session in sessions.values) {
            if (session.shouldAutoReconnect) scope.launch { session.connect() }
        }
    }

    private fun save() {
        prefs.edit().putString("list", JSONArray(devices.map { it.toJson() }).toString()).apply()
    }
}
