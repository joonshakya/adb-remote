package local.adbremote.android.bridge

import org.json.JSONObject

// Kotlin faces of AdbKit's types. Each wraps a number the Swift side keeps the real object under.

class ShellResult(val stdout: String, val stderr: String, val exitCode: Int?)

class DeviceInfo(
    val name: String,
    val sdk: Int,
    val isTV: Boolean,
    val rows: List<Pair<String, String>>,
    val advanced: List<Pair<String, String>>,
)

class Capability(val name: String, val supported: Boolean, val note: String)

class DeviceExtras(
    val rootAnswer: String,
    val rootExplanation: String,
    val rootDetails: List<Pair<String, String>>,
    val play: String,
    /** Play Store version ("" = not installed). */
    val playStore: String,
    val playServices: Boolean,
    val googlePackages: List<String>,
    val capabilities: List<Capability>,
    val adbFeatures: List<String>,
)

class SpeedTestResult(val upload: Double, val download: Double, val latency: Double, val bytes: Int)

class RemoteFile(val name: String, val size: Long, val modified: Long, val isDirectory: Boolean, val isSymlink: Boolean, val isFile: Boolean)

class FoundPort(val port: Int, val tls: Boolean)

class InstalledApp(
    val packageName: String,
    val label: String,
    val versionName: String,
    val versionCode: Long,
    val isSystem: Boolean,
    val isEnabled: Boolean,
    val isLaunchable: Boolean,
)

class AdbConnection private constructor(val id: Int, val usesTLS: Boolean) {
    companion object {
        /** `onApproval` runs (on a background thread) if the device asks its user to allow this key. */
        suspend fun connect(host: String, port: Int, onApproval: () -> Unit = {}): AdbConnection {
            var told = false
            val reply = Adb.call("connect", "host" to host, "port" to port, onProgress = {
                if (!told && it.optBoolean("waitingForApproval")) {
                    told = true
                    onApproval()
                }
            }).json
            return AdbConnection(reply.getInt("id"), reply.optBoolean("usesTLS"))
        }

        /** Returns the paired device's name. */
        suspend fun pair(host: String, port: Int, code: String): String =
            Adb.call("pair", "host" to host, "port" to port, "code" to code).json.optString("name")

        suspend fun openPorts(host: String, ports: List<Int>, timeout: Double = 0.8): List<Int> =
            Adb.call("openPorts", "host" to host, "ports" to ports, "timeout" to timeout).json.getJSONArray("open").ints()

        suspend fun findAdbPorts(host: String, preferred: List<Int>, onProgress: (scanned: Int, total: Int, open: List<Int>) -> Unit): List<FoundPort> =
            Adb.call("findAdbPorts", "host" to host, "preferred" to preferred, onProgress = {
                onProgress(it.optInt("scanned"), it.optInt("total", 1), it.optJSONArray("open")?.ints() ?: emptyList())
            }).json.getJSONArray("found").objects().map { FoundPort(it.getInt("port"), it.getBoolean("tls")) }
    }

    fun close() {
        runCatching { Adb.callNow("close", JSONObject().put("id", id)) }
    }

    /** Suspends until the connection drops; returns why. */
    suspend fun waitForDisconnect(): String = try {
        Adb.call("waitDisconnect", "id" to id).json.optString("error")
    } catch (e: AdbException) {
        e.message ?: "closed"
    }

    suspend fun ping(timeout: Double = 5.0): Double = Adb.call("ping", "id" to id, "timeout" to timeout).json.getDouble("seconds")

    suspend fun shell(command: String): ShellResult {
        val r = Adb.call("shell", "id" to id, "command" to command).json
        return ShellResult(r.optString("stdout"), r.optString("stderr"), if (r.has("exit")) r.getInt("exit") else null)
    }

    suspend fun info(): DeviceInfo {
        val r = Adb.call("info", "id" to id).json
        return DeviceInfo(r.getString("name"), r.getInt("sdk"), r.getBoolean("isTV"),
            r.getJSONArray("rows").pairs(), r.getJSONArray("advanced").pairs())
    }

