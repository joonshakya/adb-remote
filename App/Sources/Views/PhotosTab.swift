import AVFoundation
import Photos
import SwiftUI

/// Play tab → Photos: needs a connection to cast.
struct PhotosPane: View {
    @Environment(DeviceStore.self) private var store
    @State private var library = PhotoLibrary()

    var body: some View {
        if let session = store.selectedSession, session.isConnected, let cast = session.castModel() {
            LibraryGrid(library: library, cast: cast)
        } else {
            NotConnectedView()
        }
    }
}

// MARK: Library

@MainActor @Observable
final class PhotoLibrary {
    private(set) var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var assets: PHFetchResult<PHAsset>?

    var allowed: Bool { status == .authorized || status == .limited }

    func load() async {
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard allowed else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                        PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        assets = PHAsset.fetchAssets(with: options)
    }
}

private struct LibraryGrid: View {
    let library: PhotoLibrary
    let cast: CastModel
    @State private var opened: OpenedAsset?

    var body: some View {
        Group {
            if library.status == .denied || library.status == .restricted {
                ContentUnavailableView {
                    Label("No Access to Photos", systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text("Allow ADB Remote to see your photos to show them on the TV.")
                } actions: {
                    Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                        .buttonStyle(.borderedProminent)
                }
            } else if let assets = library.assets {
                if assets.count == 0 {
                    ContentUnavailableView("No Photos", systemImage: "photo")
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 2)], spacing: 2) {
                            ForEach(0..<assets.count, id: \.self) { index in
                                Thumbnail(asset: assets.object(at: index))
                                    .onTapGesture { opened = OpenedAsset(index: index) }
                            }
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .task { await library.load() }
        .fullScreenCover(item: $opened) { item in
            if let assets = library.assets {
                CastViewer(assets: assets, cast: cast, index: item.index)
            }
        }
    }
}

private struct OpenedAsset: Identifiable {
    let index: Int
    var id: Int { index }
}

private struct Thumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if asset.mediaType == .video {
                    Text(Duration.seconds(asset.duration.rounded()).formatted(.time(pattern: .minuteSecond)))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(4)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel(asset.mediaType == .video ? "Video" : "Photo")
            .accessibilityAddTraits(.isButton)
            .task(id: asset.localIdentifier) {
                image = await PhotoLoader.image(asset, side: 220, fast: true)
            }
    }
}

// MARK: Viewer

/// Full-screen pager. Whatever is on screen is sent to the TV right away.
private struct CastViewer: View {
    let assets: PHFetchResult<PHAsset>
    let cast: CastModel
    @State var index: Int
    @State private var controller: CastController?
    @AppStorage("castAutoShow") private var autoShow = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TabView(selection: $index) {
                ForEach(0..<assets.count, id: \.self) { i in
                    AssetPage(asset: assets.object(at: i), isCurrent: i == index) { scale, u, v in
                        controller?.zoom(scale: scale, u: u, v: v)
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Color.black)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottom) {
                if let controller { CastBar(controller: controller) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        controller?.closeTV()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Toggle("Show on TV Automatically", isOn: $autoShow)
                        Button("Clear the TV Screen", systemImage: "tv.slash") { controller?.clearTV() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .onAppear {
            let controller = CastController(cast: cast)
            controller.autoShow = autoShow
            self.controller = controller
            controller.select(assets.object(at: index))
        }
        .onChange(of: index) { _, i in controller?.select(assets.object(at: i)) }
        .onChange(of: autoShow) { _, on in
            controller?.autoShow = on
            if on { controller?.showNow() }
        }
    }
}

private struct AssetPage: View {
    let asset: PHAsset
    let isCurrent: Bool
    let onZoom: (CGFloat, CGFloat, CGFloat) -> Void
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black
            ZoomableImage(image: image, isCurrent: isCurrent, onZoom: onZoom)
            if image == nil {
                ProgressView().tint(.white)
            }
            if asset.mediaType == .video {
                Image(systemName: "play.tv")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(radius: 6)
                    .allowsHitTesting(false)
            }
        }
        .task(id: asset.localIdentifier) {
            let side = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * UIScreen.main.scale
            image = await PhotoLoader.image(asset, side: side, fast: false)
        }
    }
}

/// Pinch / double-tap zoom. Reports (scale, u, v): the zoom and which point of the
/// picture (0...1) is in the middle of the screen, so the TV can show the same view.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage?
    let isCurrent: Bool
    let onZoom: (CGFloat, CGFloat, CGFloat) -> Void

