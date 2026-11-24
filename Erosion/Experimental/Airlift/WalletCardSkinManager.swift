import Foundation
import UIKit
import Combine

private func airliftWalletSyslogCallback(_ ctx: UnsafeMutableRawPointer?, _ line: UnsafePointer<CChar>?) {
    guard let line else { return }
    let text = String(cString: line)
    Task { @MainActor in
        WalletCardSkinManager.shared?.processSyslogLine(text)
    }
}

enum WalletCardOverlayType: String, CaseIterable, Identifiable {
    case standard = "default"
    case stretch = "stretch"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return "Default"
        case .stretch: return "Stretch"
        }
    }
}

@MainActor
final class WalletCardSkinManager: ObservableObject {
    static weak var shared: WalletCardSkinManager?

    private static let savedCardIDsKey = "erosion.walletCardEditor.savedCardIDs"
    private static let savedActiveCardIDKey = "erosion.walletCardEditor.savedActiveCardID"
    private static let savedPanOffsetsKey = "erosion.walletCardEditor.panOffsets"
    private static let savedOverlayTypeKey = "erosion.walletCardEditor.overlayType"
    private static let currentArtworkPreviewOverrideKey = "erosion.walletCardEditor.currentArtworkPreviewOverrides"
    // Kept only in memory for this app session, matching Custom Passcode's log
    // lifetime: leaving the editor preserves output, but relaunching clears it.
    private static var sessionFlashLog: [String] = []

    @Published private(set) var cardIDs: [String] = [] {
        didSet { UserDefaults.standard.set(cardIDs, forKey: Self.savedCardIDsKey) }
    }
    @Published var selectedCardIDs: Set<String> = []
    @Published var imageData: Data?
    @Published private(set) var activeCardID: String? {
        didSet {
            if let activeCardID {
                UserDefaults.standard.set(activeCardID, forKey: Self.savedActiveCardIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.savedActiveCardIDKey)
            }
        }
    }
    @Published private(set) var currentArtworkByCardID: [String: Data] = [:]
    @Published private(set) var panOffsetsByCardID: [String: CGSize] = [:]
    @Published var overlayType: WalletCardOverlayType = .standard {
        didSet { UserDefaults.standard.set(overlayType.rawValue, forKey: Self.savedOverlayTypeKey) }
    }
    @Published private(set) var isScanning = false
    @Published private(set) var isReadingArtworks = false
    @Published private(set) var scanStatus = ""
    @Published private(set) var flashRunning = false
    @Published private(set) var flashLog: [String] = []
    @Published private(set) var lastApplySucceeded: Bool? = nil
    @Published var manualCardID = ""

    private var editedArtworkByCardID: [String: Data] = [:]
    @Published private var currentArtworkPreviewOverrides: Set<String> = []
    private var artworkReadsInFlight: Set<String> = []
    private var pendingArtworkReadIDs: [String] = []
    private var artworkReadBatchTotal = 0
    private var artworkReadBatchCompleted = 0
    private var artworkReadBatchLoaded = 0