    suspend fun extras(sdk: Int): DeviceExtras {
        val r = Adb.call("extras", "id" to id, "sdk" to sdk).json
        val root = r.getJSONObject("root")
        return DeviceExtras(
            root.getString("answer"), root.getString("explanation"), root.getJSONArray("details").pairs(),
            r.getString("play"), r.optString("playStore"), r.optBoolean("playServices"),
            r.optJSONArray("googlePackages")?.strings() ?: emptyList(),
            r.getJSONArray("capabilities").objects().map { Capability(it.getString("name"), it.getBoolean("supported"), it.getString("note")) },
            r.getJSONArray("adbFeatures").strings(),
        )
    }

    suspend fun speedTest(bytes: Int, onStatus: (String) -> Unit): SpeedTestResult {
        val r = Adb.call("speedTest", "id" to id, "bytes" to bytes, onProgress = { onStatus(it.optString("status")) }).json
        return SpeedTestResult(r.getDouble("upload"), r.getDouble("download"), r.getDouble("latency"), r.getInt("bytes"))
    }

    suspend fun list(path: String): List<RemoteFile> =
        Adb.call("filesList", "id" to id, "path" to path).json.getJSONArray("list").objects().map {
            RemoteFile(it.getString("name"), it.getLong("size"), (it.getDouble("modified") * 1000).toLong(),
                it.getBoolean("dir"), it.getBoolean("link"), it.getBoolean("file"))
        }

    /** Whether `path` is a directory (follows symlinks); null if it doesn't exist. */
    suspend fun isDirectory(path: String): Boolean? {
        val r = Adb.call("filesStat", "id" to id, "path" to "$path/.").json
        return if (r.getBoolean("exists")) r.getBoolean("dir") else null
    }

    suspend fun pull(remote: String, local: String, onBytes: (Long) -> Unit = {}) {
        Adb.call("filesPull", "id" to id, "remote" to remote, "local" to local, onProgress = { onBytes(it.optLong("bytes")) })
    }

    suspend fun push(local: String, remote: String, onBytes: (Long) -> Unit = {}) {
        Adb.call("filesPush", "id" to id, "local" to local, "remote" to remote, onProgress = { onBytes(it.optLong("bytes")) })
    }

    suspend fun screenshot(): ByteArray = Adb.call("screenshot", "id" to id).data
}

/** Keys, text and mouse for one device (scrcpy control channel on Android 5+). */
class RemoteInput private constructor(val id: Int, val supportsMouse: Boolean) {
    companion object {
        suspend fun create(adb: AdbConnection, sdk: Int, serverJar: String, helperJar: String): RemoteInput {
            val r = Adb.call("remoteCreate", "id" to adb.id, "sdk" to sdk, "serverJar" to serverJar, "helperJar" to helperJar).json
            return RemoteInput(r.getInt("remote"), r.getBoolean("mouse"))
        }
    }

    /** Returns the backend name ("scrcpy", "injector" or "input"). */
    suspend fun prepare(): String = Adb.call("remotePrepare", "remote" to id).json.optString("backend")

    suspend fun press(keycode: Int, meta: Int = 0, longPress: Boolean = false) {
        Adb.call("remotePress", "remote" to id, "keycode" to keycode, "meta" to meta, "long" to longPress)
    }

    suspend fun type(text: String) {
        Adb.call("remoteType", "remote" to id, "text" to text)
    }

    suspend fun mouse(dx: Int, dy: Int, buttons: Int, wheel: Int = 0, pan: Int = 0) {
        Adb.call("remoteMouse", "remote" to id, "dx" to dx, "dy" to dy, "buttons" to buttons, "wheel" to wheel, "pan" to pan)
    }

    /** Drops the control channel; the next action starts a new one. */
    fun restart() {
        runCatching { Adb.callNow("remoteRestart", JSONObject().put("remote", id)) }
    }

    fun close() {
        runCatching { Adb.callNow("remoteClose", JSONObject().put("remote", id)) }
    }
}

class AppManager private constructor(val id: Int) {
    companion object {
        suspend fun create(adb: AdbConnection, sdk: Int, helperJar: String): AppManager =
            AppManager(Adb.call("appsCreate", "id" to adb.id, "sdk" to sdk, "helperJar" to helperJar).json.getInt("apps"))
    }

