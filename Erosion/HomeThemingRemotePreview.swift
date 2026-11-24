import SwiftUI
import Combine
import UIKit
import ImageIO
import AVFoundation

/// Remote previews used only by the Explore galleries. No preview files or
/// decoded images are retained between visits or application launches.
private actor HomeThemingImageDecoder {
    static let shared = HomeThemingImageDecoder()
    private var didClearLegacyCache = false

    func clearLegacyCacheIfNeeded() {
        guard !didClearLegacyCache else { return }
        didClearLegacyCache = true
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }
        let legacyDirectory = caches.appendingPathComponent("ErosionThemingPreviews", isDirectory: true)
        try? FileManager.default.removeItem(at: legacyDirectory)
    }

    func decode(_ data: Data, fileExtension: String) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }

        let frameCount = CGImageSourceGetCount(source)
        if fileExtension == "gif", frameCount > 1 {
            let maxFrames = 48
            let strideValue = max(1, Int(ceil(Double(frameCount) / Double(maxFrames))))
            let options: CFDictionary = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 720
            ] as CFDictionary
            var frames: [UIImage] = []
            var duration: TimeInterval = 0

            for index in stride(from: 0, to: frameCount, by: strideValue) {
                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, index, options) else {
                    continue
                }
                frames.append(UIImage(cgImage: cgImage))
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as NSDictionary?
                let gif = properties?[kCGImagePropertyGIFDictionary] as? NSDictionary
                let unclamped = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber
                let clamped = gif?[kCGImagePropertyGIFDelayTime] as? NSNumber
                duration += max(0.04, (unclamped ?? clamped)?.doubleValue ?? 0.1) * Double(strideValue)
            }
            if !frames.isEmpty {
                return UIImage.animatedImage(with: frames, duration: max(duration, 0.1))
            }
        }

        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1200
        ] as CFDictionary
        if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) {
            return UIImage(cgImage: thumbnail)
        }
        return UIImage(data: data)
    }
}

@MainActor
private final class HomeThemingPreviewLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var videoURL: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var failed = false

    private var loadedURL: String?

    func load(_ remoteURL: URL?) async {
        guard let remoteURL else {
            image = nil
            videoURL = nil
            failed = false
            loadedURL = nil
            return
        }

        let key = remoteURL.absoluteString
        guard loadedURL != key || failed else { return }
        loadedURL = key
        image = nil
        videoURL = nil
        failed = false
        isLoading = true
        defer { isLoading = false }

        do {
            await HomeThemingImageDecoder.shared.clearLegacyCacheIfNeeded()
            let ext = remoteURL.pathExtension.lowercased()
            if ["mp4", "mov", "m4v"].contains(ext) {
                // AVPlayer streams the remote URL directly; no local preview copy is made.
                videoURL = remoteURL
                return
            }

            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(from: remoteURL)
            if let response = response as? HTTPURLResponse,
               !(200...299).contains(response.statusCode) {
                throw URLError(.badServerResponse)
            }
            guard let decoded = await HomeThemingImageDecoder.shared.decode(
                data,
                fileExtension: ext
            ) else {
                throw URLError(.cannotDecodeContentData)
            }
            image = decoded
        } catch {
            failed = true
        }
    }
}

struct HomeThemingRemotePreview: View {
    enum Scaling {
        case fit
        case fill
    }

    let url: URL?
    var scaling: Scaling = .fit

    @StateObject private var loader = HomeThemingPreviewLoader()

    private var uiImageContentMode: UIView.ContentMode {
        scaling == .fill ? .scaleAspectFill : .scaleAspectFit
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let videoURL = loader.videoURL {
                    HomeThemingLoopingVideo(url: videoURL, scaling: scaling)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else if let image = loader.image {
                    HomeThemingAnimatedImage(image: image, contentMode: uiImageContentMode)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    // A failed preview stays in the loading state instead of
                    // showing the broken-photo placeholder in Explore.
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .clipped()
        .task(id: url?.absoluteString) {
            await loader.load(url)
        }
    }
}

private final class HomeThemingPreviewImageView: UIImageView {
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }
}

private struct HomeThemingAnimatedImage: UIViewRepresentable {
    let image: UIImage
    let contentMode: UIView.ContentMode

    func makeUIView(context: Context) -> HomeThemingPreviewImageView {
        let view = HomeThemingPreviewImageView()
        view.contentMode = contentMode
        view.clipsToBounds = true
        view.backgroundColor = .clear
        view.image = image
        if image.images != nil { view.startAnimating() }
        return view
    }

    func updateUIView(_ view: HomeThemingPreviewImageView, context: Context) {
        view.contentMode = contentMode
        if view.image !== image {
            view.image = image
            if image.images != nil {
                view.startAnimating()
            } else {
                view.stopAnimating()
            }
        }
    }
}

private final class HomeThemingVideoContainer: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct HomeThemingLoopingVideo: UIViewRepresentable {
    let url: URL
    let scaling: HomeThemingRemotePreview.Scaling

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> HomeThemingVideoContainer {
        let view = HomeThemingVideoContainer()
        let player = AVQueuePlayer()
        player.isMuted = true
        let item = AVPlayerItem(url: url)
        context.coordinator.player = player
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: item)
        view.playerLayer.player = player
        view.playerLayer.videoGravity = scaling == .fill ? .resizeAspectFill : .resizeAspect
        player.play()
        return view
    }

    func updateUIView(_ view: HomeThemingVideoContainer, context: Context) {
        view.playerLayer.videoGravity = scaling == .fill ? .resizeAspectFill : .resizeAspect
    }

    static func dismantleUIView(_ view: HomeThemingVideoContainer, coordinator: Coordinator) {
        coordinator.player?.pause()
        view.playerLayer.player = nil
    }

    final class Coordinator {
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
    }
}
