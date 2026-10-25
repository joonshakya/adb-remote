package local.adbremote.android.model

import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import local.adbremote.android.bridge.AdbConnection
import local.adbremote.android.bridge.AdbException
import local.adbremote.android.bridge.DeviceExtras
import local.adbremote.android.bridge.DeviceInfo
import local.adbremote.android.bridge.FoundPort
import local.adbremote.android.bridge.PointerSender
import local.adbremote.android.bridge.RemoteInput
import local.adbremote.android.bridge.SpeedTestResult

/** Connection state and cached data for one saved device (same behaviour as the iOS app). */
class DeviceSession(val deviceID: String, private val store: DeviceStore) {
    sealed class State {
        data object Disconnected : State()
        data class Connecting(val message: String) : State()
        data object WaitingForApproval : State()
        data object Connected : State()
        data class Failed(val message: String) : State()
    }

    data class ScanState(val scanned: Int = 0, val total: Int = 1, val openPorts: List<Int> = emptyList()) {
        val probing get() = scanned >= total
    }

    var state by mutableStateOf<State>(State.Disconnected)
        private set
    var connection by mutableStateOf<AdbConnection?>(null)
        private set
    var info by mutableStateOf<DeviceInfo?>(null)
        private set
    var extras by mutableStateOf<DeviceExtras?>(null)
        private set
    var speedTest by mutableStateOf<SpeedTestResult?>(null)
    var speedTestStatus by mutableStateOf<String?>(null)

    /** The default port was refused: UI asks whether to scan. */
    var offerPortScan by mutableStateOf(false)
    var scan by mutableStateOf<ScanState?>(null)
        private set
    /** More than one ADB port found: UI lets the user pick. */
    var portChoices by mutableStateOf<List<FoundPort>>(emptyList())
    /** The device wants TLS but doesn't know our key: UI offers pairing. */
    var needsPairing by mutableStateOf(false)
    /** Result of the last quick port check (null = not checked yet). */
    var reachable by mutableStateOf<Boolean?>(null)
        private set

    var remoteReady by mutableStateOf(false)
        private set
    var remoteError by mutableStateOf<String?>(null)
    var remoteBackend by mutableStateOf<String?>(null)
        private set

    /** Latest round trip to adbd in seconds (null = not measured / no answer). */
    var latency by mutableStateOf<Double?>(null)
        private set
    var latencyTimedOut by mutableStateOf(false)
        private set

    private var wantsConnection = false
    /** Set by Disconnect so opening the app doesn't reconnect behind the user's back. */
    var userDisconnected = false
        private set
    private var scanJob: Job? = null
    private var pingJob: Job? = null
    private var watchJob: Job? = null
    private var lastError: Throwable? = null

    private var remote: RemoteInput? = null
    private var pointer: PointerSender? = null
    private var pointerJob: Job? = null
    private var remoteJob: Job? = null
    private var inputQueue: Channel<Pair<suspend (RemoteInput) -> Unit, Long>>? = null
    private var pendingInputs = 0

    private var apps: AppsModel? = null
    private var files: FilesModel? = null
    private var cast: CastModel? = null

    val device: SavedDevice? get() = store.device(deviceID)
    val isConnected get() = state == State.Connected
    val shouldAutoReconnect get() = wantsConnection && connection == null && !isBusy
    val isBusy get() = state is State.Connecting || state == State.WaitingForApproval || scan != null

    // MARK: Connect

    suspend fun connect() {
        val device = device ?: return
        if (isBusy) return
        wantsConnection = true
        userDisconnected = false
        needsPairing = false
        device.port?.let {
            connect(it)
            return
        }
        // Auto port: last working port, then 5555, then ask about scanning.
        val candidates = listOfNotNull(device.lastPort, 5555).distinct()
        for (port in candidates) {
            if (connect(port)) return
            if (state is State.Failed && !isUnreachable(lastError)) return
        }
        state = State.Failed("No ADB on port ${candidates.joinToString(", ")}")
        offerPortScan = true
    }

    private fun isUnreachable(error: Throwable?): Boolean {
        val message = error?.message ?: return true
        // AdbKit's connectionFailed / timeout / closed errors.
        return listOf("Connection failed", "Timed out", "closed", "Connection refused", "unreachable")
            .any { message.contains(it, ignoreCase = true) }
    }

    suspend fun connect(port: Int): Boolean {
        val device = device ?: return false
        state = State.Connecting("Connecting to ${device.host}:$port")
        lastError = null
        return try {
            val connection = AdbConnection.connect(device.host, port) {
                store.scope.launch { state = State.WaitingForApproval }
            }
            attach(connection, port)
            true
        } catch (e: AdbException) {
            lastError = e
            log("connect to port $port failed: ${e.message}")
            if (e.message?.contains("TLS", ignoreCase = true) == true) needsPairing = true
            state = State.Failed(e.message ?: "Failed")
            false
        }
    }