    suspend fun list(): List<InstalledApp> =
        Adb.call("appsList", "apps" to id).json.getJSONArray("list").objects().map {
            InstalledApp(it.getString("package"), it.getString("label"), it.getString("versionName"), it.getLong("versionCode"),
                it.getBoolean("system"), it.getBoolean("enabled"), it.getBoolean("launchable"))
        }

    /** PNG bytes per package. */
    suspend fun icons(packages: List<String>, size: Int = 96): Map<String, ByteArray> {
        val reply = Adb.call("appsIcons", "apps" to id, "packages" to packages, "size" to size)
        val index = reply.json.getJSONObject("icons")
        return index.keys().asSequence().associateWith { name ->
            val at = index.getJSONArray(name)
            reply.data.copyOfRange(at.getInt(0), at.getInt(0) + at.getInt(1))
        }
    }

    suspend fun launch(app: InstalledApp) { Adb.call("appsLaunch", "apps" to id, "package" to app.packageName) }
    suspend fun stop(app: InstalledApp) { Adb.call("appsStop", "apps" to id, "package" to app.packageName) }
    suspend fun uninstall(app: InstalledApp) { Adb.call("appsUninstall", "apps" to id, "package" to app.packageName) }

    /** Installs an .apk, or a bundle (.apks/.xapk/.apkm). */
    suspend fun install(path: String, workDir: String, onStatus: (String) -> Unit) {
        Adb.call("appsInstall", "apps" to id, "path" to path, "workDir" to workDir, onProgress = { onStatus(it.optString("status")) })
    }

    /** Downloads the app's APK file(s) into `dir`. */
    suspend fun extract(app: InstalledApp, dir: String, onBytes: (Long) -> Unit): List<String> =
        Adb.call("appsExtract", "apps" to id, "package" to app.packageName, "dir" to dir, onProgress = { onBytes(it.optLong("bytes")) })
            .json.getJSONArray("paths").strings()

    fun close() {
        // The manager holds nothing on the device; Swift drops it with the connection.
    }
}

suspend fun zip(path: String, files: List<String>) {
    Adb.call("zip", "path" to path, "paths" to files)
}

/** A scrcpy session streaming the device's screen as H.264 and taking touches. */
class ScreenSession private constructor(val id: Int) {
    sealed class Event {
        class Size(val width: Int, val height: Int) : Event()
        class Config(val data: ByteArray) : Event()
        class Frame(val data: ByteArray, val pts: Long, val keyFrame: Boolean) : Event()
        data object End : Event()
    }

    companion object {
        suspend fun start(adb: AdbConnection, serverJar: String, maxSize: Int, bitRate: Int, maxFps: Int): ScreenSession =
            ScreenSession(Adb.call("screenStart", "id" to adb.id, "serverJar" to serverJar,
                "maxSize" to maxSize, "bitRate" to bitRate, "maxFps" to maxFps).json.getInt("screen"))
    }

    /** Blocking read of the next video event; call from one background thread. */
    fun next(): Event {
        val r = Adb.callNow("screenNext", JSONObject().put("screen", id))
        return when (r.json.optString("type")) {
            "size" -> Event.Size(r.json.getInt("width"), r.json.getInt("height"))
            "config" -> Event.Config(r.data)
            "frame" -> Event.Frame(r.data, r.json.getLong("pts"), r.json.getBoolean("key"))
            else -> Event.End
        }
    }

    suspend fun touch(action: Int, x: Int, y: Int, width: Int, height: Int, pointer: Int = 0) {
        Adb.call("screenTouch", "screen" to id, "action" to action, "x" to x, "y" to y, "width" to width, "height" to height, "pointer" to pointer)
    }

    suspend fun scroll(x: Int, y: Int, width: Int, height: Int, horizontal: Double, vertical: Double) {
        Adb.call("screenScroll", "screen" to id, "x" to x, "y" to y, "width" to width, "height" to height,
            "horizontal" to horizontal, "vertical" to vertical)
    }

    suspend fun key(keycode: Int) { Adb.call("screenKey", "screen" to id, "keycode" to keycode) }

