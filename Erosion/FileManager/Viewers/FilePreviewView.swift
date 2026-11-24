import SwiftUI
import AVKit
import QuickLook
import UIKit
import WebKit

/// In-app preview for common media and binary assets in a File Browser snapshot.
/// Binary files expose the same Copy/Share/Edit actions as the text viewer.
struct FilePreviewView: View {
    let url: URL
    let remotePath: String?
    let remoteWritable: Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage("textViewerSize") private var textViewerSize = 11
    @AppStorage("useMonospaced") private var useMonospaced = true
    @State private var isBinaryEditing = false
    @State private var isBinaryTextMode = false
    @State private var binaryEditText = ""
    @State private var remoteWriteStatus = ""

    init(url: URL, remotePath: String? = nil, remoteWritable: Bool = false) {
        self.url = url
        self.remotePath = remotePath
        self.remoteWritable = remoteWritable

        let isDylibOrDeb = ["dylib", "deb"].contains(url.pathExtension.lowercased())
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        let isEmptyTargetFile = isDylibOrDeb && fileSize == 0
        _isBinaryTextMode = State(initialValue: isEmptyTargetFile)
        _binaryEditText = State(initialValue: isEmptyTargetFile ? getFileText(url) : "")
    }

    private var useExtraViewers: Bool { true }

    private var ext: String { url.pathExtension.lowercased() }
    private var isImage: Bool {
        ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp", "svg"].contains(ext)
    }
    private var isCAR: Bool { ext == "car" }
    private var isVideo: Bool {
        ["mp4", "mov", "m4v"].contains(ext)
    }
    private var isAudio: Bool {
        ["mp3", "m4a", "wav", "aiff", "aif", "caf", "flac", "aac"].contains(ext)
    }
    private var isBinary: Bool {
        ["dylib", "bin", "so", "o", "deb"].contains(ext)
    }
    private var usesQuickLookForCurrentType: Bool {
        !useExtraViewers && (isImage || isCAR || isBinary)
    }
    private var hasDylibDebActions: Bool {
        ["dylib", "deb"].contains(ext)
    }
    private var hasDylibDebBinToolbarActions: Bool {
        ["dylib", "deb", "bin"].contains(ext)
    }
    private var hasImageViewerActions: Bool { isImage || isCAR }