    private fun attach(connection: AdbConnection, port: Int) {
        this.connection = connection
        state = State.Connected
        log("connected to port $port${if (connection.usesTLS) " (encrypted)" else ""}")
        device?.let { if (it.port == null && it.lastPort != port) store.update(it.copy(lastPort = port)) }
        watchJob = store.scope.launch {
            val why = connection.waitForDisconnect()
            if (this@DeviceSession.connection !== connection) return@launch
            log("disconnected: $why")
            this@DeviceSession.connection = null
            resetRemote()
            state = State.Failed("Disconnected: $why")
        }
        startPinging(connection)
        store.scope.launch {
            if (checkAcceptsCommands(connection)) refreshInfo()
        }
    }

    /** Some devices keep the connection up but refuse everything once ADB access is switched
     *  off on them (BlueStacks does this). Pings still succeed then, so try a real command. */
    private suspend fun checkAcceptsCommands(connection: AdbConnection): Boolean = try {
        connection.shell("echo")
        true
    } catch (e: AdbException) {
        if (this.connection === connection) {
            log("connected but commands are refused: ${e.message}")
            wantsConnection = false
            this.connection = null
            resetRemote()
            connection.close()
            state = State.Failed("Connected, but ${device?.name ?: "the device"} is refusing commands. Turn its debugging access back on " +
                "(BlueStacks: Settings → Advanced → Android Debug Bridge; Android: Developer options → USB / Wireless debugging), then tap Retry.")
        }
        false
    }

    /** Measures latency every 2 s. "No reply" after 3 s; after 10 s the connection is treated
     *  as stuck and replaced (a stalled TCP connection can stay silent for minutes). */
    private fun startPinging(connection: AdbConnection) {
        pingJob?.cancel()
        latency = null
        latencyTimedOut = false
        pingJob = store.scope.launch {
            while (true) {
                val started = System.currentTimeMillis()
                val watchdog = launch {
                    delay(3000)
                    latency = null
                    latencyTimedOut = true
                    delay(7000)
                    replaceStalled(connection, started)
                }
                try {
                    val rtt = connection.ping(20.0)
                    watchdog.cancel()
                    latency = rtt
                    latencyTimedOut = false
                    log("ping ${(rtt * 1000).toInt()}ms")
                } catch (e: AdbException) {
                    watchdog.cancel()
                    if (this@DeviceSession.connection !== connection) return@launch
                    latency = null
                    latencyTimedOut = true
                    log("ping FAILED: ${e.message}")
                }
                delay(2000)
            }
        }
    }

    private fun replaceStalled(stalled: AdbConnection, started: Long) {
        // Time spent in the background doesn't count.
        if (connection !== stalled || store.lastBackgrounded >= started) return
        log("no reply for 10s, reconnecting")
        connection = null
        resetRemote()
        stalled.close()
        val port = device?.let { it.port ?: it.lastPort } ?: return
        store.scope.launch { connect(port) }
    }

    fun disconnect() {
        if (connection != null) log("disconnected by user")
        wantsConnection = false
        userDisconnected = true
        scanJob?.cancel()
        scan = null
        val c = connection
        connection = null
        resetRemote()
        c?.close()
        state = State.Disconnected
    }

    fun log(message: String) {
        Log.i("AdbRemote", "${device?.name ?: deviceID}: $message")
        EventLog.log(device?.name ?: deviceID, message)
    }

    // MARK: Feature models (made on first use, dropped with the connection)

    fun appsModel(): AppsModel? {
        apps?.let { return it }
        val c = connection ?: return null
        val sdk = info?.sdk ?: return null
        return AppsModel(c, sdk, store).also { apps = it }
    }

    fun castModel(): CastModel? {
        cast?.let { return it }
        val c = connection ?: return null
        val sdk = info?.sdk ?: return null
        val host = device?.host ?: return null
        return CastModel(store.context, c, host, sdk, store, ::log).also { cast = it }
    }

    fun filesModel(): FilesModel? {
        files?.let { return it }
        val c = connection ?: return null
        return FilesModel(c, store).also { files = it }
    }

    // MARK: Reachability

    /** Cheap TCP check of the device's ADB port, for the online/offline badge. */
    suspend fun checkReachability() {
        val device = device ?: return
        if (isConnected) {
            reachable = true
            return
        }
        val port = device.port ?: device.lastPort ?: 5555
        reachable = runCatching { AdbConnection.openPorts(device.host, listOf(port)).isNotEmpty() }.getOrDefault(false)
    }

    // MARK: Remote

    /** Starts the remote's input channel (scrcpy on Android 5+) the first time it's needed. */
    fun prepareRemote() {
        if (remote != null || remoteJob?.isActive == true) return
        val c = connection ?: return
        val sdk = info?.sdk ?: return
        remoteReady = false
        remoteJob = store.scope.launch {
            try {
                val r = RemoteInput.create(c, sdk, store.scrcpyServer, store.helperJar)
                if (connection !== c) {
                    r.close()
                    return@launch
                }
                remote = r
                remoteBackend = r.prepare()
                remoteReady = true
                remoteError = null
            } catch (e: AdbException) {
                remoteError = e.message
            }
        }
    }

