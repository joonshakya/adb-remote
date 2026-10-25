package local.adbremote.helper;

import android.os.SystemClock;
import android.util.Base64;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.MotionEvent;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.PrintStream;
import java.lang.reflect.Method;

/**
 * Long-running key injector for devices without scrcpy (Android 4.x). Each `input keyevent`
 * starts a new VM (1-2 s on a busy TV); this process starts once and injects in ~1 ms.
 *
 * Reads one command per line from stdin:
 *   K keycode metaState longPress(0/1)
 *   T base64-utf8-text
 *   P action x y           touch at a screen pixel: 0 = down, 1 = up, 2 = move
 *   W x y horizontal vertical   mouse-wheel scroll at a screen pixel
 * Prints READY once, then nothing unless a command fails (ERR ...).
 */
final class InputServer {
    private final Object inputManager;
    private final Method inject;

    InputServer() throws Exception {
        Class<?> cls = Class.forName("android.hardware.input.InputManager");
        inputManager = cls.getMethod("getInstance").invoke(null);
        inject = cls.getMethod("injectInputEvent", InputEvent.class, int.class);
    }

    void run(PrintStream out) throws Exception {
        out.println("READY");
        out.flush();
        BufferedReader reader = new BufferedReader(new InputStreamReader(System.in, "UTF-8"));
        String line;
        while ((line = reader.readLine()) != null) {
            line = line.trim();
            if (line.isEmpty()) continue;
            if (line.equals("Q")) break;
            try {
                String[] f = line.split(" ");
                if (f[0].equals("K")) {
                    key(Integer.parseInt(f[1]), Integer.parseInt(f[2]), f.length > 3 && f[3].equals("1"));
                } else if (f[0].equals("P") && f.length >= 4) {
                    touch(Integer.parseInt(f[1]), Float.parseFloat(f[2]), Float.parseFloat(f[3]));
                } else if (f[0].equals("W") && f.length >= 5) {
                    scroll(Float.parseFloat(f[1]), Float.parseFloat(f[2]), Float.parseFloat(f[3]), Float.parseFloat(f[4]));
                } else if (f[0].equals("T") && f.length > 1) {
                    text(new String(Base64.decode(f[1], Base64.DEFAULT), "UTF-8"));
                }
            } catch (Throwable t) {
                out.println("ERR " + t);
                out.flush();
            }
        }
    }

    private void key(int keycode, int meta, boolean longPress) throws Exception {
        long now = SystemClock.uptimeMillis();
        boolean ctrl = (meta & KeyEvent.META_CTRL_ON) != 0;
        if (ctrl) send(new KeyEvent(now, now, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_CTRL_LEFT, 0, KeyEvent.META_CTRL_ON | KeyEvent.META_CTRL_LEFT_ON));
        send(new KeyEvent(now, now, KeyEvent.ACTION_DOWN, keycode, 0, meta));
        if (longPress) {
            Thread.sleep(600);
            send(new KeyEvent(now, SystemClock.uptimeMillis(), KeyEvent.ACTION_DOWN, keycode, 1, meta,
                    KeyCharacterMap.VIRTUAL_KEYBOARD, 0, KeyEvent.FLAG_LONG_PRESS));
        }
        send(new KeyEvent(now, SystemClock.uptimeMillis(), KeyEvent.ACTION_UP, keycode, 0, meta));
        if (ctrl) send(new KeyEvent(now, SystemClock.uptimeMillis(), KeyEvent.ACTION_UP, KeyEvent.KEYCODE_CTRL_LEFT, 0, 0));
    }

    private long touchDown;

    /** A finger on the screen at (x, y): what a click with the pointer turns into. */
    private void touch(int action, float x, float y) throws Exception {
        long now = SystemClock.uptimeMillis();
        if (action == MotionEvent.ACTION_DOWN) touchDown = now;
        MotionEvent event = MotionEvent.obtain(touchDown, now, action, x, y, 0);
        event.setSource(InputDevice.SOURCE_TOUCHSCREEN);
        inject.invoke(inputManager, event, 0);
        event.recycle();
    }

    /** Wheel scroll at (x, y), like a mouse wheel over that spot. */
    private void scroll(float x, float y, float horizontal, float vertical) throws Exception {
        long now = SystemClock.uptimeMillis();
        MotionEvent.PointerProperties[] props = { new MotionEvent.PointerProperties() };
        props[0].id = 0;
        props[0].toolType = MotionEvent.TOOL_TYPE_MOUSE;
        MotionEvent.PointerCoords[] coords = { new MotionEvent.PointerCoords() };
        coords[0].x = x;
        coords[0].y = y;
        coords[0].setAxisValue(MotionEvent.AXIS_HSCROLL, horizontal);
        coords[0].setAxisValue(MotionEvent.AXIS_VSCROLL, vertical);
        MotionEvent event = MotionEvent.obtain(now, now, MotionEvent.ACTION_SCROLL, 1, props, coords,
                0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_MOUSE, 0);
        inject.invoke(inputManager, event, 0);
        event.recycle();
    }

    /** Same approach as `input text`: map characters to key events with the virtual keyboard map. */
    private void text(String text) throws Exception {
        KeyCharacterMap map = KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD);
        KeyEvent[] events = map.getEvents(text.toCharArray());
        if (events == null) {
            // Characters the keyboard map can't produce (emoji, other scripts).
            long now = SystemClock.uptimeMillis();
            send(new KeyEvent(now, text, KeyCharacterMap.VIRTUAL_KEYBOARD, 0));
            return;
        }
        for (KeyEvent event : events) send(KeyEvent.changeTimeRepeat(event, SystemClock.uptimeMillis(), 0));
    }

    private void send(KeyEvent event) throws Exception {
        if (event.getSource() == InputDevice.SOURCE_UNKNOWN) event.setSource(InputDevice.SOURCE_KEYBOARD);
        // 0 = INJECT_INPUT_EVENT_MODE_ASYNC
        inject.invoke(inputManager, event, 0);
    }
}
