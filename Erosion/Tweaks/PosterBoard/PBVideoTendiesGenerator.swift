import AVFoundation
import CoreImage
import Foundation
import UIKit
import ZIPFoundation

/// Builds a normal WallpaperKit .tendies package from a local video.
/// The package is imported by PBHandler and then follows the same Apply path
/// as every other Custom Wallpapers entry.
actor PBVideoTendiesGenerator {
    static let shared = PBVideoTendiesGenerator()

    private let maximumDuration: TimeInterval = 12
    private let targetFrameRate: Float = 30
    private let maximumOutputLongEdge: CGFloat = 1920
    private let fileManager = FileManager.default

    func makeTendies(from sourceURL: URL) async throws -> URL {
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("Erosion-Video-Tendies-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        // PBHandler looks for a top-level "descriptor" directory and imports
        // each child as a normal WallpaperKit CollectionsPoster descriptor.
        let packageRoot = workspace.appendingPathComponent("package", isDirectory: true)
        let descriptorsRoot = packageRoot.appendingPathComponent("descriptor", isDirectory: true)
        let descriptorURL = descriptorsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: descriptorsRoot, withIntermediateDirectories: true)

        try await createDescriptor(from: sourceURL, at: descriptorURL)

        let safeName = sourceURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        let packageURL = fileManager.temporaryDirectory
            .appendingPathComponent("\(safeName.isEmpty ? "Video Wallpaper" : safeName)-\(UUID().uuidString)")
            .appendingPathExtension("tendies")
        try fileManager.zipItem(at: packageRoot, to: packageURL, shouldKeepParent: false)
        return packageURL
    }

    private func createDescriptor(from sourceURL: URL, at descriptorURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let sourceDuration = try await asset.load(.duration)
        let sourceSeconds = CMTimeGetSeconds(sourceDuration)
        guard sourceSeconds.isFinite, sourceSeconds > 0 else {
            throw PBVideoTendiesError.invalidVideo
        }
        let clipDuration = min(sourceSeconds, maximumDuration)

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PBVideoTendiesError.invalidVideo
        }
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let transformedRect = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized
        let sourceWidth = Int(transformedRect.width.rounded())
        let sourceHeight = Int(transformedRect.height.rounded())
        guard sourceWidth > 0, sourceHeight > 0, nominalFrameRate > 0 else {
            throw PBVideoTendiesError.invalidVideo
        }

        // Match Placard: 30 FPS is the upper output rate; lower-rate sources
        // retain their native rate instead of manufacturing artificial frames.
        let outputFrameRate = min(nominalFrameRate, targetFrameRate)
        let maximumOutputLongEdge = self.maximumOutputLongEdge
        let outputSize = await MainActor.run {
            let nativeSize = UIScreen.main.nativeBounds.size
            let nativeLongEdge = max(nativeSize.width, nativeSize.height)
            let nativeShortEdge = min(nativeSize.width, nativeSize.height)
            let outputLongEdge = min(nativeLongEdge, maximumOutputLongEdge)
            // Match the active device's native display aspect ratio on both
            // iPhone and iPad. Each frame is then aspect-filled and center-cropped
            // below, so the wallpaper covers the screen without letterboxing.
            let ratio = nativeShortEdge / nativeLongEdge
            let shortEdge = max(2, ((outputLongEdge * ratio) / 2).rounded(.down) * 2)
            return CGSize(width: shortEdge, height: outputLongEdge)
        }
        let width = Int(outputSize.width)
        let height = Int(outputSize.height)
        guard width > 0, height > 0 else { throw PBVideoTendiesError.invalidVideo }

        let wallpaperName = "9183.Custom-810w-1080h@2x~ipad.wallpaper"
        let backgroundName = "9183.Custom_Background-810w-1080h@2x~ipad.ca"
        let floatingName = "9183.Custom_Floating-810w-1080h@2x~ipad.ca"
        let contentsURL = descriptorURL.appendingPathComponent("versions/1/contents", isDirectory: true)
        let wallpaperURL = contentsURL.appendingPathComponent(wallpaperName, isDirectory: true)
        let animationURL = wallpaperURL.appendingPathComponent(backgroundName, isDirectory: true)
        let assetsURL = animationURL.appendingPathComponent("assets", isDirectory: true)
        let floatingURL = wallpaperURL.appendingPathComponent(floatingName, isDirectory: true)
        try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: floatingURL, withIntermediateDirectories: true)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: clipDuration, preferredTimescale: 600)
        )
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw PBVideoTendiesError.invalidVideo }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? PBVideoTendiesError.invalidVideo
        }

        let ciContext = CIContext()
        var frameNames: [String] = []
        var lastFrameTime: CMTime?
        let frameInterval = CMTime(seconds: 1 / Double(outputFrameRate), preferredTimescale: 600)

        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if CMTimeGetSeconds(presentationTime) >= clipDuration { break }
            if let lastFrameTime,
               CMTimeCompare(CMTimeSubtract(presentationTime, lastFrameTime), frameInterval) < 0 {
                continue
            }

            let frameName = "\(frameNames.count).jpg"
            let jpeg = try autoreleasepool { () throws -> Data in
                guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    throw PBVideoTendiesError.frameEncodingFailed
                }
                let sourceImage = CIImage(cvPixelBuffer: imageBuffer)
                    .transformed(by: preferredTransform)
                let normalizedImage = sourceImage.transformed(
                    by: CGAffineTransform(
                        translationX: -sourceImage.extent.minX,
                        y: -sourceImage.extent.minY
                    )
                )
                guard normalizedImage.extent.width > 0, normalizedImage.extent.height > 0 else {
                    throw PBVideoTendiesError.frameEncodingFailed
                }
                let scale = max(
                    outputSize.width / normalizedImage.extent.width,
                    outputSize.height / normalizedImage.extent.height
                )
                let scaledImage = normalizedImage.transformed(
                    by: CGAffineTransform(scaleX: scale, y: scale)
                )
                let cropRect = CGRect(
                    x: scaledImage.extent.midX - outputSize.width / 2,
                    y: scaledImage.extent.midY - outputSize.height / 2,
                    width: outputSize.width,
                    height: outputSize.height
                )
                let outputImage = scaledImage.cropped(to: cropRect).transformed(
                    by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY)
                )
                guard let cgImage = ciContext.createCGImage(
                    outputImage,
                    from: CGRect(origin: .zero, size: outputSize)
                ), let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.7) else {
                    throw PBVideoTendiesError.frameEncodingFailed
                }
                return data
            }
            try jpeg.write(to: assetsURL.appendingPathComponent(frameName), options: .atomic)
            frameNames.append(frameName)
            lastFrameTime = presentationTime
        }

        guard !frameNames.isEmpty,
              reader.status == .completed || reader.status == .reading else {
            throw reader.error ?? PBVideoTendiesError.invalidVideo
        }
        if reader.status == .reading { reader.cancelReading() }

        print("(pb) video wallpaper frames ready: \(width)x\(height), \(frameNames.count) frames, \(String(format: "%.2f", clipDuration))s")
        let identifier = Int.random(in: 9_999...99_999)
        try makeDescriptorMetadata(
            at: descriptorURL,
            identifier: identifier,
            wallpaperName: wallpaperName,
            backgroundName: backgroundName,
            floatingName: floatingName,
            width: width,
            height: height
        )
        try caml(
            width: width,
            height: height,
            frameNames: frameNames,
            duration: clipDuration
        ).write(to: animationURL.appendingPathComponent("main.caml"), atomically: true, encoding: .utf8)
        try indexXML(width: width, height: height)
            .write(to: animationURL.appendingPathComponent("index.xml"), atomically: true, encoding: .utf8)
        try blankCAML()
            .write(to: floatingURL.appendingPathComponent("main.caml"), atomically: true, encoding: .utf8)
        try floatingIndexXML()
            .write(to: floatingURL.appendingPathComponent("index.xml"), atomically: true, encoding: .utf8)
    }

    private func makeDescriptorMetadata(
        at descriptorURL: URL,
        identifier: Int,
        wallpaperName: String,
        backgroundName: String,
        floatingName: String,
        width: Int,
        height: Int
    ) throws {
        try Data(String(identifier).utf8).write(
            to: descriptorURL.appendingPathComponent("com.apple.posterkit.provider.descriptor.identifier"),
            options: .atomic
        )
        try Data("PRPosterRoleLockScreen".utf8).write(
            to: descriptorURL.appendingPathComponent("com.apple.posterkit.role.identifier"),
            options: .atomic
        )
        let providerInfo = try NSKeyedArchiver.archivedData(
            withRootObject: ["kConfigurationLastUseDateKey": Date()],
            requiringSecureCoding: false
        )
        try providerInfo.write(to: descriptorURL.appendingPathComponent("providerInfo.plist"), options: .atomic)

        let contentsURL = descriptorURL.appendingPathComponent("versions/1/contents", isDirectory: true)
        let userInfo: [String: Any] = [
            "posterEnvironmentOverrides": Data("{}".utf8),
            "wallpaperRepresentingFileName": wallpaperName,
            "wallpaperRepresentingIdentifier": identifier
        ]
        try writePlist(
            userInfo,
            to: contentsURL.appendingPathComponent("com.apple.posterkit.provider.contents.userInfo")
        )

        let wallpaper: [String: Any] = [
            "appearanceAware": true,
            "assets": [
                "lockAndHome": [
                    "default": [
                        "backgroundAnimationFileName": backgroundName,
                        "floatingAnimationFileNameKey": floatingName,
                        "identifier": 9183,
                        "name": "Chip",
                        "type": "LayeredAnimation"
                    ]
                ]
            ],
            "contentVersion": 2.01,
            "family": "Chip",
            "identifier": identifier,
            "logicalScreenClass": "810w-1080h@2x~ipad",
            "name": "Chip",
            "preferredProminentColor": ["dark": "#00000", "default": "#FFFFFF"],
            "version": 1
        ]
        try writePlist(
            wallpaper,
            to: contentsURL.appendingPathComponent(wallpaperName, isDirectory: true)
                .appendingPathComponent("Wallpaper.plist")
        )
    }

    private func writePlist(_ value: Any, to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        try data.write(to: url, options: .atomic)
    }

    private func caml(width: Int, height: Int, frameNames: [String], duration: Double) -> String {
        let values = frameNames.map { "        <CGImage src=\"assets/\($0)\"/>" }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <caml xmlns="http://www.apple.com/CoreAnimation/1.0">
          <CALayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" bounds="0 0 \(width) \(height)" contentsFormat="RGBA8" cornerCurve="circular" hidden="0" name="_FLOATING" position="\(width / 2) \(height / 2)">
            <sublayers>
              <CATransformLayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" allowsHitTesting="1" bounds="0 0 \(width) \(height)" contentsFormat="RGBA8" cornerCurve="circular" name="Chip" position="\(width / 2) \(height / 2)">
                <sublayers>
                  <CALayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" bounds="0 0 \(width) \(height)" contentsFormat="RGBA8" cornerCurve="circular" name="CALayer1" position="\(width / 2) \(height / 2)">
                    <contents type="CGImage" src="assets/0.jpg"/>
                    <animations>
                      <animation type="CAKeyframeAnimation" calculationMode="linear" keyPath="contents" beginTime="1e-100" duration="\(duration)" removedOnCompletion="0" repeatCount="inf" repeatDuration="0" speed="1" timeOffset="0" autoreverses="0">
                        <values>
        \(values)
                        </values>
                      </animation>
                    </animations>
                  </CALayer>
                </sublayers>
              </CATransformLayer>
            </sublayers>
            <states><LKState name="Locked"><elements/></LKState><LKState name="Unlock"><elements/></LKState><LKState name="Sleep"><elements/></LKState></states>
            <stateTransitions><LKStateTransition fromState="*" toState="Unlock"><elements/></LKStateTransition><LKStateTransition fromState="Unlock" toState="*"><elements/></LKStateTransition><LKStateTransition fromState="*" toState="Locked"><elements/></LKStateTransition><LKStateTransition fromState="Locked" toState="*"><elements/></LKStateTransition><LKStateTransition fromState="*" toState="Sleep"><elements/></LKStateTransition><LKStateTransition fromState="Sleep" toState="*"><elements/></LKStateTransition></stateTransitions>
          </CALayer>
        </caml>
        """
    }

    private func blankCAML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <caml xmlns="http://www.apple.com/CoreAnimation/1.0">
          <CALayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" bounds="0 0 3176 3176" contentsFormat="RGBA8" cornerCurve="circular" hidden="0" name="_BACKGROUND" position="1588 1588">
            <sublayers><CALayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" anchorPoint="0 0" bounds="0 0 0 0" contentsFormat="RGBA8" cornerCurve="circular" name="_CENTER_BACKGROUND" position="1588 1588"/></sublayers>
            <states><LKState name="Locked"><elements/></LKState><LKState name="Unlock"><elements/></LKState><LKState name="Sleep"><elements/></LKState></states>
            <stateTransitions><LKStateTransition fromState="*" toState="Unlock"><elements/></LKStateTransition><LKStateTransition fromState="Unlock" toState="*"><elements/></LKStateTransition><LKStateTransition fromState="*" toState="Locked"><elements/></LKStateTransition><LKStateTransition fromState="Locked" toState="*"><elements/></LKStateTransition><LKStateTransition fromState="*" toState="Sleep"><elements/></LKStateTransition><LKStateTransition fromState="Sleep" toState="*"><elements/></LKStateTransition></stateTransitions>
          </CALayer>
        </caml>
        """
    }

    private func indexXML(width: Int, height: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>assetManifest</key><string>assetManifest.caml</string>
          <key>documentHeight</key><real>\(height)</real>
          <key>documentResizesToView</key><true/>
          <key>documentWidth</key><real>\(width)</real>
          <key>dynamicGuidesEnabled</key><true/>
          <key>geometryFlipped</key><false/>
          <key>guidesEnabled</key><true/>
          <key>interactiveMouseEventsEnabled</key><true/>
          <key>interactiveShowsCursor</key><true/>
          <key>interactiveTouchEventsEnabled</key><false/>
          <key>loopEnd</key><real>0.0</real>
          <key>loopStart</key><real>0.0</real>
          <key>loopingEnabled</key><false/>
          <key>multitouchDisablesMouse</key><false/>
          <key>multitouchEnabled</key><false/>
          <key>presentationMouseEventsEnabled</key><true/>
          <key>presentationShowsCursor</key><true/>
          <key>presentationTouchEventsEnabled</key><false/>
          <key>rootDocument</key><string>main.caml</string>
          <key>savesWindowFrame</key><false/>
          <key>scalesToFitInPlayer</key><true/>
          <key>showsTouches</key><true/>
          <key>snappingEnabled</key><true/>
          <key>timelineMarkers</key><string>[(null)]</string>
          <key>touchesColor</key><string>1 1 0 0.8</string>
          <key>unitsInPixelsInPlayer</key><true/>
        </dict></plist>
        """
    }

    private func floatingIndexXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>assetManifest</key><string>assetManifest.caml</string>
          <key>documentHeight</key><real>3176</real>
          <key>documentResizesToView</key><false/>
          <key>documentWidth</key><real>3176</real>
          <key>dynamicGuidesEnabled</key><true/>
          <key>geometryFlipped</key><false/>
          <key>guidesEnabled</key><true/>
          <key>interactiveMouseEventsEnabled</key><true/>
          <key>interactiveShowsCursor</key><true/>
          <key>interactiveTouchEventsEnabled</key><false/>
          <key>loopEnd</key><real>0.0</real>
          <key>loopStart</key><real>0.0</real>
          <key>loopingEnabled</key><false/>
          <key>multitouchDisablesMouse</key><false/>
          <key>multitouchEnabled</key><false/>
          <key>presentationMouseEventsEnabled</key><true/>
          <key>presentationShowsCursor</key><true/>
          <key>presentationTouchEventsEnabled</key><false/>
          <key>rootDocument</key><string>main.caml</string>
          <key>savesWindowFrame</key><false/>
          <key>scalesToFitInPlayer</key><false/>
          <key>showsTouches</key><true/>
          <key>snappingEnabled</key><true/>
          <key>timelineMarkers</key><string>[(null)]</string>
          <key>touchesColor</key><string>1 1 0 0.8</string>
          <key>unitsInPixelsInPlayer</key><true/>
        </dict></plist>
        """
    }
}

enum PBVideoTendiesError: LocalizedError {
    case invalidVideo
    case frameEncodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidVideo: "This video can't be read."
        case .frameEncodingFailed: "Failed to create the video wallpaper."
        }
    }
}
