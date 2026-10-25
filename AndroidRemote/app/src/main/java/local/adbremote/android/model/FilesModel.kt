package local.adbremote.android.model

import android.webkit.MimeTypeMap
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.launch
import local.adbremote.android.bridge.AdbConnection
import local.adbremote.android.bridge.AdbException
import local.adbremote.android.bridge.RemoteFile
import java.io.File
import java.util.UUID

/** File browser state for one connected device. */
class FilesModel(private val adb: AdbConnection, private val store: DeviceStore) {
    data class Location(val name: String, val path: String)

    var locations by mutableStateOf<List<Location>>(emptyList())
        private set
    var error by mutableStateOf<String?>(null)
    var activity by mutableStateOf<String?>(null)
        private set
    var message by mutableStateOf<String?>(null)

    companion object {
        const val HOME = "/sdcard"

        fun join(folder: String, name: String) = if (folder == "/") "/$name" else "$folder/$name"

        fun quote(s: String) = "'" + s.replace("'", "'\\''") + "'"

        fun progressText(label: String, bytes: Long, total: Long) =
            if (total > 0) "$label: ${formatBytes(bytes)} of ${formatBytes(total)}" else "$label: ${formatBytes(bytes)}"
    }

    fun title(path: String): String = when {
        path == HOME -> "Internal Storage"
        path == "/" -> "Whole System"
        else -> locations.firstOrNull { it.path == path }?.name ?: path.substringAfterLast('/')
    }

    // MARK: Listing

    /** Folders first, then files, by name. */
    suspend fun list(path: String): List<RemoteFile> {
        if (locations.isEmpty()) loadLocations()
        // Trailing slash makes LIST follow symlinks such as /sdcard.
        val listing = adb.list(if (path.endsWith("/")) path else "$path/")
        return listing.sortedWith(compareBy<RemoteFile> { !it.isDirectory }.thenBy { it.name.lowercase() })
    }

    /** Shortcuts: common folders plus any USB drives / SD cards under /storage. */
    private suspend fun loadLocations() {
        val list = mutableListOf(
            Location("Internal Storage", HOME),
            Location("Downloads", "/sdcard/Download"),
            Location("Movies", "/sdcard/Movies"),
            Location("Pictures", "/sdcard/Pictures"),
        )
        runCatching { adb.list("/storage/") }.getOrNull()?.forEach { entry ->
            if (entry.isDirectory && entry.name !in listOf("emulated", "self", "sdcard0", "sdcard1")) {
                list.add(Location("USB / SD (${entry.name})", "/storage/${entry.name}"))
            }
        }
        list.add(Location("Whole System", "/"))
        locations = list
    }

    // MARK: Actions

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

    private suspend fun run(command: String) {
        val result = adb.shell(command)
        if (result.exitCode != null && result.exitCode != 0) {
            throw AdbException((result.stderr + result.stdout).trim().ifEmpty { "Command failed" })
        }
    }

    suspend fun createFolder(name: String, folder: String) = perform("Creating folder") {
        run("mkdir -p ${quote(join(folder, name))}")
        null
    }

    suspend fun rename(entry: RemoteFile, folder: String, name: String) = perform("Renaming") {
        run("mv ${quote(join(folder, entry.name))} ${quote(join(folder, name))}")
        null
    }

    suspend fun delete(entry: RemoteFile, folder: String) = perform("Deleting ${entry.name}") {
        run("rm -rf ${quote(join(folder, entry.name))}")
        null
    }

    /** Copies a file from the device into the app's cache, for saving or sharing. */
    suspend fun download(entry: RemoteFile, folder: String): File? {
        var result: File? = null
        perform("Copying ${entry.name}") {
            val dir = store.cacheDir("download-${UUID.randomUUID()}")
            val file = File(dir, entry.name)
            adb.pull(join(folder, entry.name), file.path) { bytes ->
                store.scope.launch { activity = progressText("Copying ${entry.name}", bytes, entry.size) }
            }
            result = file
            null
        }
        return result
    }

    /** Uploads local copies of picked files (name to file) into `folder`, deleting the copies after. */
    suspend fun upload(files: List<Pair<String, File>>, folder: String) = perform("Uploading") {
        try {
            for ((index, item) in files.withIndex()) {
                val (name, file) = item
                val label = if (files.size > 1) "Uploading ${index + 1} of ${files.size}" else "Uploading $name"
                adb.push(file.path, join(folder, name)) { bytes ->
                    store.scope.launch { activity = progressText(label, bytes, file.length()) }
                }
            }
        } finally {
            files.forEach { it.second.delete() }
        }
        if (files.size == 1) "${files[0].first} was uploaded." else "${files.size} files were uploaded."
    }

    /** Asks the device to open a media file in its default app. */
    suspend fun openOnDevice(entry: RemoteFile, folder: String) = perform("Opening ${entry.name}") {
        val ext = entry.name.substringAfterLast('.', "").lowercase()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "*/*"
        val output = adb.shell("am start -a android.intent.action.VIEW -d ${quote("file://" + join(folder, entry.name))} -t ${quote(mime)}").stdout
        if (output.contains("Error")) throw AdbException("No app on the device can open this file.")
        null
    }
}
