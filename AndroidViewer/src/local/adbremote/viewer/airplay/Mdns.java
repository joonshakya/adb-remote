package local.adbremote.viewer.airplay;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.net.DatagramPacket;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.MulticastSocket;
import java.net.NetworkInterface;
import java.net.SocketTimeoutException;
import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;

/**
 * A small Bonjour (multicast DNS) responder: makes the AirPlay services visible to
 * iPhones on the same network. NsdManager can't set TXT records before Android 5.
 */
final class Mdns {
    static final class Service {
        final String instance;
        final String type;
        final int port;
        final byte[] txt;

        Service(String instance, String type, int port, List<String> txt) {
            this.instance = instance;
            this.type = type;
            this.port = port;
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            for (String entry : txt) {
                byte[] bytes = entry.getBytes(UTF8);
                out.write(bytes.length);
                out.write(bytes, 0, bytes.length);
            }
            this.txt = out.toByteArray();
        }

        String fullName() { return instance + "." + type; }
    }

    private static final Charset UTF8 = Charset.forName("UTF-8");
    private static final String GROUP = "224.0.0.251";
    private static final int PORT = 5353;
    private static final int PTR = 12, SRV = 33, TXT = 16, A = 1, ANY = 255;

    private final List<Service> services;
    private final String host;
    private final Inet4Address address;
    private MulticastSocket socket;
    private volatile boolean running;

    Mdns(List<Service> services, String host, Inet4Address address) {
        this.services = services;
        this.host = host;
        this.address = address;
    }

    void start() throws IOException {
        socket = new MulticastSocket(null);
        socket.setReuseAddress(true);
        socket.bind(new InetSocketAddress(PORT));
        NetworkInterface nif = NetworkInterface.getByInetAddress(address);
        if (nif != null) socket.setNetworkInterface(nif);
        socket.joinGroup(InetAddress.getByName(GROUP));
        socket.setTimeToLive(255);
        socket.setSoTimeout(1000);
        running = true;
        new Thread("mdns") {
            @Override public void run() { loop(); }
        }.start();
    }

    void stop() {
        running = false;
        new Thread("mdns-goodbye") {
            @Override public void run() {
                // Goodbye: TTL 0 tells listeners to forget the services now.
                try { send(everything(0), null); } catch (Exception ignored) {}
                if (socket != null) socket.close();
            }
        }.start();
    }

    private void loop() {
        long[] announceAt = {System.currentTimeMillis(), System.currentTimeMillis() + 1000, System.currentTimeMillis() + 3000};
        int announced = 0;
        byte[] buffer = new byte[9000];
        while (running) {
            long now = System.currentTimeMillis();
            if (announced < announceAt.length && now >= announceAt[announced]) {
                try { send(everything(-1), null); } catch (IOException ignored) {}
                announced++;
            }
            try {
                DatagramPacket packet = new DatagramPacket(buffer, buffer.length);
                socket.receive(packet);
                answer(packet);
            } catch (SocketTimeoutException ignored) {
            } catch (Exception e) {
                if (!running) return;
            }
        }
    }

    // MARK: Answering

    private void answer(DatagramPacket packet) throws IOException {
        byte[] b = packet.getData();
        int len = packet.getLength();
        if (len < 12) return;
        int flags = u16(b, 2);
        if ((flags & 0x8000) != 0) return; // a response, not a query
        int questions = u16(b, 4);
        int[] at = {12};
        Records answers = new Records();
        boolean unicast = packet.getPort() != PORT;
        for (int q = 0; q < questions && at[0] < len; q++) {
            String name = readName(b, at, len).toLowerCase(Locale.US);
            if (at[0] + 4 > len) return;
            int type = u16(b, at[0]);
            int qclass = u16(b, at[0] + 2);
            at[0] += 4;
            if ((qclass & 0x8000) != 0) unicast = true;
            for (Service s : services) {
                if (name.equals(s.type.toLowerCase(Locale.US)) && (type == PTR || type == ANY)) {
                    answers.ptr(s);
                } else if (name.equals(s.fullName().toLowerCase(Locale.US))) {
                    if (type == SRV || type == ANY) answers.srv(s);
                    if (type == TXT || type == ANY) answers.txt(s);
                } else if (name.equals("_services._dns-sd._udp.local") && (type == PTR || type == ANY)) {
                    answers.serviceType(s);
                }
            }
            if (name.equals(host.toLowerCase(Locale.US)) && (type == A || type == ANY)) answers.a();
        }
        if (answers.count == 0) return;
        // Anything asked about a service also needs the address to connect to.
        answers.additionalForServices();
        send(answers, unicast ? new InetSocketAddress(packet.getAddress(), packet.getPort()) : null);
    }

