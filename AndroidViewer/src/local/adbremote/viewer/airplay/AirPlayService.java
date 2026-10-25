package local.adbremote.viewer.airplay;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.graphics.Point;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.StrictMode;
import android.util.Log;
import android.view.Display;
import android.view.WindowManager;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;

/**
 * AirPlay screen mirroring receiver, started on demand from the iPhone app over ADB:
 *   am start-foreground-service -n local.adbremote.viewer/.airplay.AirPlayService --es name "Living Room"
 * While running, the TV appears in the iPhone's Screen Mirroring list. It stops by itself
 * after 10 minutes without mirroring, or with --es action stop.
 */
public final class AirPlayService extends Service implements AirPlayServer.Listener {
    private static final long IDLE_MS = 10 * 60 * 1000;

    private static AirPlayService running;

    private final Handler main = new Handler(Looper.getMainLooper());
    private AirPlayServer server;
    private Mdns mdns;
    private WifiManager.MulticastLock multicastLock;
    private WifiManager.WifiLock wifiLock;
    private String name;
    private volatile MirrorSource stream;
    private PhoneMirror phoneMirror;
    private volatile long lastActivity;

    static MirrorSource currentStream() {
        AirPlayService s = running;
        return s != null ? s.stream : null;
    }

    /** Ends the current mirroring session (Back on the TV remote). */
    static void stopMirroring() {
        AirPlayService s = running;
        if (s == null) return;
        MirrorSource current = s.stream;
        if (current instanceof PhoneMirror.Connection) {
            ((PhoneMirror.Connection) current).close();
            return;
        }
        // Restarting the receiver drops the iPhone's connection; it shows mirroring as stopped.
        s.restart();
    }

    @Override public IBinder onBind(Intent intent) { return null; }

    @Override
    public void onCreate() {
        super.onCreate();
        // Sockets are opened and closed on the main thread here; none of it blocks for long.
        StrictMode.setThreadPolicy(StrictMode.ThreadPolicy.LAX);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        goForeground();
        String action = intent != null ? intent.getStringExtra("action") : null;
        if ("stop".equals(action)) {
            stopSelf();
            return START_NOT_STICKY;
        }
        String requested = intent != null ? intent.getStringExtra("name") : null;
        if (requested != null && !requested.trim().isEmpty()) {
            requested = requested.trim();
            if (!requested.equals(name) && server != null) {
                name = requested;
                restart();
            }
            name = requested;
        }
        if (name == null) name = Build.MODEL;
        if (server == null) {
            try {
                begin();
            } catch (Exception e) {
                Log.e(AirPlayServer.TAG, "couldn't start: " + e);
                stopSelf();
                return START_NOT_STICKY;
            }
        }
        touch();
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        end();
        if (running == this) running = null;
        main.removeCallbacksAndMessages(null);
        super.onDestroy();
    }

    private void begin() throws Exception {
        running = this;
        WifiManager wifi = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
        if (wifi != null) {
            multicastLock = wifi.createMulticastLock("airplay");
            multicastLock.setReferenceCounted(false);
            multicastLock.acquire();
            wifiLock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "airplay");
            wifiLock.setReferenceCounted(false);
            wifiLock.acquire();
        }
        Inet4Address address = localAddress();
        if (address == null) throw new IOException("no network address");

        Display display = ((WindowManager) getSystemService(WINDOW_SERVICE)).getDefaultDisplay();
        Point size = new Point();
        if (Build.VERSION.SDK_INT >= 17) display.getRealSize(size); else display.getSize(size);
        int fps = Math.round(display.getRefreshRate());
        if (fps < 24 || fps > 60) fps = 60;

        String deviceId = deviceId();
        server = new AirPlayServer(this, this, name, deviceId, secretKey(), Math.max(size.x, size.y), Math.min(size.x, size.y), fps);
        int port = server.start();
        // Android phones mirror with plain H.264 + PCM on their own port (see PhoneMirror).
        phoneMirror = new PhoneMirror(this);
        try {
            phoneMirror.start();
        } catch (IOException e) {
            Log.w(AirPlayServer.TAG, "phone mirroring port unavailable: " + e);
            phoneMirror = null;
        }

