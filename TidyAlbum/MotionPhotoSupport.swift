import Combine
import Photos
import PhotosUI
import SwiftUI

@MainActor
final class MotionPhotoPlaybackModel: ObservableObject {
    @Published private(set) var activePhotoID: String?
    @Published private(set) var isHolding = false
    @Published private(set) var livePhoto: PHLivePhoto?
    @Published private(set) var animatedSource: AnimatedImageSource?
    @Published private(set) var progress = 0.0
    @Published private(set) var errorMessage: String?

    private var requestID: PHImageRequestID?
    private var decodeTask: Task<Void, Never>?
    private var generation: UUID?

    func beginPress(_ photo: PhotoItem) {
        guard photo.motionKind != .none else { return }
        if activePhotoID != photo.id { reset() }
        activePhotoID = photo.id
        isHolding = true
        errorMessage = nil
        // 已加载的当前张可以立即再次播放，不重复下载 iCloud 资源。
        guard livePhoto == nil, animatedSource == nil, requestID == nil, decodeTask == nil else { return }
        progress = 0
        let token = UUID()
        generation = token

        if let data = photo.animatedImageData {
            prepareAnimation(data, token: token)
            return
        }
        guard let identifier = photo.assetIdentifier,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            errorMessage = L10n.text("无法读取动态内容，请检查照片访问范围。")
            return
        }

        let progressHandler: PHAssetImageProgressHandler = { [weak self] value, _, _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.isHolding else { return }
                self.progress = value
            }
        }
        if photo.motionKind == .livePhoto {
            let options = PHLivePhotoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.progressHandler = progressHandler
            requestID = PHImageManager.default().requestLivePhoto(
                for: asset, targetSize: CGSize(width: 1_600, height: 1_600),
                contentMode: .aspectFit, options: options
            ) { [weak self] livePhoto, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, self.isHolding, !cancelled, !degraded else { return }
                    self.requestID = nil
                    self.livePhoto = livePhoto
                    if livePhoto == nil { self.errorMessage = L10n.text("实况照片加载失败，松手后长按重试。") }
                }
            }
        } else {
            let options = PHImageRequestOptions()
            options.version = .original
            options.isNetworkAccessAllowed = true
            options.progressHandler = progressHandler
            requestID = PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { [weak self] data, _, _, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, self.isHolding, !cancelled else { return }
                    self.requestID = nil
                    guard let data else {
                        self.errorMessage = L10n.text("动图加载失败，松手后长按重试。")
                        return
                    }
                    self.prepareAnimation(data, token: token)
                }
            }
        }
    }

    private func prepareAnimation(_ data: Data, token: UUID) {
        decodeTask = Task { [weak self] in
            let source = await Task.detached(priority: .userInitiated) {
                AnimatedImageSource(data: data)
            }.value
            guard !Task.isCancelled, let self, self.generation == token, self.isHolding else { return }
            self.decodeTask = nil
            self.animatedSource = source
            if source == nil { self.errorMessage = L10n.text("这张图片没有可播放的动态内容。") }
        }
    }

    func endPress() {
        isHolding = false
        generation = nil
        if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
        requestID = nil
        decodeTask?.cancel()
        decodeTask = nil
    }

    func reset() {
        endPress()
        activePhotoID = nil
        livePhoto = nil
        animatedSource = nil
        progress = 0
        errorMessage = nil
    }

    func reportDecodeFailure() {
        errorMessage = L10n.text("动图暂时无法播放，松手后长按重试。")
        animatedSource = nil
    }
}

struct MotionPhotoContent: View {
    @ObservedObject var playback: MotionPhotoPlaybackModel

    var body: some View {
        Group {
            if let error = playback.errorMessage {
                Text(error)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .padding(18)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
            } else if let livePhoto = playback.livePhoto {
                LivePhotoSurface(livePhoto: livePhoto)
            } else if let source = playback.animatedSource {
                AnimatedPhotoSurface(source: source, onFailure: playback.reportDecodeFailure)
            } else {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(
                        playback.progress > 0
                            ? L10n.format("正在加载… %lld%%", Int(playback.progress * 100))
                            : L10n.text("正在加载动态内容…")
                    )
                        .font(.subheadline)
                }
                .padding(18)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .foregroundStyle(.white)
        .allowsHitTesting(false)
    }
}

private struct LivePhotoSurface: UIViewRepresentable {
    let livePhoto: PHLivePhoto

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.playbackGestureRecognizer.isEnabled = false
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        guard view.livePhoto !== livePhoto else { return }
        view.livePhoto = livePhoto
        view.startPlayback(with: .full)
    }

    static func dismantleUIView(_ view: PHLivePhotoView, coordinator: ()) {
        view.stopPlayback()
        view.livePhoto = nil
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PHLivePhotoView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

private struct AnimatedPhotoSurface: UIViewRepresentable {
    let source: AnimatedImageSource
    let onFailure: () -> Void

    final class ImageView: UIImageView {
        private var playbackTask: Task<Void, Never>?
        private var source: AnimatedImageSource?

        func play(_ source: AnimatedImageSource, onFailure: @escaping () -> Void) {
            guard self.source !== source else { return }
            stop()
            self.source = source
            playbackTask = Task { @MainActor [weak self] in
                var index = 0
                while !Task.isCancelled {
                    let started = Date.timeIntervalSinceReferenceDate
                    let frame = await Task.detached(priority: .userInitiated) { source.frame(at: index) }.value
                    guard !Task.isCancelled else { return }
                    guard let frame else { onFailure(); return }
                    self?.image = UIImage(cgImage: frame.image)
                    let wait = max(0.001, frame.duration - (Date.timeIntervalSinceReferenceDate - started))
                    do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                    index = (index + 1) % source.frameCount
                }
            }
        }

        func stop() {
            playbackTask?.cancel()
            playbackTask = nil
            source = nil
            image = nil
        }
    }

    func makeUIView(context: Context) -> ImageView {
        let view = ImageView()
        view.contentMode = .scaleAspectFit
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ view: ImageView, context: Context) {
        view.play(source, onFailure: onFailure)
    }

    static func dismantleUIView(_ view: ImageView, coordinator: ()) { view.stop() }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ImageView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