    private Records everything(int ttl) {
        Records r = new Records();
        r.ttlOverride = ttl;
        for (Service s : services) {
            r.ptr(s);
            r.srv(s);
            r.txt(s);
        }
        r.a();
        return r;
    }

    private void send(Records records, InetSocketAddress to) throws IOException {
        byte[] data = records.packet();
        InetSocketAddress target = to != null ? to : new InetSocketAddress(GROUP, PORT);
        socket.send(new DatagramPacket(data, data.length, target));
    }

    /** Builds a response packet (answers only; additional records go in as answers too, which is allowed). */
    private final class Records {
        final ByteArrayOutputStream body = new ByteArrayOutputStream();
        final List<Service> withSrv = new ArrayList<Service>();
        int count;
        int ttlOverride = -1;
        boolean hasA;

        void ptr(Service s) {
            record(s.type, PTR, false, 4500, name(s.fullName()));
            if (!withSrv.contains(s)) withSrv.add(s);
        }

        void serviceType(Service s) {
            record("_services._dns-sd._udp.local", PTR, false, 4500, name(s.type));
        }

        void srv(Service s) {
            ByteArrayOutputStream rdata = new ByteArrayOutputStream();
            rdata.write(0); rdata.write(0); // priority
            rdata.write(0); rdata.write(0); // weight
            rdata.write(s.port >> 8); rdata.write(s.port & 0xff);
            byte[] target = name(host);
            rdata.write(target, 0, target.length);
            record(s.fullName(), SRV, true, 120, rdata.toByteArray());
        }

        void txt(Service s) {
            record(s.fullName(), TXT, true, 4500, s.txt);
        }

        void a() {
            if (hasA) return;
            hasA = true;
            record(host, A, true, 120, address.getAddress());
        }

        void additionalForServices() {
            for (Service s : new ArrayList<Service>(withSrv)) {
                srv(s);
                txt(s);
            }
            a();
        }

        private void record(String owner, int type, boolean unique, int ttl, byte[] rdata) {
            byte[] n = name(owner);
            body.write(n, 0, n.length);
            put16(body, type);
            put16(body, unique ? 0x8001 : 0x0001); // cache-flush bit for records only we own
            int t = ttlOverride >= 0 ? ttlOverride : ttl;
            put16(body, t >>> 16);
            put16(body, t & 0xffff);
            put16(body, rdata.length);
            body.write(rdata, 0, rdata.length);
            count++;
        }

        byte[] packet() {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            put16(out, 0);       // id
            put16(out, 0x8400);  // response, authoritative
            put16(out, 0);       // questions
            put16(out, count);   // answers
            put16(out, 0);
            put16(out, 0);
            byte[] b = body.toByteArray();
            out.write(b, 0, b.length);
            return out.toByteArray();
        }
    }

    // MARK: Names

    /** "a.b.local" as DNS labels. */
    private static byte[] name(String dotted) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        // The instance name may contain dots only in theory; split on the service suffix instead.
        List<String> labels = splitName(dotted);
        for (String label : labels) {
            byte[] bytes = label.getBytes(UTF8);
            int n = Math.min(bytes.length, 63);
            out.write(n);
            out.write(bytes, 0, n);
        }
        out.write(0);
        return out.toByteArray();
    }

    /** Splits a name into labels; the first label of "<instance>._x._tcp.local" may contain dots. */
    private static List<String> splitName(String dotted) {
        List<String> labels = new ArrayList<String>();
        int service = dotted.indexOf("._");
        String rest = dotted;
        if (service > 0 && !dotted.startsWith("_")) {
            labels.add(dotted.substring(0, service));
            rest = dotted.substring(service + 1);
        }
        Collections.addAll(labels, rest.split("\\."));
        return labels;
    }

    private static String readName(byte[] b, int[] at, int len) {
        StringBuilder out = new StringBuilder();
        int p = at[0];
        boolean jumped = false;
        int guard = 0;
        while (p < len && guard++ < 128) {
            int n = b[p] & 0xff;
            if (n == 0) {
                p++;
                break;
            }
            if ((n & 0xc0) == 0xc0) {
                if (p + 1 >= len) break;
                int target = ((n & 0x3f) << 8) | (b[p + 1] & 0xff);
                if (!jumped) at[0] = p + 2;
                jumped = true;
                p = target;
                continue;
            }
            if (out.length() > 0) out.append('.');
            out.append(new String(b, p + 1, Math.min(n, len - p - 1), UTF8));
            p += n + 1;
        }
        if (!jumped) at[0] = p;
        return out.toString();
    }

    private static int u16(byte[] b, int at) {
        return ((b[at] & 0xff) << 8) | (b[at + 1] & 0xff);
    }

    private static void put16(ByteArrayOutputStream out, int v) {
        out.write((v >> 8) & 0xff);
        out.write(v & 0xff);
    }
}
