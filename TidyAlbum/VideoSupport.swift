import AVKit
import Combine
import CoreTransferable
import Photos
import SwiftUI
import UniformTypeIdentifiers

enum MediaFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case photos = "照片"
    case videos = "视频"

    var id: Self { self }

    var title: String { L10n.text(rawValue) }

    var emptyTitle: String {
        switch self {
        case .all: L10n.text("没有可显示的项目")
        case .photos: L10n.text("没有可显示的照片")
        case .videos: L10n.text("没有可显示的视频")
        }
    }

    func includes(_ item: PhotoItem) -> Bool {
        switch self {
        case .all: true
        case .photos: !item.isVideo
        case .videos: item.isVideo
        }
    }
}

enum VideoDuration {
    static func text(_ duration: TimeInterval) -> String {
        guard duration.isFinite, duration >= 0, duration < Double(Int.max) else { return "0:00" }
        let seconds = Int(duration.rounded(.down))
        if seconds >= 3_600 {
            return String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// 使用文件传输，避免把完整影片读成 Data 而占满内存。
struct ImportedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MinusImportedVideos", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return ImportedVideo(url: destination)
        }
    }

    func makeItem() async throws -> PhotoItem {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let track = try await asset.loadTracks(withMediaType: .video).first
        var size = CGSize.zero
        if let track {
            let naturalSize = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            size = naturalSize.applying(transform)
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1200, height: 1200)
        let thumbnail = try? await generator.image(at: .zero)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])

        return PhotoItem(
            title: "刚刚导入",
            detail: L10n.format("视频 · %@", VideoDuration.text(duration)),
            pixelWidth: Int(abs(size.width)),
            pixelHeight: Int(abs(size.height)),
            byteSize: Int64(values.fileSize ?? 0),
            artwork: .imported,
            image: thumbnail.map { UIImage(cgImage: $0.image) },
            tag: "视频",
            mediaType: .video,
            duration: duration,
            localVideoURL: url
        )
    }
}

@MainActor
final class VideoPlaybackModel: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var activePhotoID: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var progress = 0.0
    @Published private(set) var errorMessage: String?
    @Published private(set) var isReady = false
    private var requestID: PHImageRequestID?
    private var generation: UUID?
    private var statusObservation: AnyCancellable?
    private var playbackObservation: AnyCancellable?
    private var timeObserver: Any?
    private var shouldPlayWhenReady = false
    private var shouldMute = false

    func load(_ photo: PhotoItem, muted: Bool = false, autoplay: Bool = true) {
        stop()
        activePhotoID = photo.id
        duration = photo.duration.isFinite ? max(photo.duration, 0) : 0
        shouldPlayWhenReady = autoplay
        shouldMute = muted
        errorMessage = nil
        isReady = false
        progress = 0
        let token = UUID()
        generation = token

        if let url = photo.localVideoURL {
            prepare(AVPlayerItem(url: url))
            return
        }

        guard let identifier = photo.assetIdentifier,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
              asset.mediaType == .video else {
            errorMessage = L10n.text("无法读取视频，请检查照片访问范围。")
            return
        }

        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = true
        options.progressHandler = { [weak self] progress, _, _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.progress = progress
            }
        }
        requestID = PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { [weak self] item, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, !cancelled else { return }
                self.requestID = nil
                guard let item else {
                    self.errorMessage = L10n.text("视频加载失败，请检查网络后重试。")
                    return
                }
                self.prepare(item)
            }
        }
    }

    private func prepare(_ item: AVPlayerItem) {
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = shouldMute
        player = newPlayer
        let token = generation
        statusObservation = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak newPlayer] status in
                guard let self, self.generation == token else { return }
                switch status {
                case .readyToPlay:
                    self.isReady = true
                    if self.shouldPlayWhenReady { newPlayer?.play() }
                case .failed:
                    newPlayer?.pause()
                    self.errorMessage = L10n.text("视频暂时无法播放，请重试。")
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        playbackObservation = newPlayer.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard self?.generation == token else { return }
                self?.isPlaying = status != .paused
            }
        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak newPlayer] time in
            Task { @MainActor [weak self, weak newPlayer] in
                guard let self, self.generation == token, let newPlayer else { return }
                if time.seconds.isFinite { self.currentTime = max(time.seconds, 0) }
                if let duration = newPlayer.currentItem?.duration.seconds, duration.isFinite, duration > 0 {
                    self.duration = duration
                }
            }
        }
    }

    func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus != .paused {
            pause()
        } else if duration > 0, currentTime >= duration - 0.1 {
            seek(to: 0, resume: true)
        } else {
            shouldPlayWhenReady = true
            player.play()
        }
    }

    func pause() {
        shouldPlayWhenReady = false
        player?.pause()
    }

    func seek(to seconds: Double, resume: Bool) {
        guard let player, seconds.isFinite else { return }
        shouldPlayWhenReady = resume
        let target = min(max(seconds, 0), duration)
        currentTime = target
        let token = generation
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, finished, self.shouldPlayWhenReady else { return }
                self.player?.play()
            }
        }
    }

    func stop() {
        generation = nil
        shouldPlayWhenReady = false
        shouldMute = false
        if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
        requestID = nil
        statusObservation = nil
        playbackObservation = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        activePhotoID = nil
        isPlaying = false
        isReady = false
        currentTime = 0
        duration = 0
    }
}

