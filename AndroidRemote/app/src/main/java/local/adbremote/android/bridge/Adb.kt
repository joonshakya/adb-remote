package local.adbremote.android.bridge

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.Executors

class AdbException(message: String) : Exception(message)

class Reply(val json: JSONObject, val data: ByteArray)

/**
 * Calls into AdbKit. Each call blocks a pool thread inside Swift; the coroutine waits for it.
 * Cancelling the coroutine tells Swift to cancel the call (the thread is freed when it stops).
 */
object Adb {
    private val pool = Executors.newCachedThreadPool { r -> Thread(r, "adb-bridge").apply { isDaemon = true } }

    /** Blocking call; for use on background threads only. */
    fun callNow(op: String, params: JSONObject = JSONObject(), input: ByteArray? = null): Reply {
        params.put("op", op)
        val raw = Native.call(params.toString(), input)
        val length = ByteBuffer.wrap(raw, 0, 4).int
        val json = JSONObject(String(raw, 4, length, Charsets.UTF_8))
        val data = raw.copyOfRange(4 + length, raw.size)
        json.optString("error").takeIf { it.isNotEmpty() }?.let { throw AdbException(it) }
        return Reply(json, data)
    }

    suspend fun call(
        op: String,
        vararg params: Pair<String, Any?>,
        input: ByteArray? = null,
        onProgress: ((JSONObject) -> Unit)? = null,
    ): Reply = coroutineScope {
        val request = UUID.randomUUID().toString()
        val json = JSONObject()
        for ((key, value) in params) {
            if (value != null) json.put(key, if (value is List<*>) JSONArray(value) else value)
        }
        json.put("request", request)
        val result = CompletableDeferred<Reply>()
        pool.execute {
            try {
                result.complete(callNow(op, json, input))
            } catch (e: Throwable) {
                result.completeExceptionally(e)
            }
        }
        val poller = onProgress?.let { report ->
            launch(Dispatchers.IO) {
                while (isActive) {
                    delay(250)
                    val progress = runCatching { callNow("progress", JSONObject().put("request", request)).json }.getOrNull()
                    if (progress != null && progress.length() > 0 && isActive) report(progress)
                }
            }
        }
        try {
            result.await()
        } catch (e: CancellationException) {
            runCatching { callNow("cancel", JSONObject().put("request", request)) }
            throw e
        } finally {
            poller?.cancel()
        }
    }

    fun init(keyPath: String, name: String): String =
        callNow("init", JSONObject().put("keyPath", keyPath).put("name", name)).json.getString("publicKey")
}

fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }
fun JSONArray.strings(): List<String> = (0 until length()).map { getString(it) }
fun JSONArray.ints(): List<Int> = (0 until length()).map { getInt(it) }
fun JSONArray.pairs(): List<Pair<String, String>> =
    (0 until length()).map { getJSONArray(it).let { p -> p.getString(0) to p.getString(1) } }