    private static let cardRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: "/(?:Cards|Passes/Cards)/([-A-Za-z0-9_+=]{20,64})(?:\\.pkpass|\\.cache|\\.pkcache|/|\\s|\"|'|\\)|,|$)"),
        try! NSRegularExpression(pattern: "/([-A-Za-z0-9_+=]{20,64})\\.(?:pkpass|cache|pkcache)"),
        try! NSRegularExpression(pattern: "(?<![A-Za-z0-9+/_-])([A-Za-z0-9+/_-]{27}=)(?![A-Za-z0-9+/_-])")
    ]

    init() {
        Self.shared = self

        let defaults = UserDefaults.standard
        let savedIDs = defaults.stringArray(forKey: Self.savedCardIDsKey) ?? []
        cardIDs = savedIDs
        overlayType = WalletCardOverlayType(rawValue: defaults.string(forKey: Self.savedOverlayTypeKey) ?? "default") ?? .standard
        currentArtworkPreviewOverrides = Set(defaults.stringArray(forKey: Self.currentArtworkPreviewOverrideKey) ?? [])

        if let savedActive = defaults.string(forKey: Self.savedActiveCardIDKey),
           savedIDs.contains(savedActive) {
            activeCardID = savedActive
            selectedCardIDs = [savedActive]
        } else if let first = savedIDs.first {
            activeCardID = first
            selectedCardIDs = [first]
        }

        let savedOffsets = defaults.dictionary(forKey: Self.savedPanOffsetsKey) as? [String: [Double]] ?? [:]
        panOffsetsByCardID = savedOffsets.reduce(into: [:]) { result, item in
            guard item.value.count >= 2 else { return }
            result[item.key] = Self.clampedPanPosition(CGSize(width: item.value[0], height: item.value[1]))
        }

        var currentCache: [String: Data] = [:]
        var editedCache: [String: Data] = [:]
        for cardID in savedIDs {
            if let data = Self.readArtworkCache(cardID: cardID, kind: .current), UIImage(data: data) != nil {
                currentCache[cardID] = data
            }
            if let data = Self.readArtworkCache(cardID: cardID, kind: .edited), UIImage(data: data) != nil {
                editedCache[cardID] = data
            }
        }
        currentArtworkByCardID = currentCache
        editedArtworkByCardID = editedCache
        flashLog = Self.sessionFlashLog
        if let activeCardID {
            if currentArtworkPreviewOverrides.contains(activeCardID) {
                imageData = currentCache[activeCardID] ?? editedCache[activeCardID]
            } else {
                imageData = editedCache[activeCardID] ?? currentCache[activeCardID]
            }
        }
    }

    var canApply: Bool {
        !flashRunning
            && cardIDs.contains(where: { editedArtworkByCardID[$0] != nil })
            && AirliftBridge.shared.airliftFeatureReady()
    }

    func displayedArtworkData(for cardID: String) -> Data? {
        if currentArtworkPreviewOverrides.contains(cardID),
           let currentArtwork = currentArtworkByCardID[cardID] {
            return currentArtwork
        }
        return editedArtworkByCardID[cardID] ?? currentArtworkByCardID[cardID]
    }

    private func persistCurrentArtworkPreviewOverrides() {
        UserDefaults.standard.set(
            Array(currentArtworkPreviewOverrides).sorted(),
            forKey: Self.currentArtworkPreviewOverrideKey
        )
    }

    func selectCard(_ cardID: String) {
        guard cardIDs.contains(cardID) else { return }
        activeCardID = cardID
        selectedCardIDs = [cardID]
        loadPersistedArtworkIfNeeded(for: cardID)
        imageData = displayedArtworkData(for: cardID)
    }

    /// Explicitly read the current artwork for known cards. Nothing triggers
    /// remote card-image reads automatically: the user starts them from the menu.
    func getCurrentArtworks() {
        guard AirliftBridge.shared.airliftFeatureReady() else {
            appendLog("❌ LocalDevVPN + pairing are required to get current artwork")
            return
        }
        guard !isReadingArtworks else {
            appendLog("Current artwork reads are already running")
            return
        }
        guard !cardIDs.isEmpty else {
            appendLog("No cards are available to read")
            return
        }

        // Snapshot every hash currently in the editor and read them in list order.
        // Keep only one card-image request in flight at a time: the remote read
        // primitive is shared and serializing these calls avoids one read replacing
        // or starving another when several cards are queued together.
        pendingArtworkReadIDs = cardIDs.filter { !artworkReadsInFlight.contains($0) }
        guard !pendingArtworkReadIDs.isEmpty else {
            appendLog("Current artwork reads are already queued for all listed cards")
            return
        }
        artworkReadBatchTotal = pendingArtworkReadIDs.count
        artworkReadBatchCompleted = 0
        artworkReadBatchLoaded = 0
        isReadingArtworks = true
        appendLog("Reading current artwork for \(artworkReadBatchTotal) card(s), in list order…")
        readNextCurrentArtwork()
    }

    func setImageData(_ data: Data) {
        guard !data.isEmpty, UIImage(data: data) != nil, let activeCardID else { return }
        // Keep the original import. Default previews/crops it; Stretch flattens
        // it only when the card files are prepared for Apply.
        imageData = data
        currentArtworkPreviewOverrides.remove(activeCardID)
        persistCurrentArtworkPreviewOverrides()
        editedArtworkByCardID[activeCardID] = data
        Self.writeArtworkCache(data, cardID: activeCardID, kind: .edited)
        setPanPosition(.zero, for: activeCardID)
        appendLog("Loaded source artwork; overlay type: \(overlayType.title).")
    }

    func clearImage() {
        imageData = nil
        if let activeCardID {
            editedArtworkByCardID.removeValue(forKey: activeCardID)
            Self.removeArtworkCache(cardID: activeCardID, kind: .edited)
            setPanPosition(.zero, for: activeCardID)
            imageData = currentArtworkByCardID[activeCardID]
        }
    }

    func panPosition(for cardID: String) -> CGSize {
        panOffsetsByCardID[cardID] ?? .zero
    }

    func setPanPosition(_ position: CGSize, for cardID: String, persist: Bool = true) {
        panOffsetsByCardID[cardID] = Self.clampedPanPosition(position)
        guard persist else { return }
        let values = panOffsetsByCardID.mapValues { [Double($0.width), Double($0.height)] }
        UserDefaults.standard.set(values, forKey: Self.savedPanOffsetsKey)
    }

    func clearScanResults() {
        stopScanning()

        // Forget only card-specific Erosion state for the cards currently known
        // to this editor. Later scans can add them again and build fresh state.
        let cardIDsToForget = Set(cardIDs)
            .union(currentArtworkByCardID.keys)
            .union(editedArtworkByCardID.keys)
            .union(panOffsetsByCardID.keys)
            .union(activeCardID.map { [$0] } ?? [])

        for cardID in cardIDsToForget {
            Self.removeArtworkCache(cardID: cardID, kind: .current)
            Self.removeArtworkCache(cardID: cardID, kind: .edited)
        }

        currentArtworkPreviewOverrides.subtract(cardIDsToForget)
        persistCurrentArtworkPreviewOverrides()
        panOffsetsByCardID = panOffsetsByCardID.filter { !cardIDsToForget.contains($0.key) }
        let persistedOffsets = panOffsetsByCardID.mapValues { [Double($0.width), Double($0.height)] }
        UserDefaults.standard.set(persistedOffsets, forKey: Self.savedPanOffsetsKey)

        cardIDs.removeAll()
        selectedCardIDs.removeAll()
        activeCardID = nil
        imageData = nil
        currentArtworkByCardID.removeAll()
        editedArtworkByCardID.removeAll()
        appendLog("Cleared scanned card list and removed saved Erosion artwork for those cards. Cards can be scanned or added again later.")
    }

    func toggleSelected(_ id: String) {
        if selectedCardIDs.contains(id) {
            selectedCardIDs.remove(id)
        } else {
            selectedCardIDs.insert(id)
        }
    }

    func selectAll() {
        selectedCardIDs = Set(cardIDs)
    }

    func deselectAll() {
        selectedCardIDs.removeAll()
    }

    func addManualCard() {
        guard let clean = Self.cleanCardID(manualCardID) else {
            appendLog("❌ Invalid card identifier")
            return
        }
        if !cardIDs.contains(clean) {
            cardIDs.append(clean)
        }
        manualCardID = ""
        selectCard(clean)
        appendLog("Added card: \(clean.prefix(12))…")
    }

    func startScanning() {
        guard !isScanning else { return }
        let pairingPath = PairingController.pairingFilePath()
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            appendLog("❌ No pairing file")
            return
        }

        isScanning = true
        scanStatus = "Open Apple Pay and tap the card…"
        appendLog("Started Wallet card scanner")
        AirliftBridge.shared.beginFeatureOperationLogScope()

        let thread = Thread {
            var outError: UnsafeMutablePointer<CChar>? = nil
            let rc = pairingPath.withCString { pairC in
                al_syslog_stream_start(pairC, airliftWalletSyslogCallback, nil, &outError)
            }
            let err = outError.flatMap { p -> String? in
                let s = String(validatingUTF8: p)
                al_string_free(p)
                return s
            }
            Task { @MainActor in
                guard let manager = WalletCardSkinManager.shared else { return }
                manager.isScanning = false
                AirliftBridge.shared.endFeatureOperationLogScope()
                if rc != 0 {
                    manager.scanStatus = "Scanner stopped: \(err ?? "rc=\(rc)")"
                    manager.appendLog("❌ Scanner error: \(err ?? "rc=\(rc)")")
                } else {
                    manager.scanStatus = "Scanning stopped. Cards: \(manager.cardIDs.count)"
                }
            }
        }
        thread.name = "Erosion.WalletCardScanner"
        thread.stackSize = 4 * 1024 * 1024
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stopScanning() {
        al_syslog_stream_stop()
        isScanning = false
        scanStatus = "Scanning stopped. Cards: \(cardIDs.count)"
    }

    func processSyslogLine(_ line: String) {
        let lower = line.lowercased()
        guard lower.contains("wallet") || lower.contains("passbook") || lower.contains("passkit") ||
              lower.contains("pdcardfilemanager") || lower.contains("pdpasslibrary") || lower.contains("/cards/") else { return }

        for regex in Self.cardRegexes {
            for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: line),
                      let clean = Self.cleanCardID(String(line[range])) else { continue }
                if !cardIDs.contains(clean) {
                    cardIDs.append(clean)
                    scanStatus = "Found card: \(clean.prefix(12))…"
                    appendLog("Found card: \(clean)")
                    if activeCardID == nil {
                        selectCard(clean)
                    }
                }
            }
        }
    }

    private func readNextCurrentArtwork() {
        guard !pendingArtworkReadIDs.isEmpty else {
            isReadingArtworks = !artworkReadsInFlight.isEmpty
            appendLog("Finished reading current artwork: \(artworkReadBatchLoaded)/\(artworkReadBatchTotal) loaded")
            return
        }

        let cardID = pendingArtworkReadIDs.removeFirst()
        guard artworkReadsInFlight.insert(cardID).inserted else {
            readNextCurrentArtwork()
            return
        }

        isReadingArtworks = true
        let index = artworkReadBatchCompleted + 1
        let basePath = "/var/mobile/Library/Passes/Cards/\(cardID).pkpass/cardBackgroundCombined"
        appendLog("[\(index)/\(artworkReadBatchTotal)] Reading artwork for \(cardID)…")
        AirliftBridge.shared.readRemoteImageFile(
            preferredPath: basePath + "@2x.png",
            fallbackPath: basePath + "@3x.png"
        ) { [weak self] data in
            guard let self else { return }
            self.artworkReadsInFlight.remove(cardID)
            self.artworkReadBatchCompleted += 1
            if let data, UIImage(data: data) != nil {
                self.currentArtworkByCardID[cardID] = data
                self.currentArtworkPreviewOverrides.insert(cardID)
                self.persistCurrentArtworkPreviewOverrides()
                Self.writeArtworkCache(data, cardID: cardID, kind: .current)
                if self.activeCardID == cardID {
                    self.imageData = data
                }
                self.artworkReadBatchLoaded += 1
                self.appendLog("[\(self.artworkReadBatchCompleted)/\(self.artworkReadBatchTotal)] Loaded and cached artwork for \(cardID)…")
            } else {
                self.appendLog("[\(self.artworkReadBatchCompleted)/\(self.artworkReadBatchTotal)] Could not load artwork for \(cardID)…")
            }

            // Start the next hash only after this callback completes, ensuring the
            // queue visits every listed card independently and in the visible order.
            self.readNextCurrentArtwork()
        }
    }

    private func loadPersistedArtworkIfNeeded(for cardID: String) {
        if currentArtworkByCardID[cardID] == nil,
           let data = Self.readArtworkCache(cardID: cardID, kind: .current), UIImage(data: data) != nil {
            currentArtworkByCardID[cardID] = data
        }
        if editedArtworkByCardID[cardID] == nil,
           let data = Self.readArtworkCache(cardID: cardID, kind: .edited), UIImage(data: data) != nil {
            editedArtworkByCardID[cardID] = data
        }
    }

    func applySelectedCards() {
        // Each card keeps its own imported image and pan offset. Build the target
        // list in the scanned-card order rather than relying on the single active
        // card or the selection that is changed while switching between cards.
        let targets: [(cardID: String, imageData: Data, panPosition: CGSize)] = cardIDs.compactMap { cardID in
            guard let data = editedArtworkByCardID[cardID] else { return nil }
            return (cardID, data, panPosition(for: cardID))
        }
        guard canApply, !targets.isEmpty else { return }

        let selectedOverlayType = overlayType
        let pairingPath = PairingController.pairingFilePath()
        flashRunning = true
        lastApplySucceeded = nil
        flashLog.removeAll()
        Self.sessionFlashLog.removeAll()
        appendLog("Applying individual artwork to \(targets.count) card(s), sequentially")
        AirliftBridge.shared.beginFeatureOperationLogScope()

        DispatchQueue.global(qos: .userInitiated).async {
            var success = 0
            var failed = 0

            for (index, targetCard) in targets.enumerated() {
                Task { @MainActor in
                    WalletCardSkinManager.shared?.appendFlashLog("[\(index + 1)/\(targets.count)] Preparing \(targetCard.cardID.prefix(12))…")
                }

                guard let image = UIImage(data: targetCard.imageData),
                      let skins = Self.prepareAllCardSkins(
                        from: image,
                        overlayType: selectedOverlayType,
                        panPosition: targetCard.panPosition
                      ),
                      !skins.isEmpty else {
                    failed += 1
                    Task { @MainActor in
                        WalletCardSkinManager.shared?.appendFlashLog("  ❌ Could not prepare artwork for this card")
                    }
                    continue
                }

                let stage = FileManager.default.temporaryDirectory
                    .appendingPathComponent("erosion_wallet_\(UUID().uuidString)", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                    for (name, data) in skins {
                        try data.write(to: stage.appendingPathComponent(name), options: .atomic)
                    }
                } catch {
                    failed += 1
                    try? FileManager.default.removeItem(at: stage)
                    let message = error.localizedDescription
                    Task { @MainActor in
                        WalletCardSkinManager.shared?.appendFlashLog("  ❌ Failed to stage artwork: \(message)")
                    }
                    continue
                }

                let target = "/var/mobile/Library/Passes/Cards/\(targetCard.cardID).pkpass"
                Task { @MainActor in
                    WalletCardSkinManager.shared?.appendFlashLog("[\(index + 1)/\(targets.count)] Writing \(targetCard.cardID.prefix(12))…")
                }
                // This call is synchronous. Do not start the next card until the
                // current directory write has fully returned.
                let ok = Self.writeDirectory(pairingPath: pairingPath, source: stage.path, target: target)
                try? FileManager.default.removeItem(at: stage)

                if ok {
                    success += 1
                    if let appliedArtwork = skins["cardBackgroundCombined@3x.png"] {
                        Task { @MainActor in
                            guard let manager = WalletCardSkinManager.shared else { return }
                            manager.currentArtworkByCardID[targetCard.cardID] = appliedArtwork
                            Self.writeArtworkCache(appliedArtwork, cardID: targetCard.cardID, kind: .current)
                            manager.appendFlashLog("  ✅ Artwork written")
                        }
                    } else {
                        Task { @MainActor in WalletCardSkinManager.shared?.appendFlashLog("  ✅ Artwork written") }
                    }
                    Self.invalidateCache(pairingPath: pairingPath, cardID: targetCard.cardID)
                    Task { @MainActor in WalletCardSkinManager.shared?.appendFlashLog("  ✅ Wallet cache invalidated") }
                } else {
                    failed += 1
                    Task { @MainActor in WalletCardSkinManager.shared?.appendFlashLog("  ❌ Failed to write card") }
                }
            }

            Task { @MainActor in
                WalletCardSkinManager.shared?.appendFlashLog("Finished: \(success)/\(targets.count) card(s) applied; \(failed) failed")
                WalletCardSkinManager.shared?.lastApplySucceeded = !targets.isEmpty && success == targets.count
                WalletCardSkinManager.shared?.flashRunning = false
                AirliftBridge.shared.endFeatureOperationLogScope()
            }
        }
    }

    func appendLog(_ line: String) {
        flashLog.append(line)
        if flashLog.count > 200 { flashLog.removeFirst(flashLog.count - 160) }
        Self.sessionFlashLog = flashLog
        if isAirliftCompatibilityMode() {
            AirliftBridge.shared.appendFeatureLog("cards", line)
        }
    }

    private func appendFlashLog(_ line: String) {
        appendLog(line)
    }

    private static func writeDirectory(pairingPath: String, source: String, target: String) -> Bool {
        var outError: UnsafeMutablePointer<CChar>? = nil
        let rc = pairingPath.withCString { p in
            source.withCString { s in
                target.withCString { t in
                    al_exploit_write_dir(p, s, t, nil, nil, &outError)
                }
            }
        }
        if let outError {
            al_string_free(outError)
        }
        return rc == 0
    }

    private static func invalidateCache(pairingPath: String, cardID: String) {
        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("erosion_wallet_inv_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        for leaf in ["FrontFace", "Preview", "PlaceHolder"] {
            try? Data("corrupted".utf8).write(to: stage.appendingPathComponent(leaf))
        }
        for ext in [".cache", ".pkcache"] {
            _ = writeDirectory(
                pairingPath: pairingPath,
                source: stage.path,
                target: "/var/mobile/Library/Passes/Cards/\(cardID)\(ext)"
            )
        }
        try? FileManager.default.removeItem(at: stage)
    }

    private enum ArtworkCacheKind {
        case current
        case edited
    }

    private static func artworkCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Erosion/WalletCardArtwork", isDirectory: true)
    }

    private static func cacheFileKey(for cardID: String) -> String {
        Data(cardID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func artworkCacheURL(cardID: String, kind: ArtworkCacheKind) -> URL {
        let suffix = kind == .current ? "current.imgdata" : "edited.imgdata"
        return artworkCacheDirectory().appendingPathComponent("\(cacheFileKey(for: cardID)).\(suffix)")
    }

    private static func readArtworkCache(cardID: String, kind: ArtworkCacheKind) -> Data? {
        try? Data(contentsOf: artworkCacheURL(cardID: cardID, kind: kind))
    }

    private static func writeArtworkCache(_ data: Data, cardID: String, kind: ArtworkCacheKind) {
        let directory = artworkCacheDirectory()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: artworkCacheURL(cardID: cardID, kind: kind), options: .atomic)
        } catch {
            print("(wallet) failed to cache artwork: \(error.localizedDescription)")
        }
    }

    private static func removeArtworkCache(cardID: String, kind: ArtworkCacheKind) {
        try? FileManager.default.removeItem(at: artworkCacheURL(cardID: cardID, kind: kind))
    }

    private static func clampedPanPosition(_ position: CGSize) -> CGSize {
        CGSize(width: min(max(position.width, -1), 1), height: min(max(position.height, -1), 1))
    }

    private static func prepareAllCardSkins(
        from image: UIImage,
        overlayType: WalletCardOverlayType,
        panPosition: CGSize
    ) -> [String: Data]? {
        let normalized = normalizeAndDownsample(image, maxDimension: 2560)
        var skins: [String: Data] = [:]
        let target3x = CGSize(width: 1536, height: 969)
        let target2x = CGSize(width: 1024, height: 646)
        if let data3x = renderCardOverlay(normalized, targetSize: target3x, overlayType: overlayType, panPosition: panPosition)?.pngData() {
            skins["cardBackgroundCombined@3x.png"] = data3x
            skins["diffuse@3x.png"] = data3x
            skins["background@3x.png"] = data3x
            skins["strip@3x.png"] = data3x
        }
        if let data2x = renderCardOverlay(normalized, targetSize: target2x, overlayType: overlayType, panPosition: panPosition)?.pngData() {
            skins["cardBackgroundCombined@2x.png"] = data2x
            skins["diffuse@2x.png"] = data2x
            skins["background@2x.png"] = data2x
            skins["strip@2x.png"] = data2x
        }
        let rect = CGRect(origin: .zero, size: target3x)
        let pdf = UIGraphicsPDFRenderer(bounds: rect).pdfData { context in
            context.beginPage()
            if let finalImage = renderCardOverlay(normalized, targetSize: target3x, overlayType: overlayType, panPosition: panPosition) {
                finalImage.draw(in: rect)
            }
        }
        skins["cardBackgroundCombined.pdf"] = pdf
        skins["background.pdf"] = pdf
        skins["strip.pdf"] = pdf
        return skins.isEmpty ? nil : skins
    }

    private static func renderCardOverlay(
        _ image: UIImage,
        targetSize: CGSize,
        overlayType: WalletCardOverlayType,
        panPosition: CGSize
    ) -> UIImage? {
        guard targetSize.width > 0, targetSize.height > 0, image.size.width > 0, image.size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { context in
            let bounds = CGRect(origin: .zero, size: targetSize)
            if overlayType == .stretch {
                image.draw(in: bounds)
                return
            }

            // Default fills the card frame, preserving the source aspect ratio.
            // The normalized pan position moves the source inside the crop.
            let sourceAspect = image.size.width / image.size.height
            let targetAspect = targetSize.width / targetSize.height
            let drawSize: CGSize
            if sourceAspect > targetAspect {
                drawSize = CGSize(width: targetSize.height * sourceAspect, height: targetSize.height)
            } else {
                drawSize = CGSize(width: targetSize.width, height: targetSize.width / sourceAspect)
            }
            let overflowX = max(0, drawSize.width - targetSize.width)
            let overflowY = max(0, drawSize.height - targetSize.height)
            let x = (targetSize.width - drawSize.width) / 2 + CGFloat(panPosition.width) * overflowX / 2
            let y = (targetSize.height - drawSize.height) / 2 + CGFloat(panPosition.height) * overflowY / 2
            context.cgContext.saveGState()
            context.cgContext.clip(to: bounds)
            image.draw(in: CGRect(origin: CGPoint(x: x, y: y), size: drawSize))
            context.cgContext.restoreGState()
        }
    }

    private static func normalizeAndDownsample(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = min(1.0, maxDimension / max(size.width, size.height))
        let target = CGSize(width: max(1, floor(size.width * scale)), height: max(1, floor(size.height * scale)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private static func cleanCardID(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "'\",()<>;[]{}"))
        if value.contains("/") { value = (value as NSString).lastPathComponent }
        for ext in [".pkpass", ".cache", ".pkcache"] where value.hasSuffix(ext) {
            value = String(value.dropLast(ext.count))
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "'\",()<>;[]{}. "))
        guard value.count >= 20 && value.count <= 64 && !value.contains("/") else { return nil }
        if value.count == 36 && value.filter({ $0 == "-" }).count == 4 { return nil }
        return value
    }
}

private extension PairingController {
    static func pairingFilePathExists() -> Bool {
        let path = PairingController.pairingFilePath()
        return FileManager.default.fileExists(atPath: path)
    }
}