    func makeUIView(context: Context) -> ZoomScrollView {
        ZoomScrollView()
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        view.onZoom = onZoom
        view.setImage(image)
        // Pages you swiped away from start unzoomed when you come back.
        if !isCurrent && view.zoomScale != 1 { view.setZoomScale(1, animated: false) }
    }
}

final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    var onZoom: ((CGFloat, CGFloat, CGFloat) -> Void)?
    private var laidOutSize = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 8
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: UIImage?) {
        guard imageView.image !== image else { return }
        imageView.image = image
        laidOutSize = .zero
        setZoomScale(1, animated: false)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Size the picture to fit only while unzoomed; resizing mid-zoom fights the gesture.
        guard zoomScale == 1, bounds.size != laidOutSize, let size = imageView.image?.size,
              size.width > 0, size.height > 0, bounds.width > 0 else { return }
        laidOutSize = bounds.size
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * fit, height: size.height * fit)
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
        centerContent()
    }

    private func centerContent() {
        let x = max(0, (bounds.width - contentSize.width) / 2)
        let y = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        report()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if isTracking || isDecelerating || isZooming || isZoomBouncing { report() }
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        report()
    }

    private func report() {
        guard contentSize.width > 0, contentSize.height > 0 else { return }
        let u = (contentOffset.x + bounds.width / 2) / contentSize.width
        let v = (contentOffset.y + bounds.height / 2) / contentSize.height
        onZoom?(zoomScale, min(max(u, 0), 1), min(max(v, 0), 1))
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1 {
            setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let scale: CGFloat = 2.5
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        }
    }
}

/// Status and buttons at the bottom of the viewer.
private struct CastBar: View {
    let controller: CastController

    var body: some View {
        HStack(spacing: 14) {
            switch controller.status {
            case .working(let text):
                ProgressView().tint(.white)
                Text(text)
            case .ready:
                Image(systemName: "checkmark.circle")
                Text(controller.videoWaiting ? "Ready to play" : "Ready on the TV")
                Button(controller.videoWaiting ? "Play on TV" : "Show") { controller.showNow() }
                    .buttonStyle(.borderedProminent)
            case .onTV:
                Image(systemName: "tv").foregroundStyle(.green)
                Text("On the TV")
            case .playing:
                VideoControls(controller: controller)
            case .ended:
                Image(systemName: "checkmark.circle")
                Text("Finished")
                Button("Play Again") { controller.replay() }
                    .buttonStyle(.bordered)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
                Text(message).lineLimit(3)
                Button("Retry") { controller.replay() }
                    .buttonStyle(.bordered)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.bottom, 40)
        .padding(.horizontal)
        .animation(.snappy, value: controller.status)
        // Always on a dark backdrop: dark controls keep the scrubber's track visible.
        .environment(\.colorScheme, .dark)
    }
}

/// Play/pause, 10-second skips and a scrubber for the video playing on the TV.
private struct VideoControls: View {
    let controller: CastController
    /// While dragging, the scrubber shows the finger's time and the TV follows.
    @State private var scrubbing: Double?
    @State private var scrubEnd: Task<Void, Never>?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let position = scrubbing ?? controller.videoPosition(at: context.date)
            let duration = max(controller.videoDuration, 0.1)
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Text(Self.format(position)).frame(minWidth: 44, alignment: .leading)
                    Slider(value: Binding(get: { min(position, duration) }, set: scrub), in: 0...duration)
                    .tint(.white)
                    .disabled(controller.videoDuration <= 0)
                    Text(Self.format(controller.videoDuration)).frame(minWidth: 44, alignment: .trailing)
                }
                .font(.caption.monospacedDigit())
                HStack(spacing: 36) {
                    Button { controller.skip(by: -10) } label: {
                        Image(systemName: "gobackward.10")
                    }
                    .accessibilityLabel("Back 10 Seconds")
                    Button { controller.togglePause() } label: {
                        Image(systemName: controller.videoPaused ? "play.fill" : "pause.fill")
                            .font(.title)
                            .frame(width: 36)
                    }
                    .accessibilityLabel(controller.videoPaused ? "Play" : "Pause")
                    .accessibilityIdentifier("playPause")
                    Button { controller.skip(by: 10) } label: {
                        Image(systemName: "goforward.10")
                    }
                    .accessibilityLabel("Forward 10 Seconds")
                }
                .font(.title2)
            }
        }
    }

    private func scrub(_ value: Double) {
        scrubbing = value
        controller.scrub(to: value)
        // Once the finger stops, show the TV's time again.
        scrubEnd?.cancel()
        scrubEnd = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled { scrubbing = nil }
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded(.down))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: Casting