/// 只呈现画面，触摸交给整理页；控制条作为独立兄弟视图，不参与左右滑动判定。
private struct InlinePlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    var fillsBounds = false

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.playerLayer.videoGravity = fillsBounds ? .resizeAspectFill : .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.playerLayer.videoGravity = fillsBounds ? .resizeAspectFill : .resizeAspect
        view.playerLayer.player = player
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

struct InlineVideoContent: View {
    @ObservedObject var playback: VideoPlaybackModel
    var fillsBounds = false

    var body: some View {
        ZStack {
            if playback.errorMessage == nil, let player = playback.player {
                InlinePlayerSurface(player: player, fillsBounds: fillsBounds)
            } else {
                Color.black.opacity(0.65)
                VStack(spacing: 12) {
                    if let error = playback.errorMessage {
                        Image(systemName: "video.slash").font(.title)
                        Text(error)
                        Text("轻点重试").font(.caption)
                    } else {
                        ProgressView().tint(.white)
                        Text(
                            playback.progress > 0
                                ? L10n.format("正在加载视频… %lld%%", Int(playback.progress * 100))
                                : L10n.text("正在加载视频…")
                        )
                    }
                }
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(false)
    }
}

struct InlineVideoControls: View {
    @ObservedObject var playback: VideoPlaybackModel
    @State private var isSeeking = false
    @State private var seekPosition = 0.0
    @State private var resumeAfterSeeking = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: playback.togglePlayback) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.isPlaying ? L10n.text("暂停视频") : L10n.text("播放视频"))

            VStack(spacing: 2) {
                Slider(
                    value: Binding(
                        get: { min(isSeeking ? seekPosition : playback.currentTime, max(playback.duration, 0.1)) },
                        set: { seekPosition = $0 }
                    ),
                    in: 0...max(playback.duration, 0.1),
                    onEditingChanged: { editing in
                        if editing {
                            resumeAfterSeeking = playback.isPlaying
                            isSeeking = true
                            playback.pause()
                        } else {
                            playback.seek(to: seekPosition, resume: resumeAfterSeeking)
                            isSeeking = false
                        }
                    }
                )
                .disabled(playback.duration <= 0)
                .tint(Color.tidyAccent)
                .accessibilityLabel("视频播放进度")

                HStack {
                    Text(VideoDuration.text(isSeeking ? seekPosition : playback.currentTime))
                    Spacer()
                    Text(VideoDuration.text(playback.duration))
                }
                .font(.caption.monospacedDigit())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
        .onAppear { seekPosition = playback.currentTime }
        .onChange(of: playback.currentTime) { time in
            // 只按住进度条而没有拖动时，也应停留在当前进度，而不是跳回开头。
            if !isSeeking { seekPosition = time }
        }
    }
}

struct VideoPreviewView: View {
    let photo: PhotoItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var playback = VideoPlaybackModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let error = playback.errorMessage {
                VStack(spacing: 18) {
                    Image(systemName: "video.slash").font(.largeTitle)
                    Text(error).multilineTextAlignment(.center)
                    Button("重试") { playback.load(photo) }
                        .buttonStyle(.bordered)
                }
                .foregroundStyle(.white)
                .padding(24)
            } else if let player = playback.player {
                VideoPlayer(player: player)
            } else {
                VStack(spacing: 14) {
                    ProgressView().tint(.white)
                    Text(
                        playback.progress > 0
                            ? L10n.format("正在从 iCloud 加载视频… %lld%%", Int(playback.progress * 100))
                            : L10n.text("正在加载视频…")
                    )
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Label(photo.durationText, systemImage: "video.fill")
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(.black)
        }
        .task(id: photo.id) { playback.load(photo) }
        .onDisappear { playback.stop() }
        .onChange(of: scenePhase) { phase in
            if phase != .active { playback.pause() }
        }
    }
}
