package local.adbremote.viewer.airplay;

import java.io.ByteArrayOutputStream;
import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Apple binary property lists ("bplist00"), as used in AirPlay requests and replies.
 * Values map to Java as: dict = Map<String, Object>, array = List<Object>, string = String,
 * data = byte[], integer = Long, real = Double, boolean = Boolean.
 */
final class Bplist {
    private static final Charset ASCII = Charset.forName("US-ASCII");
    private static final Charset UTF16 = Charset.forName("UTF-16BE");
    private static final Charset UTF8 = Charset.forName("UTF-8");

    private Bplist() {}

    // MARK: Reading

    /** True for a binary plist ("bplist00..."), whatever the Content-Type says. */
    static boolean isBinary(byte[] b) {
        return b != null && b.length >= 8 && b[0] == 'b' && b[1] == 'p' && b[2] == 'l' && b[3] == 'i'
                && b[4] == 's' && b[5] == 't';
    }

    static Object parse(byte[] b) {
        if (b == null || b.length < 40 || !new String(b, 0, 8, ASCII).equals("bplist00")) {
            throw new IllegalArgumentException("not a binary plist");
        }
        int t = b.length - 32;
        int offsetSize = b[t + 6] & 0xff;
        int refSize = b[t + 7] & 0xff;
        int count = (int) uint(b, t + 8, 8);
        int top = (int) uint(b, t + 16, 8);
        int table = (int) uint(b, t + 24, 8);
        int[] offsets = new int[count];
        for (int i = 0; i < count; i++) offsets[i] = (int) uint(b, table + i * offsetSize, offsetSize);
        return new Reader(b, offsets, refSize).read(top);
    }

    private static final class Reader {
        final byte[] b;
        final int[] offsets;
        final int refSize;

        Reader(byte[] b, int[] offsets, int refSize) {
            this.b = b;
            this.offsets = offsets;
            this.refSize = refSize;
        }

        Object read(int ref) {
            int at = offsets[ref];
            int marker = b[at] & 0xff;
            int type = marker >> 4;
            int info = marker & 0x0f;
            switch (type) {
                case 0x0:
                    if (info == 0x8) return Boolean.FALSE;
                    if (info == 0x9) return Boolean.TRUE;
                    return null;
                case 0x1: {
                    int n = 1 << info;
                    long v = uint(b, at + 1, Math.min(n, 8));
                    return v;
                }
                case 0x2: {
                    int n = 1 << info;
                    long bits = uint(b, at + 1, n);
                    return n == 4 ? (double) Float.intBitsToFloat((int) bits) : Double.longBitsToDouble(bits);
                }
                case 0x3:
                    return Double.longBitsToDouble(uint(b, at + 1, 8));
                default:
                    break;
            }
            int[] start = {at + 1};
            int length = info == 0xf ? (int) readInt(start) : info;
            int p = start[0];
            switch (type) {
                case 0x4: {
                    byte[] out = new byte[length];
                    System.arraycopy(b, p, out, 0, length);
                    return out;
                }
                case 0x5:
                    return new String(b, p, length, ASCII);
                case 0x6:
                    return new String(b, p, length * 2, UTF16);
                case 0x7:
                    return new String(b, p, length, UTF8);
                case 0xa: {
                    List<Object> list = new ArrayList<Object>();
                    for (int i = 0; i < length; i++) list.add(read((int) uint(b, p + i * refSize, refSize)));
                    return list;
                }
                case 0xd: {
                    Map<String, Object> map = new LinkedHashMap<String, Object>();
                    for (int i = 0; i < length; i++) {
                        Object key = read((int) uint(b, p + i * refSize, refSize));
                        Object value = read((int) uint(b, p + (length + i) * refSize, refSize));
                        map.put(String.valueOf(key), value);
                    }
                    return map;
                }
                default:
                    return null;
            }
        }

        /** An integer object used as a length (after a 0xf length nibble). */
        long readInt(int[] at) {
            int marker = b[at[0]] & 0xff;
            int n = 1 << (marker & 0x0f);
            long v = uint(b, at[0] + 1, n);
            at[0] += 1 + n;
            return v;
        }
    }

