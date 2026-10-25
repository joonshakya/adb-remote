package local.adbremote.helper;

import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.BitmapDrawable;
import android.graphics.drawable.Drawable;
import android.os.Build;
import android.os.Looper;
import android.util.Base64;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.InputStreamReader;
import java.io.PrintStream;
import java.util.List;

/**
 * Runs on the device as the shell user via app_process:
 *   CLASSPATH=/data/local/tmp/adbremote-helper.jar app_process / local.adbremote.helper.Main list
 *
 * Commands (output is one tab-separated record per line, fields have tabs/newlines removed):
 *   list              -> APP pkg label versionName versionCode system(0/1) enabled(0/1) launchComponent
 *   icons size [pkg...] -> ICON pkg base64-png for each package (from args, else stdin)
 *   input             -> long-running key injector, see InputServer
 *   done marker: END
 */
public final class Main {
    private static PrintStream out;

    public static void main(String[] args) throws Exception {
        out = new PrintStream(System.out, false, "UTF-8");
        if (args.length > 0 && "input".equals(args[0])) {
            try {
                new InputServer().run(out);
            } catch (Throwable t) {
                out.println("ERR\t" + clean(String.valueOf(t)));
            }
            out.flush();
            System.exit(0);
        }
        try {
            PackageManager pm = systemContext().getPackageManager();
            String command = args.length > 0 ? args[0] : "list";
            if ("list".equals(command)) {
                list(pm);
            } else if ("icons".equals(command)) {
                int size = args.length > 1 ? Integer.parseInt(args[1]) : 96;
                if (args.length > 2) {
                    for (int i = 2; i < args.length; i++) icon(pm, args[i], size);
                } else {
                    icons(pm, size);
                }
            } else {
                out.println("ERR\tunknown command " + command);
            }
        } catch (Throwable t) {
            out.println("ERR\t" + clean(String.valueOf(t)));
        }
        out.println("END");
        out.flush();
        System.exit(0);
    }

    /** A system Context gives a working PackageManager without being an installed app. */
    private static Context systemContext() throws Exception {
        if (Looper.getMainLooper() == null) {
            Looper.prepareMainLooper();
        }
        Class<?> activityThread = Class.forName("android.app.ActivityThread");
        Object thread = activityThread.getMethod("systemMain").invoke(null);
        return (Context) activityThread.getMethod("getSystemContext").invoke(thread);
    }

    private static void list(PackageManager pm) {
        List<PackageInfo> packages = pm.getInstalledPackages(0);
        for (PackageInfo info : packages) {
            ApplicationInfo app = info.applicationInfo;
            if (app == null) continue;
            String label;
            try {
                label = String.valueOf(app.loadLabel(pm));
            } catch (Throwable t) {
                label = info.packageName;
            }
            boolean system = (app.flags & (ApplicationInfo.FLAG_SYSTEM | ApplicationInfo.FLAG_UPDATED_SYSTEM_APP)) != 0;
            long versionCode = Build.VERSION.SDK_INT >= 28 ? info.getLongVersionCode() : info.versionCode;
            out.println("APP\t" + clean(info.packageName) + "\t" + clean(label) + "\t"
                    + clean(info.versionName) + "\t" + versionCode + "\t" + (system ? 1 : 0) + "\t"
                    + (app.enabled ? 1 : 0) + "\t" + clean(launchComponent(pm, info.packageName)));
        }
    }

    /** Prefers the TV (leanback) launcher activity, then the phone launcher activity. */
    private static String launchComponent(PackageManager pm, String pkg) {
        Intent intent = null;
        try {
            if (Build.VERSION.SDK_INT >= 21) intent = pm.getLeanbackLaunchIntentForPackage(pkg);
            if (intent == null) intent = pm.getLaunchIntentForPackage(pkg);
        } catch (Throwable ignored) {
        }
        if (intent == null || intent.getComponent() == null) return "";
        return intent.getComponent().flattenToShortString();
    }

    private static void icons(PackageManager pm, int size) throws Exception {
        BufferedReader reader = new BufferedReader(new InputStreamReader(System.in, "UTF-8"));
        String pkg;
        while ((pkg = reader.readLine()) != null) {
            pkg = pkg.trim();
            if (pkg.isEmpty()) continue;
            if (pkg.equals("END")) break;
            icon(pm, pkg, size);
        }
    }

    private static void icon(PackageManager pm, String pkg, int size) {
        try {
            Drawable icon = pm.getApplicationIcon(pkg);
            out.println("ICON\t" + pkg + "\t" + encode(icon, size));
        } catch (Throwable t) {
            out.println("ICON\t" + pkg + "\t");
        }
        out.flush();
    }

    private static String encode(Drawable drawable, int size) {
        Bitmap bitmap;
        if (drawable instanceof BitmapDrawable && ((BitmapDrawable) drawable).getBitmap() != null) {
            bitmap = Bitmap.createScaledBitmap(((BitmapDrawable) drawable).getBitmap(), size, size, true);
        } else {
            bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888);
            Canvas canvas = new Canvas(bitmap);
            drawable.setBounds(0, 0, size, size);
            drawable.draw(canvas);
        }
        ByteArrayOutputStream png = new ByteArrayOutputStream();
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, png);
        return Base64.encodeToString(png.toByteArray(), Base64.NO_WRAP);
    }

    private static String clean(CharSequence s) {
        if (s == null) return "";
        return s.toString().replace('\t', ' ').replace('\n', ' ').replace('\r', ' ');
    }
}
