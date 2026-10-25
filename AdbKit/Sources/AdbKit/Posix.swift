#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#endif

/// The C socket calls under one name on every platform (Darwin, Bionic, Glibc).
enum Posix {
    static func close(_ fd: Int32) {
        #if canImport(Darwin)
        _ = Darwin.close(fd)
        #elseif canImport(Android)
        _ = Android.close(fd)
        #else
        _ = Glibc.close(fd)
        #endif
    }

    static let streamSocket: Int32 = {
        #if canImport(Glibc) && !canImport(Android)
        return Int32(SOCK_STREAM.rawValue)
        #else
        return SOCK_STREAM
        #endif
    }()

    /// A TCP socket that won't raise SIGPIPE on a dropped connection (Darwin;
    /// elsewhere `send` passes MSG_NOSIGNAL).
    static func tcpSocket() -> Int32 {
        let fd = socket(AF_INET, streamSocket, 0)
        #if canImport(Darwin)
        if fd >= 0 {
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        #endif
        return fd
    }

    static func ipv4(_ address: in_addr, port: UInt16) -> sockaddr_in {
        var sa = sockaddr_in()
        #if canImport(Darwin)
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_port = port.bigEndian
        sa.sin_addr = address
        return sa
    }

    static func setNonBlocking(_ fd: Int32, _ on: Bool) {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, on ? flags | O_NONBLOCK : flags & ~O_NONBLOCK)
    }

    static func connect(_ fd: Int32, _ sa: sockaddr_in) -> Int32 {
        var sa = sa
        return withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Darwin)
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #elseif canImport(Android)
                Android.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #else
                Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }
    }

    /// `send` without SIGPIPE on a dropped connection (Darwin sockets use SO_NOSIGPIPE instead).
    static func send(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.send(fd, buffer, count, 0)
        #elseif canImport(Android)
        return Android.send(fd, buffer, count, Int32(MSG_NOSIGNAL))
        #else
        return Glibc.send(fd, buffer, count, Int32(MSG_NOSIGNAL))
        #endif
    }

    static func socketError(_ fd: Int32) -> Int32 {
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err
    }
}
