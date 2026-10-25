package local.adbremote.android.model

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import local.adbremote.android.bridge.AdbConnection
import local.adbremote.android.bridge.AdbException
import local.adbremote.android.bridge.AppManager
import local.adbremote.android.bridge.InstalledApp
import local.adbremote.android.bridge.zip
import java.io.File

/** App list, icons and app actions for one connected device. */
class AppsModel(private val connection: AdbConnection, private val sdk: Int, private val store: DeviceStore) {
    var apps by mutableStateOf<List<InstalledApp>>(emptyList())
        private set
    val icons = mutableStateMapOf<String, Bitmap>()
    var isLoading by mutableStateOf(false)
        private set
    var error by mutableStateOf<String?>(null)
    /** Shown while installing or saving ("Uploading", "Installing", ...). */
    var activity by mutableStateOf<String?>(null)
        private set
    /** Set after a successful action, e.g. "TV Bro was uninstalled." */
    var message by mutableStateOf<String?>(null)

    private var manager: AppManager? = null
    private val cache = store.cacheDir("icons")

    private suspend fun manager(): AppManager =
        manager ?: AppManager.create(connection, sdk, store.helperJar).also { manager = it }

    private fun iconFile(app: InstalledApp) = File(cache, "${app.packageName}-${app.versionCode}.png")

    suspend fun refresh() {
        if (isLoading) return
        isLoading = true
        try {
            apps = manager().list().sortedBy { it.label.lowercase() }
            error = null
            loadIcons()
        } catch (e: AdbException) {
            error = e.message
        } finally {
            isLoading = false
        }
    }

    /** Cached icons load instantly; missing ones are fetched from the device in batches. */
    private suspend fun loadIcons() {
        val missing = mutableListOf<InstalledApp>()
        withContext(Dispatchers.IO) {
            for (app in apps) {
                if (icons.containsKey(app.packageName)) continue
                val file = iconFile(app)
                val bitmap = if (file.exists()) BitmapFactory.decodeFile(file.path) else null
                if (bitmap != null) withContext(Dispatchers.Main) { icons[app.packageName] = bitmap } else missing.add(app)
            }
        }
        // Launchable apps first so the grid fills in quickly.
        missing.sortBy { !it.isLaunchable }
        for (batch in missing.chunked(40)) {
            val fetched = try {
                manager().icons(batch.map { it.packageName })
            } catch (e: AdbException) {
                return
            }
            for (app in batch) {
                val png = fetched[app.packageName] ?: continue
                val bitmap = BitmapFactory.decodeByteArray(png, 0, png.size) ?: continue
                icons[app.packageName] = bitmap
                withContext(Dispatchers.IO) { iconFile(app).writeBytes(png) }
            }
        }
    }

    private suspend fun perform(status: String, body: suspend () -> String?) {
        activity = status
        try {
            message = body()
            error = null
        } catch (e: AdbException) {
            error = e.message
        } finally {
            activity = null
        }
    }

    suspend fun open(app: InstalledApp) = perform("Opening ${app.label}") {
        manager().launch(app)
        null
    }

    suspend fun stop(app: InstalledApp) = perform("Stopping ${app.label}") {
        manager().stop(app)
        "${app.label} was stopped."
    }

    suspend fun uninstall(app: InstalledApp) = perform("Uninstalling ${app.label}") {
        manager().uninstall(app)
        apps = apps.filter { it.packageName != app.packageName }
        if (app.isSystem) "${app.label} was removed. It's a built-in app, so a factory reset brings it back."
        else "${app.label} was uninstalled."
    }

    /** Copies the app's file(s) to the phone: one "<Name> <version>.apk", or ".apks" for split apps. */
    suspend fun saveAppFile(app: InstalledApp): File? {
        var result: File? = null
        perform("Copying ${app.label}") {
            val base = store.cacheDir("export").also { it.deleteRecursively(); it.mkdirs() }
            val parts = manager().extract(app, File(base, "parts").path) { bytes ->
                store.scope.launch { activity = "Copying ${app.label}: ${formatBytes(bytes)}" }
            }
            val name = "${app.label} ${app.versionName}".replace("/", "-")
            result = if (parts.size == 1) {
                File(base, "$name.apk").also { File(parts[0]).renameTo(it) }
            } else {
                File(base, "$name.apks").also { zip(it.path, parts) }
            }
            null
        }
        return result
    }

    /** Installs an app file the user picked (.apk, .apks, .xapk, .apkm), already copied to `file`. */
    suspend fun install(file: File, name: String) {
        perform("Preparing $name") {
            try {
                manager().install(file.path, store.cacheDir("install-parts").path) { status ->
                    store.scope.launch { activity = status }
                }
            } finally {
                file.delete()
            }
            "${name.substringBeforeLast('.')} was installed."
        }
        refresh()
    }
}

fun formatBytes(bytes: Long): String = when {
    bytes >= 1L shl 30 -> "%.1f GB".format(bytes / (1L shl 30).toDouble())
    bytes >= 1L shl 20 -> "%.1f MB".format(bytes / (1L shl 20).toDouble())
    bytes >= 1L shl 10 -> "%.0f KB".format(bytes / (1L shl 10).toDouble())
    else -> "$bytes bytes"
}
