import Foundation

public struct ShellResult: Sendable {
    public let stdout: Data
    public let stderr: Data
    /// nil when the device lacks shell_v2 (Android < 7) and cannot report it.
    public let exitCode: Int?

    public var output: String { String(decoding: stdout, as: UTF8.self) }
    public var errorOutput: String { String(decoding: stderr, as: UTF8.self) }
}

/// Single-quotes a string for the device's /system/bin/sh.
public func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

extension AdbConnection {
    public var supportsShellV2: Bool { features.contains("shell_v2") }

    /// Runs a command and collects its output.
    public func shell(_ command: String) async throws -> ShellResult {
        if supportsShellV2 {
            let stream = try await open("shell,v2,raw:" + command)
            defer { stream.close() }
            var stdout = Data()
            var stderr = Data()
            var exitCode: Int?
            // shell_v2 packet: u8 id, u32 LE length, payload.
            while true {
                guard let header = try await readOrEOF(stream, 5) else { break }
                let length = Int(header.le32(at: 1))
                let payload = length > 0 ? try await stream.readExactly(length) : Data()
                switch header[header.startIndex] {
                case 1: stdout.append(payload)
                case 2: stderr.append(payload)
                case 3: exitCode = payload.first.map(Int.init)
                default: break
                }
                if exitCode != nil { break }
            }
            return ShellResult(stdout: stdout, stderr: stderr, exitCode: exitCode)
        } else {
            // Old devices run "shell:" on a PTY, which turns \n into \r\n.
            let stream = try await open("shell:" + command)
            defer { stream.close() }
            let raw = try await stream.readAll()
            let output = Data(String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n").utf8)
            return ShellResult(stdout: output, stderr: Data(), exitCode: nil)
        }
    }

    /// Convenience: stdout as trimmed text, throws if the command fails.
    @discardableResult
    public func run(_ command: String) async throws -> String {
        let result = try await shell(command)
        if let code = result.exitCode, code != 0 {
            let message = [result.errorOutput, result.output]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "exit code \(code)"
            throw AdbError.command(message)
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Raw-mode shell stream for long-running commands (no PTY, output as-is).
    public func openRawShell(_ command: String) async throws -> AdbStream {
        try await open("shell:" + command)
    }

    /// Opens a raw byte stream to a command using "exec:" (no shell_v2 framing).
    public func exec(_ command: String) async throws -> AdbStream {
        try await open("exec:" + command)
    }

    private func readOrEOF(_ stream: AdbStream, _ count: Int) async throws -> Data? {
        var out = Data()
        while out.count < count {
            guard let chunk = try await stream.read(max: count - out.count) else {
                if out.isEmpty { return nil }
                throw AdbError.protocolError("truncated shell packet")
            }
            out.append(chunk)
        }
        return out
    }
}
