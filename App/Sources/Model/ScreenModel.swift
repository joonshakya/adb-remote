import AVFoundation
import AdbKit
import Foundation
import Observation
import UIKit

/// Live screen for one device: scrcpy H.264 on Android 5+, screenshots otherwise.
@MainActor @Observable
final class ScreenModel {
    enum Mode { case video, screenshots }

    private(set) var mode: Mode
    private(set) var isRunning = false
    private(set) var status: String?
    var error: String?
    /// Device frame size (video or screenshot pixels).
    private(set) var frameSize = CGSize(width: 16, height: 9)
    /// Latest still frame in screenshot mode.
    private(set) var still: UIImage?

    /// Connection log hook (set by DeviceSession).
    var log: (String) -> Void = { _ in }

    let renderer = H264Renderer()
    private let adb: AdbConnection
    private var session: ScrcpySession?
    private var task: Task<Void, Never>?
    /// Bumped on every start, so a stopped run finishing late can't touch a newer one.
    private var generation = 0

    init(connection: AdbConnection, sdk: Int) {
        adb = connection
        mode = sdk >= 21 && DeviceSession.scrcpyServer != nil ? .video : .screenshots
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        error = nil
        log("screen start (\(mode == .video ? "video" : "screenshots"))")
        status = "Starting…"
        generation += 1
        let current = generation
        task = Task { [weak self] in
            guard let self else { return }
            switch mode {
            case .video: await runVideo()
            case .screenshots: await runScreenshots()
            }
            if generation == current { isRunning = false }
        }
    }

    func stop() {
        if isRunning { log("screen stop") }
        task?.cancel()
        task = nil
        session?.close()
        session = nil
        isRunning = false
    }

    private func runVideo() async {
        guard let jar = DeviceSession.scrcpyServer else { return }
        var session: ScrcpySession?
        do {
            let started = try await ScrcpySession.start(
                adb: adb, serverJar: jar, video: .init(maxSize: 1280, bitRate: 4_000_000, maxFps: 30))
            session = started
            // Stopped while starting: end the server right away.
            guard !Task.isCancelled else {
                started.close()
                return
            }
            self.session = started
            let session = started
            let reader = ScrcpyVideoReader(stream: session.video!)
            guard try await reader.readCodec() == ScrcpyVideoReader.h264 else {
                throw AdbError.command("The TV sent an unsupported video format.")
            }
            status = nil
            while !Task.isCancelled, let event = try await reader.next() {
                switch event {
                case .size(let w, let h):
                    frameSize = CGSize(width: w, height: h)
                case .config(let data):
                    renderer.setParameterSets(data)
                case .frame(let data, _, _):
                    renderer.enqueue(data)
                }
            }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
        session?.close()
        if let session, self.session === session { self.session = nil }
    }

    private static let screenshotNote = "This TV is too old for live video. Showing a screenshot about every second."

    private func runScreenshots() async {
        status = Self.screenshotNote
        while !Task.isCancelled {
            do {
                let png = try await adb.screenshotPNG()
                if let image = UIImage(data: png) {
                    still = image
                    status = Self.isBlack(image)
                        ? "The screen looks black. TVs can't capture an HDMI or TV-channel picture; switch to an app to see it here."
                        : Self.screenshotNote
                    frameSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
                return
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
    }

    /// True when a downscaled copy of the image has no visible pixels.
    private static func isBlack(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        let size = 16
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        return pixels.enumerated().allSatisfy { $0.offset % 4 == 3 || $0.element < 8 }
    }

    // MARK: Touch

    private typealias TouchEvent = (session: ScrcpySession, action: TouchAction, id: Int, x: Int32, y: Int32, w: UInt16, h: UInt16)
    private var touchQueue: AsyncStream<TouchEvent>.Continuation?

    /// Touch at a point in device-frame pixels. Events go through one queue so
    /// "finger up" can never overtake "finger down".
    func touch(_ action: TouchAction, id: Int, at point: CGPoint) {
        let x = Int32(point.x.rounded()), y = Int32(point.y.rounded())
        if let session {
            if touchQueue == nil {
                let (stream, continuation) = AsyncStream.makeStream(of: TouchEvent.self)
                touchQueue = continuation
                Task {
                    for await e in stream {
                        try? await e.session.injectTouch(e.action, pointerId: UInt64(e.id), x: e.x, y: e.y, width: e.w, height: e.h)
                    }
                }
            }
            touchQueue?.yield((session, action, id, x, y, UInt16(frameSize.width), UInt16(frameSize.height)))
        } else if mode == .screenshots {
            tapFallback(action, x: x, y: y)
        }
    }

    private var swipeStart: (x: Int32, y: Int32, time: Date)?

    /// Without scrcpy: a tap or a swipe via `input`, sent when the finger lifts.
    private func tapFallback(_ action: TouchAction, x: Int32, y: Int32) {
        switch action {
        case .down:
            swipeStart = (x, y, Date())
        case .move:
            break
        case .up:
            guard let start = swipeStart else { return }
            swipeStart = nil
            let moved = abs(start.x - x) + abs(start.y - y) > 20
            let ms = max(100, Int(Date().timeIntervalSince(start.time) * 1000))
            let command = moved ? "input swipe \(start.x) \(start.y) \(x) \(y) \(ms)" : "input tap \(x) \(y)"
            Task { try? await adb.run(command) }
        }
    }

    func scroll(at point: CGPoint, dx: CGFloat, dy: CGFloat) {
        guard let session else { return }
        let w = UInt16(frameSize.width), h = UInt16(frameSize.height)
        Task {
            try? await session.injectScroll(x: Int32(point.x), y: Int32(point.y), width: w, height: h,
                                            horizontal: Float(dx), vertical: Float(dy))
        }
    }
}

/// Feeds H.264 Annex-B access units to an AVSampleBufferDisplayLayer (hardware decode).
final class H264Renderer {
    let layer = AVSampleBufferDisplayLayer()
    private var format: CMVideoFormatDescription?

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
    }

    /// Splits Annex-B data into NAL units (without start codes).
    static func nalUnits(_ data: Data) -> [Data] {
        var units: [Data] = []
        let bytes = [UInt8](data)
        var i = 0, start = -1
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    if end > start, bytes[end - 1] == 0 { end -= 1 } // 4-byte start code
                    units.append(Data(bytes[start..<end]))
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0, start < bytes.count { units.append(Data(bytes[start...])) }
        return units
    }

    func setParameterSets(_ annexB: Data) {
        let units = Self.nalUnits(annexB)
        guard let sps = units.first(where: { ($0.first ?? 0) & 0x1f == 7 }),
              let pps = units.first(where: { ($0.first ?? 0) & 0x1f == 8 }) else { return }
        var newFormat: CMVideoFormatDescription?
        sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &newFormat)
            }
        }
        if let newFormat {
            format = newFormat
            layer.flush()
        }
    }

    func enqueue(_ annexB: Data) {
        guard let format else { return }
        // AVCC: each NAL prefixed with its 4-byte big-endian length.
        var avcc = Data()
        for unit in Self.nalUnits(annexB) {
            let type = (unit.first ?? 0) & 0x1f
            if type == 7 || type == 8 { continue }
            avcc.appendBigEndian(UInt32(unit.count))
            avcc.append(unit)
        }
        guard !avcc.isEmpty else { return }

        var block: CMBlockBuffer?
        let length = avcc.count
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block) == noErr,
            let block else { return }
        avcc.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) }

        var sample: CMSampleBuffer?
        var size = length
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if layer.status == .failed { layer.flush() }
        layer.enqueue(sample)
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