        List<Mdns.Service> services = new ArrayList<Mdns.Service>();
        services.add(new Mdns.Service(name, "_airplay._tcp.local", port, server.airplayTxt()));
        services.add(new Mdns.Service(deviceId.replace(":", "") + "@" + name, "_raop._tcp.local", port, server.raopTxt()));
        String host = "adbremote-" + deviceId.replace(":", "").toLowerCase(Locale.US) + ".local";
        mdns = new Mdns(services, host, address);
        mdns.start();
        Log.i(AirPlayServer.TAG, "AirPlay \"" + name + "\" on " + address.getHostAddress() + ":" + port + " " + size.x + "x" + size.y + "@" + fps);
    }

    private void end() {
        if (mdns != null) { mdns.stop(); mdns = null; }
        if (server != null) { server.stop(); server = null; }
        if (phoneMirror != null) { phoneMirror.stop(); phoneMirror = null; }
        stream = null;
        MirrorActivity.close();
        if (multicastLock != null) { multicastLock.release(); multicastLock = null; }
        if (wifiLock != null) { wifiLock.release(); wifiLock = null; }
    }

    private void restart() {
        main.post(new Runnable() {
            @Override public void run() {
                end();
                try {
                    begin();
                } catch (Exception e) {
                    stopSelf();
                }
            }
        });
    }

    // MARK: Idle timeout

    private void touch() {
        lastActivity = System.currentTimeMillis();
        main.removeCallbacks(idleCheck);
        main.postDelayed(idleCheck, 60 * 1000);
    }

    private final Runnable idleCheck = new Runnable() {
        @Override public void run() {
            if (stream == null && System.currentTimeMillis() - lastActivity > IDLE_MS) {
                Log.i(AirPlayServer.TAG, "idle, stopping");
                stopSelf();
            } else {
                main.postDelayed(this, 60 * 1000);
            }
        }
    };

    // MARK: AirPlayServer.Listener

    @Override
    public void onMirrorStart(MirrorSource s) {
        stream = s;
        MediaActivity.stop();
        touch();
        Intent intent = new Intent(this, MirrorActivity.class);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        startActivity(intent);
    }

    /** A phone's mirroring connection ended; only the current one closes the screen. */
    void onPhoneMirrorStop(MirrorSource connection) {
        main.post(new Runnable() {
            @Override public void run() {
                if (stream == connection) onMirrorStop();
            }
        });
    }

    @Override
    public void onMirrorStop() {
        stream = null;
        touch();
        MirrorActivity.close();
    }

    @Override
    public void onActivity() {
        lastActivity = System.currentTimeMillis();
    }

    // MARK: Identity

    /** The receiver's Ed25519 key, kept so iPhones recognise the TV next time. */
    private byte[] secretKey() throws IOException {
        File file = new File(getFilesDir(), "airplay-key");
        if (file.length() == 64) {
            byte[] key = new byte[64];
            FileInputStream in = new FileInputStream(file);
            try {
                if (in.read(key) == 64) return key;
            } finally {
                in.close();
            }
        }
        byte[] key = Native.signKeypair();
        FileOutputStream out = new FileOutputStream(file);
        try { out.write(key); } finally { out.close(); }
        return key;
    }

    /** A made-up hardware address (Android hides the real one), fixed per install. */
    private String deviceId() throws IOException {
        File file = new File(getFilesDir(), "airplay-id");
        if (file.length() == 17) {
            byte[] b = new byte[17];
            FileInputStream in = new FileInputStream(file);
            try {
                if (in.read(b) == 17) return new String(b, "US-ASCII");
            } finally {
                in.close();
            }
        }
        byte[] mac = new byte[6];
        new SecureRandom().nextBytes(mac);
        mac[0] = (byte) ((mac[0] & 0xfe) | 0x02); // locally administered, unicast
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < 6; i++) sb.append(i == 0 ? "" : ":").append(String.format(Locale.US, "%02X", mac[i]));
        String id = sb.toString();
        FileOutputStream out = new FileOutputStream(file);
        try { out.write(id.getBytes("US-ASCII")); } finally { out.close(); }
        return id;
    }

    private static Inet4Address localAddress() throws IOException {
        Inet4Address fallback = null;
        for (NetworkInterface nif : Collections.list(NetworkInterface.getNetworkInterfaces())) {
            if (!nif.isUp() || nif.isLoopback()) continue;
            for (InetAddress a : Collections.list(nif.getInetAddresses())) {
                if (!(a instanceof Inet4Address)) continue;
                String n = nif.getName();
                if (n.startsWith("wlan") || n.startsWith("eth")) return (Inet4Address) a;
                if (fallback == null) fallback = (Inet4Address) a;
            }
        }
        return fallback;
    }

    // MARK: Foreground

    @SuppressWarnings("deprecation")
    private void goForeground() {
        if (Build.VERSION.SDK_INT < 26) return;
        NotificationManager manager = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        manager.createNotificationChannel(new NotificationChannel("airplay", "Screen mirroring", NotificationManager.IMPORTANCE_LOW));
        Notification notification = new Notification.Builder(this, "airplay")
                .setContentTitle("Ready for Screen Mirroring")
                .setSmallIcon(getResources().getIdentifier("ic_photos", "drawable", getPackageName()))
                .build();
        startForeground(2, notification);
    }
}
