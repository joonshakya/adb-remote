package local.adbremote.android

import android.app.Application
import local.adbremote.android.model.DeviceStore

class AdbRemoteApplication : Application() {
    val store: DeviceStore by lazy { DeviceStore(this) }
}
