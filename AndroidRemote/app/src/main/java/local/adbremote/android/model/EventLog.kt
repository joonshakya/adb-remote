package local.adbremote.android.model

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/**
 * Per-device timeline of pings, key presses and connection events, so lag can be traced
 * afterwards (same as the iOS app's). Files live in the app's cache as "logs/<device>.log";
 * each grows to 2 MB and then the older half moves to "<device>.old.log".
 */
object EventLog {
    private val writer = Executors.newSingleThreadExecutor()
    private val time = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSXXX", Locale.US)
    private const val MAX_SIZE = 2 * 1024 * 1024
    private lateinit var directory: File

    fun init(context: Context) {
        directory = File(context.cacheDir, "logs")
    }

    fun file(device: String): File = File(directory, device.map { if (it.isLetterOrDigit()) it else '_' }.joinToString("") + ".log")

    fun log(device: String, message: String) {
        if (!::directory.isInitialized) return
        val line = "${time.format(Date())} $message\n"
        writer.execute {
            directory.mkdirs()
            val file = file(device)
            if (file.length() > MAX_SIZE) {
                val old = File(directory, file.nameWithoutExtension + ".old.log")
                old.delete()
                file.renameTo(old)
            }
            file.appendText(line)
        }
    }
}