    /** Trackpad sender, made once the remote is ready (null until then). */
    fun pointer(): PointerSender? {
        pointer?.let { return it }
        prepareRemote()
        val r = remote ?: return null
        val c = connection ?: return null
        val sdk = info?.sdk ?: return null
        val host = device?.host ?: return null
        if (pointerJob?.isActive != true) {
            pointerJob = store.scope.launch {
                try {
                    val p = PointerSender.create(r, c, host, sdk, store.viewerApk, store.helperJar)
                    if (remote === r) pointer = p
                } catch (e: AdbException) {
                    remoteError = e.message
                }
            }
        }
        return null
    }

    /** Queues a remote action; actions run one at a time in order (typing stays in order).
     *  A failed action restarts the input channel and is retried once. */
    fun sendInput(action: suspend (RemoteInput) -> Unit) {
        prepareRemote()
        val queue = inputQueue ?: Channel<Pair<suspend (RemoteInput) -> Unit, Long>>(Channel.UNLIMITED).also { channel ->
            inputQueue = channel
            store.scope.launch {
                for ((next, queued) in channel) {
                    remoteJob?.join()
                    val remote = remote
                    pendingInputs--
                    if (remote == null) continue
                    // A press that couldn't go out for a while is dropped, not sent late.
                    if (System.currentTimeMillis() - queued > 5000) {
                        log("input dropped after waiting ${System.currentTimeMillis() - queued}ms")
                        continue
                    }
                    val started = System.currentTimeMillis()
                    var outcome = "ok"
                    try {
                        next(remote)
                        remoteError = null
                    } catch (e: AdbException) {
                        outcome = "retried after ${e.message}"
                        remote.restart()
                        try {
                            next(remote)
                            remoteError = null
                        } catch (e: AdbException) {
                            outcome = "FAILED: ${e.message}"
                            remoteError = e.message
                        }
                    }
                    log("input waited ${started - queued}ms took ${System.currentTimeMillis() - started}ms via $remoteBackend $outcome")
                }
            }
        }
        pendingInputs++
        queue.trySend(action to System.currentTimeMillis())
    }

    private fun resetRemote() {
        pingJob?.cancel()
        pingJob = null
        watchJob?.cancel()
        watchJob = null
        latency = null
        latencyTimedOut = false
        inputQueue?.close()
        inputQueue = null
        pendingInputs = 0
        remoteJob?.cancel()
        remoteJob = null
        pointerJob?.cancel()
        pointerJob = null
        pointer = null
        remote?.close()
        remote = null
        remoteReady = false
        remoteBackend = null
        apps = null
        files = null
        cast?.disconnect()
        cast = null
        info = null
        extras = null
    }

    // MARK: Port scan

    fun startPortScan() {
        val device = device ?: return
        offerPortScan = false
        portChoices = emptyList()
        scan = ScanState()
        state = State.Connecting("Scanning ${device.host} for open ports")
        scanJob = store.scope.launch {
            try {
                val found = AdbConnection.findAdbPorts(device.host, listOfNotNull(device.lastPort)) { scanned, total, open ->
                    store.scope.launch { if (scan != null) scan = ScanState(scanned, total, open) }
                }
                scan = null
                when (found.size) {
                    0 -> state = State.Failed("No ADB port found on ${device.host}. Enable network debugging on the device.")
                    1 -> if (!connect(found[0].port) && found[0].tls) needsPairing = true
                    else -> {
                        portChoices = found
                        state = State.Disconnected
                    }
                }
            } catch (e: AdbException) {
                scan = null
                state = State.Failed(e.message ?: "Scan failed")
            }
        }
    }

    fun cancelScan() {
        scanJob?.cancel()
        scan = null
        state = State.Disconnected
    }

    // MARK: Info

    suspend fun refreshInfo() {
        val c = connection ?: return
        try {
            val info = c.info()
            this.info = info
            extras = c.extras(info.sdk)
        } catch (e: AdbException) {
            log("info failed: ${e.message}")
        }
    }

    suspend fun runSpeedTest() {
        val c = connection ?: return
        speedTest = null
        speedTestStatus = "Starting"
        // Old devices (4 KB packets) are slow; keep their test short.
        val bytes = if ((info?.sdk ?: 30) < 21) 1024 * 1024 else 8 * 1024 * 1024
        try {
            speedTest = c.speedTest(bytes) { status -> store.scope.launch { speedTestStatus = status } }
            speedTestStatus = null
        } catch (e: AdbException) {
            speedTestStatus = "Failed: ${e.message}"
        }
    }

    // MARK: Pairing

    suspend fun pair(port: Int, code: String) {
        val device = device ?: return
        AdbConnection.pair(device.host, port, code)
        needsPairing = false
    }
}
