package local.adbremote.viewer;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.graphics.PixelFormat;
import android.graphics.Point;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.view.Display;
import android.view.Gravity;
import android.view.WindowManager;
import android.widget.ImageView;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;

/**
 * Draws a mouse pointer over everything, for devices where the phone can't add a real
 * (virtual USB) mouse. The phone moves it and does the clicking itself.
 *
 * Listens on TCP port 38791, one command per line:
 *   SIZE        -> SIZE width height   (screen pixels, current rotation)
 *   POS x y     move the pointer's tip to (x, y)
 *   HIDE        remove the pointer and stop
 */
public final class PointerService extends Service {
    static final int PORT = 38791;

    private final Handler main = new Handler(Looper.getMainLooper());
    private WindowManager windows;
    private ImageView pointer;
    private WindowManager.LayoutParams params;
    private ServerSocket listener;
    private volatile boolean running;

    @Override public IBinder onBind(Intent intent) { return null; }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        goForeground();
        if (pointer == null) addPointer();
        if (!running) startServer();
        return START_NOT_STICKY;
    }

    /** Android 8+ only lets a service keep running in the background as a foreground service. */
    @SuppressWarnings("deprecation")
    private void goForeground() {
        if (Build.VERSION.SDK_INT < 26) return;
        NotificationManager manager = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        manager.createNotificationChannel(new NotificationChannel("pointer", "Trackpad pointer", NotificationManager.IMPORTANCE_LOW));
        Notification notification = new Notification.Builder(this, "pointer")
                .setContentTitle("Trackpad from iPhone")
                .setSmallIcon(getResources().getIdentifier("ic_photos", "drawable", getPackageName()))
                .build();
        startForeground(1, notification);
    }

    @SuppressWarnings("deprecation")
    private void addPointer() {
        windows = (WindowManager) getSystemService(WINDOW_SERVICE);
        pointer = new ImageView(this);
        pointer.setImageResource(getResources().getIdentifier("ic_cursor", "drawable", getPackageName()));
        float dp = getResources().getDisplayMetrics().density;
        int type = Build.VERSION.SDK_INT >= 26
                ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                : WindowManager.LayoutParams.TYPE_SYSTEM_OVERLAY;
        params = new WindowManager.LayoutParams((int) (30 * dp), (int) (45 * dp), type,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                        | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
                        | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT);
        params.gravity = Gravity.TOP | Gravity.LEFT;
        Point size = screenSize();
        params.x = size.x / 2;
        params.y = size.y / 2;
        windows.addView(pointer, params);
    }

    @SuppressWarnings("deprecation")
    private Point screenSize() {
        Display display = ((WindowManager) getSystemService(WINDOW_SERVICE)).getDefaultDisplay();
        Point size = new Point();
        if (Build.VERSION.SDK_INT >= 17) display.getRealSize(size); else display.getSize(size);
        return size;
    }

    private void move(final int x, final int y) {
        main.post(new Runnable() {
            @Override public void run() {
                if (pointer == null) return;
                params.x = x;
                params.y = y;
                windows.updateViewLayout(pointer, params);
            }
        });
    }

    private void startServer() {
        running = true;
        new Thread("pointer-server") {
            @Override public void run() {
                try {
                    listener = new ServerSocket();
                    listener.setReuseAddress(true);
                    listener.bind(new InetSocketAddress(PORT));
                    while (running) handle(listener.accept());
                } catch (IOException ignored) {
                }
            }
        }.start();
    }

    private void handle(Socket socket) {
        try {
            socket.setTcpNoDelay(true);
            BufferedReader in = new BufferedReader(new InputStreamReader(socket.getInputStream(), "UTF-8"));
            OutputStream out = socket.getOutputStream();
            String line;
            while ((line = in.readLine()) != null) {
                String[] f = line.trim().split(" ");
                if (f[0].equals("SIZE")) {
                    Point size = screenSize();
                    out.write(("SIZE " + size.x + " " + size.y + "\n").getBytes("UTF-8"));
                    out.flush();
                } else if (f[0].equals("POS") && f.length >= 3) {
                    move(Integer.parseInt(f[1]), Integer.parseInt(f[2]));
                } else if (f[0].equals("HIDE")) {
                    main.post(new Runnable() {
                        @Override public void run() { stopSelf(); }
                    });
                    break;
                }
            }
        } catch (Exception ignored) {
        } finally {
            try { socket.close(); } catch (IOException ignored) {}
        }
    }

    @Override
    public void onDestroy() {
        running = false;
        try { if (listener != null) listener.close(); } catch (IOException ignored) {}
        if (pointer != null) windows.removeView(pointer);
        pointer = null;
        super.onDestroy();
    }
}