/// Sends the asset on screen to the TV: photos are uploaded and shown when ready
/// (or when the user taps Show); videos start playing on the TV straight away.
@MainActor @Observable
final class CastController {
    enum Status: Equatable {
        case working(String)
        case ready
        case onTV
        case playing(paused: Bool)
        case ended
        case failed(String)
    }

    let cast: CastModel
    var autoShow = true
    private(set) var status: Status = .working("Connecting to the TV…")
    private var asset: PHAsset?
    private var currentID = 0
    private var readyID: Int?
    /// With Auto Show off, a prepared video waits here until Show is tapped.
    private var readyVideo: (id: Int, file: URL)?
    var videoWaiting: Bool { readyVideo != nil }
    private var task: Task<Void, Never>?
    /// Keeps the Photos file (and its access) alive while the TV reads it.
    private var videoAsset: AVAsset?

    init(cast: CastModel) {
        self.cast = cast
        cast.onEvent = { [weak self] event in self?.handle(event) }
    }

    func select(_ asset: PHAsset) {
        self.asset = asset
        zoomState = (1, 0.5, 0.5)
        task?.cancel()
        readyID = nil
        readyVideo = nil
        currentID = 0
        task = Task { await send(asset) }
    }

    func replay() {
        if let asset { select(asset) }
    }

    func showNow() {
        if let video = readyVideo {
            readyVideo = nil
            status = .working("Starting on the TV…")
            cast.playVideo(id: video.id, file: video.file)
            return
        }
        guard let readyID else { return }
        cast.show(id: readyID)
    }

    func togglePause() {
        guard case .playing(let paused) = status else { return }
        timeBase = videoPosition(at: Date())
        timeBaseDate = Date()
        ignoreTimeUntil = Date().addingTimeInterval(1)
        if paused { cast.resume() } else { cast.pause() }
        status = .playing(paused: !paused)
    }

    // MARK: Video position

    /// Last position the TV reported, and when; the position in between is estimated.
    private var timeBase: Double = 0
    private var timeBaseDate = Date()
    private(set) var videoDuration: Double = 0
    var videoPaused: Bool {
        if case .playing(let paused) = status { return paused }
        return true
    }

    func videoPosition(at date: Date) -> Double {
        let elapsed = videoPaused ? 0 : date.timeIntervalSince(timeBaseDate)
        return min(timeBase + max(elapsed, 0), videoDuration > 0 ? videoDuration : .infinity)
    }

    func seek(to seconds: Double) {
        let target = min(max(seconds, 0), max(videoDuration - 0.5, 0))
        timeBase = target
        timeBaseDate = Date()
        // Reports from before the seek would pull the scrubber back for a moment.
        ignoreTimeUntil = Date().addingTimeInterval(1)
        cast.seek(to: target)
    }

