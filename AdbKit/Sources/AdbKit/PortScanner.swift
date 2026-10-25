#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

public enum AdbProbe: Sendable, Equatable {
    /// Plain adbd (may still ask for key approval).
    case adb
    /// adbd that wants TLS: Android 11+ wireless debugging (needs pairing first).
    case adbTLS
}

public enum PortScanner {
    /// Ports worth trying before a full sweep.
    public static let likelyPorts: [UInt16] = [5555] + Array(5556...5585) + [5037, 5789, 7272, 9555, 4444, 4445]

    /// Finds open TCP ports with non-blocking connects, `batch` sockets at a time
    /// (iOS apps have a low file-descriptor limit, so keep it modest).
    public static func openPorts(
        host: String,
        ports: [UInt16],
        batch: Int = 128,
        timeout: Double = 0.35,
        progress: @escaping @Sendable (_ scanned: Int, _ open: [UInt16]) -> Void = { _, _ in }
    ) async throws -> [UInt16] {
        guard let address = resolveIPv4(host) else { throw AdbError.connectionFailed("cannot resolve \(host)") }
        let cancelled = Box(false)
        return try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                var open: [UInt16] = []
                var scanned = 0
                var index = 0
                while index < ports.count {
                    if cancelled.value { break }
                    let slice = Array(ports[index..<min(index + batch, ports.count)])
                    open += scanBatch(address: address, ports: slice, timeout: timeout)
                    index += slice.count
                    scanned += slice.count
                    progress(scanned, open)
                }
                continuation.resume(returning: open)
            }
          }
        } onCancel: {
            cancelled.value = true
        }
    }

    /// Sends an ADB CNXN and checks whether the reply looks like adbd.
    public static func probe(host: String, port: UInt16, timeout: Double = 2) async -> AdbProbe? {
        let tcp = TCPTransport(host: host, port: port)
        defer { tcp.close() }
        do {
            try await tcp.start(timeout: timeout)
            try await tcp.send(AdbMessage(AdbMessage.cnxn, AdbMessage.version, AdbMessage.maxPayload,
                                          Data(cString: "host::features=\(AdbConnection.hostFeatures)")).encoded)
            let reader = BufferedReader(tcp)
            let header = try await withTimeout(timeout, "probe") { try await reader.read(24) }
            let command = header.le32(at: 0)
            guard header.le32(at: 20) == command ^ 0xffff_ffff else { return nil }
            switch command {
            case AdbMessage.stls: return .adbTLS
            case AdbMessage.cnxn, AdbMessage.auth: return .adb
            default: return nil
            }
        } catch {
            return nil
        }
    }

    /// Well-known services that are never adbd; sending them ADB bytes is pointless.
    static let knownNonAdb: Set<UInt16> = [21, 22, 23, 53, 80, 139, 443, 445, 554, 1900, 8008, 8009, 8080, 8443, 9000]

    /// Finds ADB ports while touching as few other services as possible: probing
    /// a non-ADB port sends it unexpected bytes, which can crash fragile TV apps.
    /// 1. Probe open ports among `preferred` + `likelyPorts`; stop at the first ADB hit.
    /// 2. Otherwise sweep all ports, then probe open ones one by one (likely ranges first).
    public static func findAdbPorts(
        host: String,
        preferred: [UInt16] = [],
        stopAtFirst: Bool = true,
        progress: @escaping @Sendable (_ scanned: Int, _ total: Int, _ open: [UInt16]) -> Void = { _, _, _ in }
    ) async throws -> [(port: UInt16, kind: AdbProbe)] {
        var ordered: [UInt16] = []
        for port in preferred + likelyPorts where !ordered.contains(port) { ordered.append(port) }
        let likely = ordered
        let likelySet = Set(likely)
        let rest = (1...UInt16.max).filter { !likelySet.contains($0) }
        let total = likely.count + rest.count
        var found: [(UInt16, AdbProbe)] = []

        let likelyOpen = try await openPorts(host: host, ports: likely) { scanned, open in
            progress(scanned, total, open)
        }
        for port in likely where likelyOpen.contains(port) {
            if let kind = await probe(host: host, port: port) {
                found.append((port, kind))
                if stopAtFirst { return found }
            }
        }

        let restOpen = try await openPorts(host: host, ports: rest) { scanned, open in
            progress(likely.count + scanned, total, likelyOpen + open)
        }
        // adb tcpip ports cluster near 5555; wireless debugging uses high random ports.
        func rank(_ p: UInt16) -> Int {
            if (5000...6000).contains(p) { return 0 }
            if (30000...50000).contains(p) { return 1 }
            return 2
        }
        for port in restOpen.sorted(by: { (rank($0), $0) < (rank($1), $1) }) where !knownNonAdb.contains(port) {
            try Task.checkCancellation()
            if let kind = await probe(host: host, port: port) {
                found.append((port, kind))
                if stopAtFirst { break }
            }
        }
        return found
    }

    static func resolveIPv4(_ host: String) -> in_addr? {
        var addr = in_addr()
        if inet_pton(AF_INET, host, &addr) == 1 { return addr }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = Posix.streamSocket
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }
        return info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
    }

    private static func scanBatch(address: in_addr, ports: [UInt16], timeout: Double) -> [UInt16] {
        var fds: [Int32] = []
        var fdPorts: [Int32: UInt16] = [:]
        var open: [UInt16] = []
        defer { for fd in fds { Posix.close(fd) } }

        for port in ports {
            let fd = Posix.tcpSocket()
            guard fd >= 0 else { continue }
            Posix.setNonBlocking(fd, true)
            let r = Posix.connect(fd, Posix.ipv4(address, port: port))
            fds.append(fd)
            if r == 0 {
                open.append(port)
            } else if errno == EINPROGRESS {
                fdPorts[fd] = port
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while !fdPorts.isEmpty {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            var pfds = fdPorts.keys.map { pollfd(fd: $0, events: Int16(POLLOUT), revents: 0) }
            let n = poll(&pfds, nfds_t(pfds.count), Int32(remaining * 1000))
            if n <= 0 { break }
            for p in pfds where p.revents != 0 {
                if Posix.socketError(p.fd) == 0, let port = fdPorts[p.fd] { open.append(port) }
                fdPorts.removeValue(forKey: p.fd)
            }
        }
        return open
    }
}