    fun close() {
        runCatching { Adb.callNow("screenClose", JSONObject().put("screen", id)) }
    }

    object Touch {
        const val DOWN = 0
        const val UP = 1
        const val MOVE = 2
    }
}

/** Android KeyEvent codes the remote uses (same numbers as AdbKit's Keycode). */
object Keycode {
    const val HOME = 3; const val BACK = 4
    const val DPAD_UP = 19; const val DPAD_DOWN = 20; const val DPAD_LEFT = 21; const val DPAD_RIGHT = 22; const val DPAD_CENTER = 23
    const val VOLUME_UP = 24; const val VOLUME_DOWN = 25; const val POWER = 26
    const val TAB = 61; const val SPACE = 62; const val ENTER = 66; const val DEL = 67
    const val MENU = 82; const val SEARCH = 84
    const val MEDIA_PLAY_PAUSE = 85; const val MEDIA_NEXT = 87; const val MEDIA_PREVIOUS = 88
    const val MEDIA_REWIND = 89; const val MEDIA_FAST_FORWARD = 90
    const val ESCAPE = 111; const val FORWARD_DEL = 112
    const val MUTE = 164; const val CHANNEL_UP = 166; const val CHANNEL_DOWN = 167
    const val SETTINGS = 176; const val TV_INPUT = 178; const val APP_SWITCH = 187
    fun function(n: Int) = 130 + n
}

/** The TV viewer app connection (AdbKit's ViewerClient). Events arrive through `nextEvents`. */
class ViewerClient private constructor(val id: Int, val direct: Boolean, val tv: TV) {
    data class TV(val sdk: Int, val longSide: Int, val hevc: Boolean)

    sealed class Event {
        data class Ready(val id: Int) : Event()
        data class Shown(val id: Int) : Event()
        data class PhotoFailed(val id: Int) : Event()
        data class Playing(val id: Int) : Event()
        data class Ended(val id: Int) : Event()
        data class VideoFailed(val id: Int, val why: String) : Event()
        data class Time(val id: Int, val position: Double, val duration: Double, val playing: Boolean) : Event()
        data class Read(val id: Int, val request: Int, val offset: Long, val length: Int) : Event()
        data object Closed : Event()
    }

    companion object {
        const val PACKAGE = "local.adbremote.viewer"

        /** Installs or updates the TV app if needed (without opening it). */
        suspend fun installIfNeeded(adb: AdbConnection, sdk: Int, apk: String, helperJar: String, onStatus: (String) -> Unit) {
            Adb.call("viewerInstall", "id" to adb.id, "sdk" to sdk, "apk" to apk, "helperJar" to helperJar,
                onProgress = { onStatus(it.optString("status")) })
        }

        suspend fun connect(adb: AdbConnection, host: String, sdk: Int, apk: String, helperJar: String,
                            onStatus: (String) -> Unit): ViewerClient {
            val r = Adb.call("castConnect", "id" to adb.id, "host" to host, "sdk" to sdk, "apk" to apk, "helperJar" to helperJar,
                onProgress = { onStatus(it.optString("status")) }).json
            return ViewerClient(r.getInt("cast"), r.getBoolean("direct"),
                TV(r.getInt("sdk"), r.getInt("longSide"), r.getBoolean("hevc")))
        }
    }

    /** Blocking: waits for the TV's next messages. Call from one background thread. */
    fun nextEvents(): List<Event> = try {
        Adb.callNow("castEvents", JSONObject().put("cast", id)).json.getJSONArray("events").objects().map {
            val i = it.optInt("id")
            when (it.getString("type")) {
                "ready" -> Event.Ready(i)
                "shown" -> Event.Shown(i)
                "photoFailed" -> Event.PhotoFailed(i)
                "playing" -> Event.Playing(i)
                "ended" -> Event.Ended(i)
                "videoFailed" -> Event.VideoFailed(i, it.optString("why"))
                "time" -> Event.Time(i, it.getDouble("position"), it.getDouble("duration"), it.getBoolean("playing"))
                "read" -> Event.Read(i, it.getInt("request"), it.getLong("offset"), it.getInt("length"))
                else -> Event.Closed
            }
        }
    } catch (e: AdbException) {
        listOf(Event.Closed)
    }