    private var lastScrubSeek = Date.distantPast
    private var scrubFlush: Task<Void, Never>?

    /// Seeks while the scrubber is dragged: at most 4 times a second, always ending on the last spot.
    func scrub(to seconds: Double) {
        scrubFlush?.cancel()
        let wait = 0.25 - Date().timeIntervalSince(lastScrubSeek)
        if wait <= 0 {
            lastScrubSeek = Date()
            seek(to: seconds)
        } else {
            scrubFlush = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                lastScrubSeek = Date()
                seek(to: seconds)
            }
        }
    }

    func skip(by seconds: Double) {
        seek(to: videoPosition(at: Date()) + seconds)
    }

    private var ignoreTimeUntil = Date.distantPast

    /// Latest zoom from the phone; re-sent when a new photo appears on the TV.
    private var zoomState: (scale: CGFloat, u: CGFloat, v: CGFloat) = (1, 0.5, 0.5)
    private var lastZoomSent = Date.distantPast
    private var zoomFlush: Task<Void, Never>?

    /// Mirrors the phone's zoom on the TV, at most ~30 updates a second.
    func zoom(scale: CGFloat, u: CGFloat, v: CGFloat) {
        let new = (scale, u, v)
        guard new != zoomState else { return }
        zoomState = new
        let wait = 0.033 - Date().timeIntervalSince(lastZoomSent)
        if wait <= 0 {
            sendZoom()
        } else if zoomFlush == nil {
            zoomFlush = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                self?.zoomFlush = nil
                self?.sendZoom()
            }
        }
    }

    private func sendZoom() {
        guard currentID != 0 else { return }
        lastZoomSent = Date()
        cast.zoom(id: currentID, scale: zoomState.scale, u: zoomState.u, v: zoomState.v)
    }

    func closeTV() {
        task?.cancel()
        Task { await cast.closeViewer() }
    }

    func clearTV() {
        task?.cancel()
        cast.clear()
        status = .working("Cleared")
    }

    private func send(_ asset: PHAsset) async {
        if cast.state != .ready { status = .working("Connecting to the TV…") }
        guard await cast.prepare() else {
            if case .failed(let message) = cast.state { status = .failed(message) }
            return
        }
        guard !Task.isCancelled else { return }
        let id = cast.newID()
        currentID = id
        if asset.mediaType == .video {
            await sendVideo(asset, id: id)
        } else {
            status = .working("Sending…")
            let side = CGFloat(min(max(cast.tv.longSide, 1280), 1920))
            guard let image = await PhotoLoader.image(asset, side: side, fast: false), !Task.isCancelled else {
                if !Task.isCancelled { status = .failed("Couldn't load this photo") }
                return
            }
            let jpeg = await Task.detached { image.jpegData(compressionQuality: 0.85) }.value
            guard let jpeg, !Task.isCancelled else { return }
            cast.sendPhoto(id: id, jpeg: jpeg)
        }
    }

    private func sendVideo(_ asset: PHAsset, id: Int) async {
        status = .working("Getting the video…")
        do {
            let file = try await VideoPreparer.file(for: asset, tv: cast.tv) { [weak self] progress in
                self?.status = .working("Converting for the TV… \(Int(progress * 100))%")
            } keep: { [weak self] avAsset in
                self?.videoAsset = avAsset
            }
            guard !Task.isCancelled else { return }
            if autoShow {
                status = .working("Starting on the TV…")
                cast.playVideo(id: id, file: file)
            } else {
                // Videos stream, so "ready" means ready to start; nothing plays until Show.
                readyVideo = (id, file)
                status = .ready
            }
        } catch {
            if !Task.isCancelled { status = .failed(error.localizedDescription) }
        }
    }

    private func handle(_ event: CastModel.Event) {
        switch event {
        case .ready(let id) where id == currentID:
            readyID = id
            if autoShow { cast.show(id: id) } else { status = .ready }
        case .shown(let id) where id == currentID:
            status = .onTV
            if zoomState.scale != 1 { sendZoom() }
        case .photoFailed(let id) where id == currentID:
            status = .failed("The TV couldn't open this photo")
        case .playing(let id) where id == currentID:
            status = .playing(paused: false)
            timeBase = 0
            timeBaseDate = Date()
            videoDuration = 0
            if zoomState.scale != 1 { sendZoom() }
        case .ended(let id) where id == currentID:
            status = .ended
        case .videoFailed(let id, _) where id == currentID:
            status = .failed("The TV couldn't play this video")
        case .time(let id, let position, let duration, let playing) where id == currentID:
            guard case .playing = status else { return }
            videoDuration = duration
            guard Date() >= ignoreTimeUntil else { return }
            timeBase = position
            timeBaseDate = Date()
            // Paused or resumed from the TV's own remote.
            if playing == videoPaused { status = .playing(paused: !playing) }
        default:
            break
        }
    }
}