    private func copyPreviewFile() {
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard copyDataToClipboard(data, fileName: url.lastPathComponent) else {
                throw NSError(domain: "Erosion.FilePreview", code: 1)
            }
            Haptic.shared.play(.soft)
        } catch {
            Alertinator.shared.alert(title: "Failed to copy file!", body: error.localizedDescription)
        }
    }

    private func exportPreviewFile() {
        let source = url.standardizedFileURL
        let tempDestination = URL.temporaryDirectory
            .appendingPathComponent(url.lastPathComponent)
            .standardizedFileURL
        if source == tempDestination {
            presentShareSheet(with: url)
        } else if let exportURL = makeTemp(url) {
            presentShareSheet(with: exportURL)
        } else {
            Alertinator.shared.alert(title: "Failed to export file!", body: Errors.checkLogs)
        }
    }
    private var canEditBinary: Bool {
        if remotePath != nil { return remoteWritable }
        return getFileItem(at: url).writable == true
    }

    private func binaryIsEmpty() -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value else {
            return false
        }
        return size == 0
    }

    private func beginBinaryEditing() {
        binaryEditText = getFileText(url)
        isBinaryTextMode = true
        isBinaryEditing = true
        Haptic.shared.play(.soft)
    }

    private func cancelBinaryEditing() {
        binaryEditText = getFileText(url)
        isBinaryEditing = false
        isBinaryTextMode = binaryIsEmpty()
    }

    private func saveBinaryEditing() {
        do {
            try Data(binaryEditText.utf8).write(to: url)
            isBinaryEditing = false
            isBinaryTextMode = binaryIsEmpty()
            Haptic.shared.play(.soft)

            guard let remotePath else { return }
            remoteWriteStatus = "Writing through Airlift…"
            Task {
                let ok = await AirliftBridge.shared.writeBack(localURL: url, remotePath: remotePath)
                await MainActor.run {
                    remoteWriteStatus = ok ? "Written to device" : "Airlift write failed — see Airlift log"
                }
            }
        } catch {
            Alertinator.shared.alert(title: "Failed to write file!", body: error.localizedDescription)
        }
    }

    private func shareBinaryFile() {
        let source = url.standardizedFileURL
        let temporaryURL = URL.temporaryDirectory
            .appendingPathComponent(url.lastPathComponent)
            .standardizedFileURL
        if source == temporaryURL {
            presentShareSheet(with: url)
        } else if let shareURL = makeTemp(url) {
            presentShareSheet(with: shareURL)
        }
    }

    var body: some View {
        Group {
            if usesQuickLookForCurrentType {
                QuickLookDirectPreview(url: url)
            } else if isCAR {
                CARAssetCatalogPreview(url: url)
            } else if isImage {
                ImagePreview(url: url)
            } else if isVideo {
                VideoFilePreview(url: url)
            } else if isAudio {
                AudioFilePreview(url: url)
            } else if isBinary && hasDylibDebActions && isBinaryTextMode {
                VStack(alignment: .leading, spacing: 0) {
                    if !remoteWriteStatus.isEmpty {
                        Text(remoteWriteStatus)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                    }
                    if isBinaryEditing {
                        TextEditor(text: $binaryEditText)
                            .font(.system(size: CGFloat(textViewerSize), design: useMonospaced ? .monospaced : .default))
                    } else {
                        ScrollView {
                            Text(binaryEditText)
                                .font(.system(size: CGFloat(textViewerSize), design: useMonospaced ? .monospaced : .default))
                                .padding(5)
                                .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                                .textSelection(.enabled)
                                .tint(Color.accentColor)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if isBinary {
                VStack(spacing: 0) {
                    if !remoteWriteStatus.isEmpty {
                        Text(remoteWriteStatus)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                    }
                    BinaryFilePreview(
                        url: url,
                        hideScrollIndicator: hasDylibDebActions
                    )
                }
            } else {
                QuickLookDirectPreview(url: url)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !usesQuickLookForCurrentType && hasDylibDebActions && !canEditBinary {
                HStack {
                    Spacer()
                    Button {
                        Alertinator.shared.alert(title: "View-Only File", body: "You can only read this file.")
                    } label: {
                        Image(systemName: "lock")
                            .padding(10)
                    }
                    .foregroundStyle(Color.accentColor)
                    .buttonStyle(.plain)
                    .padding(.trailing)
                    .ignoresSafeArea()
                }
            }
        }
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !usesQuickLookForCurrentType && hasDylibDebBinToolbarActions {
                    if isBinaryEditing {
                        // Editing mode mirrors Text Viewer: only Cancel remains on the left.
                        Button {
                            cancelBinaryEditing()
                        } label: {
                            ToolbarLabel("Cancel", symbol: "xmark")
                        }
                    } else if canEditBinary {
                        Menu {
                            Button(action: beginBinaryEditing) {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button(action: shareBinaryFile) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        } label: {
                            Label("Menu", systemImage: "ellipsis")
                                .labelStyle(.iconOnly)
                        }
                    } else {
                        Button(action: exportPreviewFile) {
                            Label("Export", systemImage: "square.and.arrow.up")
                                .labelStyle(.iconOnly)
                        }
                        .accessibilityLabel("Export")
                    }
                } else if !usesQuickLookForCurrentType && hasImageViewerActions {
                    Menu {
                        Button(action: copyPreviewFile) {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        Button(action: exportPreviewFile) {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Label("Menu", systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isBinaryEditing {
                    Button(role: .adaptiveConfirm, action: saveBinaryEditing) {
                        ToolbarLabel("Save", symbol: "checkmark")
                    }
                } else {
                    Button {
                        dismiss()
                    } label: {
                        ToolbarLabel("Close", symbol: "xmark")
                    }
                }
            }
        }
    }
}

private struct ImagePreview: View {
    let url: URL
    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    @State private var image: UIImage?
    @State private var svgData: Data?
    @State private var svgDimensions: CGSize?
    @State private var isLoadingSVG = false

    private var isSVG: Bool { url.pathExtension.lowercased() == "svg" }

    private var zoomAndPanGesture: some Gesture {
        SimultaneousGesture(
            MagnificationGesture()
                .onChanged { value in scale = min(max(committedScale * value, 0.25), 8) }
                .onEnded { _ in committedScale = scale },
            DragGesture()
                .onChanged { value in
                    offset = CGSize(
                        width: committedOffset.width + value.translation.width,
                        height: committedOffset.height + value.translation.height
                    )
                }
                .onEnded { _ in committedOffset = offset }
        )
    }

    private func resetZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            scale = 1
            committedScale = 1
            offset = .zero
            committedOffset = .zero
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(String(format: "%.1f×", Double(scale)))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            GeometryReader { proxy in
                ZStack {
                    if isSVG {
                        if let svgData {
                            SVGDocumentPreview(data: svgData)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .scaleEffect(scale)
                                .offset(offset)
                        } else if isLoadingSVG {
                            ProgressView("Loading SVG…")
                        } else {
                            ContentUnavailableView("Unable to Open Image", systemImage: "photo", description: Text(url.lastPathComponent))
                        }
                    } else if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(scale)
                            .offset(offset)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    } else {
                        ContentUnavailableView("Unable to Open Image", systemImage: "photo", description: Text(url.lastPathComponent))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(zoomAndPanGesture)
                .onTapGesture(count: 2, perform: resetZoom)
                .clipped()
            }

            Group {
                if isSVG {
                    if let svgDimensions {
                        Text("\(Int(svgDimensions.width.rounded())) × \(Int(svgDimensions.height.rounded()))")
                    } else {
                        Text("SVG")
                    }
                } else if let image {
                    Text("\(Int(image.size.width * image.scale)) × \(Int(image.size.height * image.scale))")
                } else {
                    Text("—")
                }
            }
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color.black.opacity(0.04))
        .task(id: url) {
            image = nil
            svgData = nil
            svgDimensions = nil
            if isSVG {
                isLoadingSVG = true
                let sourceURL = url
                let loadedData = await Task.detached(priority: .utility) {
                    try? Data(contentsOf: sourceURL, options: [.mappedIfSafe])
                }.value
                svgData = loadedData
                svgDimensions = loadedData.flatMap { SVGDocumentDimensions.parse($0) }
                isLoadingSVG = false
            } else {
                image = UIImage(contentsOfFile: url.path)
            }
        }
    }
}

/// A sandboxed, script-disabled WebKit surface used only to render the SVG as
/// an image. The document is embedded as a data URL and cannot load external
/// resources, so SVG script or remote content is never executed/fetched.
private struct SVGDocumentPreview: UIViewRepresentable {
    let data: Data

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = false
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences = preferences
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isUserInteractionEnabled = false
        context.coordinator.lastData = data
        webView.loadHTMLString(Self.html(for: data), baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastData != data else { return }
        context.coordinator.lastData = data
        webView.loadHTMLString(Self.html(for: data), baseURL: nil)
    }

    private static func html(for data: Data) -> String {
        let encoded = data.base64EncodedString()
        return """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline';">
          <style>
            html, body { width: 100%; height: 100%; margin: 0; padding: 0; overflow: hidden; background: transparent; }
            body { display: flex; align-items: center; justify-content: center; }
            img { display: block; max-width: 100%; max-height: 100%; width: auto; height: auto; object-fit: contain; }
          </style>
        </head>
        <body><img alt="SVG image" src="data:image/svg+xml;base64,\(encoded)"></body>
        </html>
        """
    }

    final class Coordinator {
        var lastData: Data?
    }
}

private enum SVGDocumentDimensions {
    static func parse(_ data: Data) -> CGSize? {
        guard let source = String(data: data, encoding: .utf8) else { return nil }

        if let viewBox = firstMatch(
            pattern: #"(?i)viewBox\s*=\s*[\"']\s*([-+0-9.eE]+)[ ,]+([-+0-9.eE]+)[ ,]+([-+0-9.eE]+)[ ,]+([-+0-9.eE]+)"#,
            in: source,
            captureCount: 4
        ), let width = Double(viewBox[2]), let height = Double(viewBox[3]), width > 0, height > 0 {
            return CGSize(width: CGFloat(width), height: CGFloat(height))
        }

        let width = firstMatch(pattern: #"(?i)\bwidth\s*=\s*[\"']\s*([0-9]+(?:\.[0-9]+)?)"#, in: source, captureCount: 1)
            .flatMap { Double($0[0]) }
        let height = firstMatch(pattern: #"(?i)\bheight\s*=\s*[\"']\s*([0-9]+(?:\.[0-9]+)?)"#, in: source, captureCount: 1)
            .flatMap { Double($0[0]) }
        guard let width, let height, width > 0, height > 0 else { return nil }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    private static func firstMatch(pattern: String, in source: String, captureCount: Int) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else {
            return nil
        }
        return (1...captureCount).compactMap { index in
            guard index < match.numberOfRanges,
                  let range = Range(match.range(at: index), in: source) else { return nil }
            return String(source[range])
        }
    }
}

private struct VideoFilePreview: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var failureMessage: String?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .onDisappear { player.pause() }
            } else if isLoading {
                ProgressView("Loading video…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Unable to Play Video",
                    systemImage: "video.slash",
                    description: Text(failureMessage ?? url.lastPathComponent)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
        .task(id: url) {
            player?.pause()
            player = nil
            isLoading = true
            failureMessage = nil
            do {
                let asset = AVURLAsset(url: url)
                let playable = try await asset.load(.isPlayable)
                guard playable else {
                    failureMessage = "This movie uses an unsupported or invalid video format."
                    isLoading = false
                    return
                }
                let item = AVPlayerItem(asset: asset)
                let newPlayer = AVPlayer(playerItem: item)
                player = newPlayer
                isLoading = false
                newPlayer.play()
            } catch {
                failureMessage = error.localizedDescription
                isLoading = false
            }
        }
        .onDisappear {
            player?.pause()
        }
    }
}

private struct AudioFilePreview: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)

            Text(url.lastPathComponent)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal)

            if let player {
                HStack(spacing: 28) {
                    Button {
                        if isPlaying {
                            player.pause()
                        } else {
                            player.play()
                        }
                        isPlaying.toggle()
                    } label: {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 56))
                    }
                    .buttonStyle(.plain)

                    Button {
                        player.seek(to: .zero)
                        isPlaying = false
                    } label: {
                        Image(systemName: "backward.end.circle")
                            .font(.system(size: 38))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ProgressView()
            }

            Text(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .task(id: url) {
            player = AVPlayer(url: url)
            isPlaying = false
        }
        .onDisappear {
            player?.pause()
            isPlaying = false
        }
    }

    private var fileSize: Int64 {
        Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
    }
}

private struct BinaryFilePreview: View {
    let url: URL
    let hideScrollIndicator: Bool

    var body: some View {
        HexDumpView(url: url, hideScrollIndicator: hideScrollIndicator)
    }
}

private struct HexDumpView: View {
    let url: URL
    let hideScrollIndicator: Bool

    @State private var data = Data()
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        GeometryReader { geometry in
            // Keep the file memory-mapped and create only visible row views.
            // This avoids both the previous 1 MiB truncation and allocating a
            // formatted string for every byte in a large library at once.
            let characterCapacity = Int(max(0, geometry.size.width - 12) / 6)
            let bytesPerLine = max(4, min(32, (characterCapacity - 12) / 4))
            let lineCount = data.isEmpty ? 0 : (data.count + bytesPerLine - 1) / bytesPerLine

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(12)
                    } else if isLoading {
                        ProgressView("Loading…")
                            .padding(24)
                    } else if data.isEmpty {
                        Text("File is empty.")
                            .font(.system(size: 12, design: .monospaced))
                            .padding(24)
                    } else {
                        ForEach(0..<lineCount, id: \.self) { lineIndex in
                            let offset = lineIndex * bytesPerLine
                            let end = min(offset + bytesPerLine, data.count)
                            HexLineView(
                                offset: offset,
                                bytes: Array(data[offset..<end]),
                                bytesPerLine: bytesPerLine
                            )
                        }
                    }
                }
                .frame(width: geometry.size.width, alignment: .leading)
            }
            .scrollIndicators(hideScrollIndicator ? .hidden : .automatic)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Color(.systemBackground))
        .task(id: url) {
            errorMessage = nil
            isLoading = true
            data = Data()
            do {
                let sourceURL = url
                let loadedData = try await Task.detached(priority: .utility) {
                    try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
                }.value
                data = loadedData
            } catch {
                errorMessage = "Unable to read file: \(error.localizedDescription)"
            }
            isLoading = false
        }
    }
}

private struct HexLineView: View {
    let offset: Int
    let bytes: [UInt8]
    let bytesPerLine: Int

    var body: some View {
        Text(renderedLine)
            .font(.system(size: 10, design: .monospaced))
            .textSelection(.enabled)
            .tint(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var renderedLine: String {
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        let paddedHex = hex.padding(toLength: max(0, bytesPerLine * 3 - 1), withPad: " ", startingAt: 0)
        let ascii = bytes.map { byte -> Character in
            (byte >= 0x20 && byte < 0x7F) ? Character(UnicodeScalar(byte)) : "."
        }
        return String(format: "%08X  %@  %@", offset, paddedHex, String(ascii))
    }
}

struct QuickLookDirectPreview: View {
    let url: URL
    @State private var previewURL: URL?

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .quickLookPreview($previewURL)
            .task(id: url) {
                // Present only after the Quick Look host is attached to the view tree.
                await Task.yield()
                previewURL = url
            }
    }
}