    private static long uint(byte[] b, int at, int n) {
        long v = 0;
        for (int i = 0; i < n; i++) v = (v << 8) | (b[at + i] & 0xff);
        return v;
    }

    // MARK: Writing

    static byte[] write(Object root) {
        List<Object> objects = new ArrayList<Object>();
        flatten(root, objects);
        int count = objects.size();
        int refSize = count < 256 ? 1 : 2;
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write('b'); out.write('p'); out.write('l'); out.write('i');
        out.write('s'); out.write('t'); out.write('0'); out.write('0');
        int[] offsets = new int[count];
        for (int i = 0; i < count; i++) {
            offsets[i] = out.size();
            writeObject(out, objects.get(i), objects, refSize);
        }
        int table = out.size();
        int offsetSize = table < 256 ? 1 : table < 65536 ? 2 : 4;
        for (int offset : offsets) putUint(out, offset, offsetSize);
        for (int i = 0; i < 6; i++) out.write(0);
        out.write(offsetSize);
        out.write(refSize);
        putUint(out, count, 8);
        putUint(out, 0, 8);
        putUint(out, table, 8);
        return out.toByteArray();
    }

    /** Lists every object once (containers before their contents); refs are list indexes. */
    @SuppressWarnings("unchecked")
    private static void flatten(Object o, List<Object> objects) {
        objects.add(o);
        if (o instanceof Map) {
            Map<String, Object> map = (Map<String, Object>) o;
            for (String key : map.keySet()) flatten(new Key(key), objects);
            for (Object value : map.values()) flatten(value, objects);
        } else if (o instanceof List) {
            for (Object item : (List<Object>) o) flatten(item, objects);
        }
    }

    /** Dict keys get their own objects, even when equal to a value elsewhere. */
    private static final class Key {
        final String s;
        Key(String s) { this.s = s; }
    }

    @SuppressWarnings("unchecked")
    private static void writeObject(ByteArrayOutputStream out, Object o, List<Object> objects, int refSize) {
        if (o instanceof Key) o = ((Key) o).s;
        if (o instanceof Boolean) {
            out.write((Boolean) o ? 0x09 : 0x08);
        } else if (o instanceof Long || o instanceof Integer) {
            long v = ((Number) o).longValue();
            if (v >= 0 && v < 256) { out.write(0x10); putUint(out, v, 1); }
            else if (v >= 0 && v < 65536) { out.write(0x11); putUint(out, v, 2); }
            else if (v >= 0 && v < 4294967296L) { out.write(0x12); putUint(out, v, 4); }
            else { out.write(0x13); putUint(out, v, 8); }
        } else if (o instanceof Double || o instanceof Float) {
            out.write(0x23);
            putUint(out, Double.doubleToLongBits(((Number) o).doubleValue()), 8);
        } else if (o instanceof byte[]) {
            byte[] data = (byte[]) o;
            header(out, 0x4, data.length);
            out.write(data, 0, data.length);
        } else if (o instanceof String) {
            String s = (String) o;
            boolean ascii = true;
            for (int i = 0; i < s.length(); i++) if (s.charAt(i) > 0x7f) ascii = false;
            if (ascii) {
                byte[] bytes = s.getBytes(ASCII);
                header(out, 0x5, bytes.length);
                out.write(bytes, 0, bytes.length);
            } else {
                byte[] bytes = s.getBytes(UTF16);
                header(out, 0x6, s.length());
                out.write(bytes, 0, bytes.length);
            }
        } else if (o instanceof Map) {
            Map<String, Object> map = (Map<String, Object>) o;
            header(out, 0xd, map.size());
            int self = indexOf(objects, o);
            // Keys follow the dict in flatten order, then each value's subtree.
            int next = self + 1;
            int[] keyRefs = new int[map.size()];
            for (int i = 0; i < keyRefs.length; i++) keyRefs[i] = next++;
            int[] valueRefs = new int[map.size()];
            int i = 0;
            for (Object value : map.values()) {
                valueRefs[i++] = next;
                next += size(value);
            }
            for (int ref : keyRefs) putUint(out, ref, refSize);
            for (int ref : valueRefs) putUint(out, ref, refSize);
        } else if (o instanceof List) {
            List<Object> list = (List<Object>) o;
            header(out, 0xa, list.size());
            int next = indexOf(objects, o) + 1;
            for (Object item : list) {
                putUint(out, next, refSize);
                next += size(item);
            }
        } else {
            out.write(0x00);
        }
    }