// MARK: Loading

enum PhotoLoader {
    /// Image no larger than `side` pixels on its long edge (iCloud photos are downloaded).
    @MainActor
    static func image(_ asset: PHAsset, side: CGFloat, fast: Bool) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = fast ? .opportunistic : .highQualityFormat
        options.resizeMode = fast ? .fast : .exact
        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: side, height: side), contentMode: fast ? .aspectFill : .aspectFit,
                options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                // Opportunistic requests call back twice; take the first for thumbnails.
                guard !resumed, !degraded || fast else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }
}

enum VideoPreparer {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// A file the TV can play: the original when its format works on this TV,
    /// otherwise a converted H.264 copy (cached in tmp).
    @MainActor
    static func file(for asset: PHAsset, tv: CastModel.TV,
                     progress: @escaping @MainActor (Double) -> Void,
                     keep: @escaping @MainActor (AVAsset) -> Void) async throws -> URL {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        let avAsset: AVAsset = try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                if let avAsset {
                    continuation.resume(returning: avAsset)
                } else {
                    let error = info?[PHImageErrorKey] as? Error
                    continuation.resume(throwing: Failure(errorDescription: error?.localizedDescription ?? "Couldn't open this video"))
                }
            }
        }
        keep(avAsset)

        if let urlAsset = avAsset as? AVURLAsset, try await !needsConversion(urlAsset, tv: tv) {
            return urlAsset.url
        }
        let name = asset.localIdentifier.replacingOccurrences(of: "/", with: "_")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("cast-\(name)-\(tv.longSide).mp4")
        if FileManager.default.fileExists(atPath: output.path) { return output }
        return try await convert(avAsset, to: output, tv: tv, progress: progress)
    }

    /// HEVC on a TV without an HEVC decoder, or 4K on an old TV, gets converted.
    private static func needsConversion(_ asset: AVURLAsset, tv: CastModel.TV) async throws -> Bool {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return false }
        let size = try await track.load(.naturalSize)
        let formats = try await track.load(.formatDescriptions)
        let hevc = formats.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC }
        if hevc && !tv.hevc { return true }
        return max(abs(size.width), abs(size.height)) > 1920 && tv.sdk < 21
    }

    @MainActor
    private static func convert(_ asset: AVAsset, to output: URL, tv: CastModel.TV,
                                progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let preset = tv.longSide >= 1920 ? AVAssetExportPreset1920x1080 : AVAssetExportPreset1280x720
        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw Failure(errorDescription: "This video can't be converted")
        }
        let partial = output.deletingPathExtension().appendingPathExtension("part.mp4")
        try? FileManager.default.removeItem(at: partial)
        export.outputURL = partial
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                progress(Double(export.progress))
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        defer { ticker.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                export.exportAsynchronously { continuation.resume() }
            }
        } onCancel: {
            export.cancelExport()
        }
        guard export.status == .completed else {
            throw Failure(errorDescription: export.error?.localizedDescription ?? "Converting the video failed")
        }
        try FileManager.default.moveItem(at: partial, to: output)
        return output
    }
}