    private fun send(op: String, params: JSONObject = JSONObject(), input: ByteArray? = null) {
        runCatching { Adb.callNow(op, params.put("cast", id), input) }
    }

    fun sendPhoto(photo: Int, jpeg: ByteArray) = send("castPhoto", JSONObject().put("photo", photo), jpeg)
    fun show(photo: Int) = send("castShow", JSONObject().put("photo", photo))
    fun playVideo(video: Int, size: Long, mime: String) = send("castVideo", JSONObject().put("video", video).put("size", size).put("mime", mime))
    fun sendData(request: Int, data: ByteArray) = send("castData", JSONObject().put("requestId", request), data)
    fun pause() = send("castPause")
    fun resume() = send("castResume")
    fun seek(seconds: Double) = send("castSeek", JSONObject().put("seconds", seconds))
    fun zoom(photo: Int, scale: Double, u: Double, v: Double) =
        send("castZoom", JSONObject().put("photo", photo).put("scale", scale).put("u", u).put("v", v))
    fun clear() = send("castClear")
    fun closeViewer() = send("castCloseViewer")
    fun disconnect() = send("castDisconnect")
}

object Links {
    /** youtu.be/…, /shorts/…, m.youtube.com/… → https://www.youtube.com/watch?v=… (null if not a YouTube video). */
    fun youtubeWatchURL(url: String): String? =
        runCatching { Adb.callNow("youtubeWatchURL", JSONObject().put("url", url)).json.optString("url").ifEmpty { null } }.getOrNull()

    /** kind: "youtube", "web" or "text". Returns e.g. "Playing in YouTube". */
    suspend fun open(adb: AdbConnection, kind: String, value: String, onStatus: (String) -> Unit = {}): String =
        Adb.call("openLink", "id" to adb.id, "kind" to kind, "value" to value, onProgress = { onStatus(it.optString("status")) })
            .json.optString("message")
}

/** A raw ADB stream (e.g. "tcp:7200": a port on the device, reached through ADB). Blocking calls. */
class AdbStream private constructor(val id: Int) {
    companion object {
        fun open(adb: AdbConnection, service: String): AdbStream =
            AdbStream(Adb.callNow("streamOpen", JSONObject().put("id", adb.id).put("service", service)).json.getInt("stream"))
    }

    fun write(data: ByteArray) {
        Adb.callNow("streamWrite", JSONObject().put("stream", id), data)
    }

    /** Next bytes, or null once the stream closed. */
    fun read(): ByteArray? = try {
        val r = Adb.callNow("streamRead", JSONObject().put("stream", id))
        if (r.json.optBoolean("closed")) null else r.data
    } catch (e: AdbException) {
        null
    }

    fun close() {
        runCatching { Adb.callNow("streamClose", JSONObject().put("stream", id)) }
    }
}

/** Trackpad motion for a device (AdbKit's PointerSender): virtual mouse, or a pointer the TV app draws. */
class PointerSender private constructor(val id: Int) {
    companion object {
        suspend fun create(remote: RemoteInput, adb: AdbConnection, host: String, sdk: Int, apk: String, helperJar: String): PointerSender =
            PointerSender(Adb.call("pointerCreate", "remote" to remote.id, "id" to adb.id, "host" to host, "sdk" to sdk,
                "apk" to apk, "helperJar" to helperJar).json.getInt("pointer"))
    }

    /** Each call returns the latest problem sending (null when it works). */
    private fun send(op: String, params: JSONObject = JSONObject()): String? = try {
        Adb.callNow(op, params.put("pointer", id)).json.optString("problem").ifEmpty { null }
    } catch (e: AdbException) {
        e.message
    }

    fun move(dx: Double, dy: Double) = send("pointerMove", JSONObject().put("dx", dx).put("dy", dy))
    fun scroll(dx: Double, dy: Double) = send("pointerScroll", JSONObject().put("dx", dx).put("dy", dy))
    fun setButtons(buttons: Int) = send("pointerButtons", JSONObject().put("buttons", buttons))
    fun click(button: Int) = send("pointerClick", JSONObject().put("button", button))
    fun hide() = send("pointerHide")
}