    /** Number of objects in o's subtree, including o. */
    @SuppressWarnings("unchecked")
    private static int size(Object o) {
        int n = 1;
        if (o instanceof Map) {
            Map<String, Object> map = (Map<String, Object>) o;
            n += map.size();
            for (Object value : map.values()) n += size(value);
        } else if (o instanceof List) {
            for (Object item : (List<Object>) o) n += size(item);
        }
        return n;
    }

    private static int indexOf(List<Object> objects, Object o) {
        for (int i = 0; i < objects.size(); i++) if (objects.get(i) == o) return i;
        return -1;
    }

    private static void header(ByteArrayOutputStream out, int type, int length) {
        if (length < 15) {
            out.write((type << 4) | length);
        } else {
            out.write((type << 4) | 0xf);
            if (length < 256) { out.write(0x10); putUint(out, length, 1); }
            else if (length < 65536) { out.write(0x11); putUint(out, length, 2); }
            else { out.write(0x12); putUint(out, length, 4); }
        }
    }

    private static void putUint(ByteArrayOutputStream out, long v, int n) {
        for (int i = n - 1; i >= 0; i--) out.write((int) (v >>> (8 * i)) & 0xff);
    }

    // MARK: XML (the AirPlay video requests use text plists)

    static byte[] xml(Object root) {
        StringBuilder sb = new StringBuilder();
        sb.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
        sb.append("<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n");
        sb.append("<plist version=\"1.0\">\n");
        xmlValue(sb, root);
        sb.append("</plist>\n");
        return sb.toString().getBytes(UTF8);
    }

    @SuppressWarnings("unchecked")
    private static void xmlValue(StringBuilder sb, Object o) {
        if (o instanceof Map) {
            sb.append("<dict>\n");
            for (Map.Entry<String, Object> e : ((Map<String, Object>) o).entrySet()) {
                sb.append("<key>").append(escape(e.getKey())).append("</key>\n");
                xmlValue(sb, e.getValue());
            }
            sb.append("</dict>\n");
        } else if (o instanceof List) {
            sb.append("<array>\n");
            for (Object item : (List<Object>) o) xmlValue(sb, item);
            sb.append("</array>\n");
        } else if (o instanceof Boolean) {
            sb.append((Boolean) o ? "<true/>\n" : "<false/>\n");
        } else if (o instanceof Double || o instanceof Float) {
            sb.append("<real>").append(((Number) o).doubleValue()).append("</real>\n");
        } else if (o instanceof Number) {
            sb.append("<integer>").append(((Number) o).longValue()).append("</integer>\n");
        } else if (o instanceof byte[]) {
            sb.append("<data>").append(android.util.Base64.encodeToString((byte[]) o, android.util.Base64.NO_WRAP)).append("</data>\n");
        } else {
            sb.append("<string>").append(escape(String.valueOf(o))).append("</string>\n");
        }
    }

    private static String escape(String s) {
        return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;");
    }

    // MARK: Helpers for reading values

    @SuppressWarnings("unchecked")
    static Map<String, Object> dict(Object o) {
        return o instanceof Map ? (Map<String, Object>) o : new LinkedHashMap<String, Object>();
    }

    static long number(Object o, long fallback) {
        return o instanceof Number ? ((Number) o).longValue() : fallback;
    }

    static double real(Object o, double fallback) {
        return o instanceof Number ? ((Number) o).doubleValue() : fallback;
    }
}
