//
//  KeypadManager.swift
//  Erosion
//
//  Created by lunginspector on 8/27/26.
//

import Combine
import Foundation
import UIKit
import ZIPFoundation

// i hate you, apple incorporated.
// with love, lunginspector. august 28th, 2026.
enum KeypadID: String, CaseIterable {
    case one, two, three, four, five, six, seven, eight, nine, star, zero, pound
    
    private var assetKey: String {
        switch self {
        case .one: return "-1-"
        case .two: return "-2-A B C"
        case .three: return "-3-D E F"
        case .four: return "-4-G H I"
        case .five: return "-5-J K L"
        case .six: return "-6-M N O"
        case .seven: return "-7-P Q R S"
        case .eight: return "-8-T U V"
        case .nine: return "-9-W X Y Z"
        case .star: return "-*-"
        case .zero: return "-0-+"
        case .pound: return "-#-"
        }
    }

    /// Names for the language bucket used by this device's current language.
    var fileNames: [String] {
        getFileNames(forKey: assetKey, prefix: kp.getFileRegCode())
    }

    /// Alternate known prefixes are retained for importing pre-existing artwork.
    /// New writes use the shared Dialer & Passcode prefix selected in Settings.
    var allFileNames: [String] {
        let prefixes = [kp.getFileRegCode(), "other", "en"]
        var seen = Set<String>()
        return prefixes.filter { seen.insert($0).inserted }
            .flatMap { getFileNames(forKey: assetKey, prefix: $0) }
    }

    private func getFileNames(forKey key: String, prefix: String) -> [String] {
        let files = ["--mask.png", "--white.png", "-hi-mask.png", "-hi-white.png", "--white-bold.png", "--mask-bold.png"]
        return files.map { prefix + key + $0 }
    }
    
    var dialerNumber: String {
        switch self {
        case .one: return "1"
        case .two: return "2"
        case .three: return "3"
        case .four: return "4"
        case .five: return "5"
        case .six: return "6"
        case .seven: return "7"
        case .eight: return "8"
        case .nine: return "9"
        case .star: return "*"
        case .zero: return "0"
        case .pound: return "#"
        }
    }

    var dialerLetters: String {
        switch self {
        case .one: return ""
        case .two: return "ABC"
        case .three: return "DEF"
        case .four: return "GHI"
        case .five: return "JKL"
        case .six: return "MNO"
        case .seven: return "PQRS"
        case .eight: return "TUV"
        case .nine: return "WXYZ"
        case .star, .zero, .pound: return ""
        }
    }

    func getAccentedFileName() -> String {
        let appearance = UIScreen.main.traitCollection.userInterfaceStyle
        switch appearance {
        case .light: return self.fileNames[0]
        case .dark: return self.fileNames[1]
        default: return self.fileNames[0]
        }
    }
}

enum KPSize: Int, CaseIterable {
    case defSize, small, medium, large, custom
    
    var float: CGFloat {
        switch self {
        case .small: return CGFloat(150)
        case .medium: return CGFloat(205)
        case .large: return CGFloat(225)
        default: return CGFloat(0)
        }
    }
    
    var label: String {
        switch self {
        case .defSize: return "Default"
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .custom: return "Custom"
        }
    }
}

enum KPSizeLimits {
    static let min = CGFloat(50)
    static let max = CGFloat(2500)
}

struct KeypadItem: Identifiable, Equatable {
    let id = UUID()
    var kpID: KeypadID
    var imgData = Data()
    var ogImgData = Data()
}

let emptyKeypadArray = [
    KeypadItem(kpID: KeypadID.one), KeypadItem(kpID: KeypadID.two), KeypadItem(kpID: KeypadID.three), KeypadItem(kpID: KeypadID.four), KeypadItem(kpID: KeypadID.five), KeypadItem(kpID: KeypadID.six), KeypadItem(kpID: KeypadID.seven), KeypadItem(kpID: KeypadID.eight), KeypadItem(kpID: KeypadID.nine), KeypadItem(kpID: KeypadID.star), KeypadItem(kpID: KeypadID.zero), KeypadItem(kpID: KeypadID.pound)
]

/// Persists Dialer Themer artwork just like PasscodeThemeStorage: image bytes are
/// stored as individual files in Application Support, never in UserDefaults.
private enum DialerKeypadStorage {
    static var directoryURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("ErosionDialerKeypad", isDirectory: true)
    }

    private static func fileURL(for id: KeypadID, original: Bool) -> URL {
        directoryURL.appendingPathComponent(
            "\(id.rawValue).\(original ? "original" : "current").keydata"
        )
    }

    static func load() -> [KeypadItem]? {
        let items = KeypadID.allCases.map { id in
            let current = (try? Data(contentsOf: fileURL(for: id, original: false))) ?? Data()
            let original = (try? Data(contentsOf: fileURL(for: id, original: true))) ?? Data()
            return KeypadItem(kpID: id, imgData: current, ogImgData: original)
        }
        return items.contains { !$0.imgData.isEmpty || !$0.ogImgData.isEmpty } ? items : nil
    }

    static func save(_ items: [KeypadItem]) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            for id in KeypadID.allCases {
                guard let item = items.first(where: { $0.kpID == id }) else { continue }
                try write(item.imgData, to: fileURL(for: id, original: false))
                try write(item.ogImgData, to: fileURL(for: id, original: true))
            }
        } catch {
            print("(kp) failed to persist dialer keys: \(error.localizedDescription)")
        }
    }

    private static func write(_ data: Data, to url: URL) throws {
        if data.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }
}


enum KPMsg {
    static let resetWarn = "You'll lose both what you're currently editing and what you've already set inside of the Phone app."
    static let applyComp = "For changes to take effect, open the Phone app and change the appearance until your custom keys show up. You can also restart your device. Do NOT force kill the Phone app!"
}

private enum KeypadThemeImportError: LocalizedError {
    case noImageFiles
    case noMatchingKeyImages(appearance: String)

    var errorDescription: String? {
        switch self {
        case .noImageFiles:
            return "The archive contains no supported keypad image files."
        case .noMatchingKeyImages(let appearance):
            return "No compatible \(appearance) keypad images were found. Check that the archive contains TelephonyUI keypad assets."
        }
    }
}

let kp = KeypadManager()
final class KeypadManager: ObservableObject {
    static let shared = KeypadManager()
    
    @Published var mpKeypad = [KeypadItem]()
    @Published private(set) var lastThemeImportError: String?
    
    private var mpContainerPath = {
        return UserDefaults.standard.value(forKey: "mpContainerPath") as? String ?? ""
    }
    
    init() {
        mpKeypad = DialerKeypadStorage.load() ?? emptyKeypadArray
    }
    
    // fun...
    func getFileRegCode() -> String {
        DialerPasscodePrefix.currentCode
    }
    
    func updateKeypadItem(forID id: KeypadID, withData data: Data, ogData: Data? = nil) {
        if let index = mpKeypad.firstIndex(where: { $0.kpID == id }) {
            mpKeypad[index].imgData = data
            if let data = ogData {
                mpKeypad[index].ogImgData = data
            }
            DialerKeypadStorage.save(mpKeypad)
        }
    }
    
    func applyKeypadItems() -> Bool {
        // iOS 27 Airlift mode: use the same direct TelephonyUI-10 write
        // mechanism as AirCard instead of relying on the MobilePhone
        // application container path.
        if usesAirliftForSelectedExploit() {
            let bridge = AirliftBridge.shared
            guard bridge.hasPairing() else {
                bridge.appendFeatureLog("dialer", "Airlift pairing is unavailable")
                return false
            }

            bridge.beginFeatureOperationLogScope()
            defer { bridge.endFeatureOperationLogScope() }
            let stage = FileManager.default.temporaryDirectory
                .appendingPathComponent("ErosionTelephonyUI-10-\(UUID().uuidString)")

            do {
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)

                for item in mpKeypad {
                    // Do not create zero-byte TelephonyUI assets for keys that
                    // the user has not customized. Leaving those files untouched
                    // lets the system keep its original digit/key artwork.
                    guard !item.imgData.isEmpty else { continue }
                    for fileName in item.kpID.fileNames {
                        try item.imgData.write(to: stage.appendingPathComponent(fileName))
                    }
                }

                let pairingPath = AirliftBridge.shared.pairingFilePath()
                let source = stage.path

                // The Phone dialer cache lives inside the MobilePhone app
                // container on iOS 27. Resolve that container through Airlift
                // instead of relying on a locally visible UUID/hash.
                var containerPtr: UnsafeMutablePointer<CChar>?
                var findError: UnsafeMutablePointer<CChar>?
                let findRC = pairingPath.withCString { p in
                    "com.apple.mobilephone".withCString { bundle in
                        al_find_app_container(
                            p, bundle, nil, nil,
                            &containerPtr, &findError
                        )
                    }
                }

                guard findRC == 0, let containerPtr else {
                    if let findError {
                        bridge.appendFeatureLog("dialer", "Failed to find MobilePhone container: \(String(cString: findError))")
                        al_string_free(findError)
                    } else {
                        bridge.appendFeatureLog("dialer", "Failed to find MobilePhone container (rc=\(findRC))")
                    }
                    try? FileManager.default.removeItem(at: stage)
                    return false
                }

                let container = String(cString: containerPtr)
                al_string_free(containerPtr)
                UserDefaults.standard.set(container, forKey: "mpContainerPath")
                UserDefaults.standard.set("airlift", forKey: "mpContainerPathSource")
                let target = URL(fileURLWithPath: container)
                    .appendingPathComponent("Library/Caches/TelephonyUI-10")
                    .path
                let assetCount = mpKeypad.reduce(into: 0) { count, item in
                    if !item.imgData.isEmpty { count += item.kpID.fileNames.count }
                }
                bridge.appendFeatureLog("dialer", "Writing \(assetCount) keypad assets to \(target)")

                var error: UnsafeMutablePointer<CChar>?
                let rc = pairingPath.withCString { p in
                    source.withCString { s in
                        target.withCString { t in
                            al_exploit_write_dir(p, s, t, nil, nil, &error)
                        }
                    }
                }

                if let error {
                    bridge.appendFeatureLog("dialer", "TelephonyUI-10 write failed: \(String(cString: error))")
                    al_string_free(error)
                }

                try? FileManager.default.removeItem(at: stage)
                if rc == 0 {
                    bridge.appendFeatureLog("dialer", "Write succeeded for \(assetCount) assets. TelephonyUI-10 is a cache and iOS may regenerate it later.")
                } else {
                    bridge.appendFeatureLog("dialer", "Write failed (rc=\(rc))")
                }
                return rc == 0
            } catch {
                bridge.appendFeatureLog("dialer", "Failed to stage keypad theme: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: stage)
                return false
            }
        }

        guard prepareWorseQueryContainerAccess() else {
            print("(kp) failed to resolve Worse Query access to the MobilePhone container")
            return false
        }

        var failed = 0
        for item in mpKeypad {
            let files = item.kpID.fileNames
            for fileName in files {
                let finalURL = URL(fileURLWithPath: mpContainerPath()).appendingPathComponent("Library/Caches/TelephonyUI-10").appendingPathComponent(fileName)
                do {
                    try item.imgData.write(to: finalURL)
                } catch {
                    print("(kp) failed to write image data: \(error.localizedDescription)")
                    failed += 1
                }
            }
        }
        return failed == 0
    }
    
    func resetKeypadItems() -> Bool {
        guard prepareWorseQueryContainerAccess() else {
            print("(kp) failed to resolve Worse Query access before resetting keypad items")
            return false
        }
        do {
            let filesURL = URL(fileURLWithPath: mpContainerPath()).appendingPathComponent("Library/Caches/TelephonyUI-10")
            let files = try fm.contentsOfDirectory(at: filesURL, includingPropertiesForKeys: [])
            for fileURL in files {
                try fm.removeItem(at: fileURL)
            }
            clearKeypads()
            return true
        } catch {
            print("(kp) failed to reset keypad items: \(error.localizedDescription)")
        }
        return false
    }
    
    func clearKeypads() {
        for keypad in mpKeypad {
            if let index = mpKeypad.firstIndex(where: { $0.id == keypad.id }) {
                mpKeypad[index].ogImgData = Data()
                mpKeypad[index].imgData = Data()
            }
        }
        DialerKeypadStorage.save(mpKeypad)
    }
    
    func resizeAndRet(withData data: Data, newSize: CGFloat = CGFloat(0), customSize: CGSize? = nil, shallCircle: Bool = false, isDefault: Bool = false) -> Data {
        if let image = UIImage(data: data) {
            var width = isDefault ? image.size.width : customSize?.width ?? newSize
            var height = isDefault ? image.size.height: customSize?.height ?? newSize
            width = min(max(width, KPSizeLimits.min), KPSizeLimits.max)
            height = min(max(height, KPSizeLimits.min), KPSizeLimits.max)
            let resized = image.resized(to: CGSize(width: width, height: height), shouldCircle: shallCircle)
            if let newData = resized.pngData() {
                return newData
            }
        }
        return data
    }
    
    /// Mirrors the original Erosion flow: find the MobilePhone container with
    /// pathleak, then request Worse Query access to the container before local IO.
    @discardableResult
    func prepareWorseQueryContainerAccess() -> Bool {
        var containerPath = mpContainerPath()
        if containerPath.isEmpty {
            // Combined obtains the path through the existing InstallationProxy
            // flow in KeypadView. Do not replace that with a WQ path scan here.
            guard selectedExploitSelection() == .worseQuery else { return false }
            containerPath = fsHandlers.getContainerPathWithWorseQuery(forMatch: "com.apple.mobilephone")
            guard !containerPath.isEmpty else { return false }
            UserDefaults.standard.set(containerPath, forKey: "mpContainerPath")
            UserDefaults.standard.set("worse_query", forKey: "mpContainerPathSource")
        }

        // Request the Worse Query extension explicitly even when the path is
        // readable already: Dialer Themer also needs write access for Apply.
        let access = wq.grantAccess(path: containerPath)
        return access.0
    }

    func getCurrentKeypads(size: KPSize = KPSize.defSize, custW: Int = 0, custH: Int = 0, saveOgData: Bool = false) {
        if usesAirliftForSelectedExploit() {
            getCurrentKeypadsViaAirlift(size: size, custW: custW, custH: custH, saveOgData: saveOgData)
            return
        }

        guard prepareWorseQueryContainerAccess() else {
            print("(kp) failed to resolve Worse Query access before loading current keypad assets")
            return
        }

        do {
            let filesURL = URL(fileURLWithPath: mpContainerPath()).appendingPathComponent("Library/Caches/TelephonyUI-10")
            for kpId in KeypadID.allCases {
                let fileName = kpId.getAccentedFileName()
                let url = filesURL.appendingPathComponent(fileName)
                let data = try Data(contentsOf: url)
                let imgData = {
                    switch size {
                    case .defSize: return resizeAndRet(withData: data, isDefault: true)
                    case .custom: return resizeAndRet(withData: data, customSize: CGSize(width: custW, height: custH))
                    default: return resizeAndRet(withData: data, newSize: size.float)
                    }
                }()
                if saveOgData {
                    updateKeypadItem(forID: kpId, withData: imgData, ogData: imgData)
                } else {
                    updateKeypadItem(forID: kpId, withData: imgData)
                }
            }
        } catch {
            // keypads could've been reset so nothing to log here, logs are just gonna spit out nonsense
        }
    }
    
    /// On iOS 27 DB5+ the Phone data container is resolved through the existing
    /// InstallationProxy integration, then read through Airlift's existing
    /// safe folder-snapshot path. The local file-reading path below is unchanged.
    private func getCurrentKeypadsViaAirlift(
        size: KPSize,
        custW: Int,
        custH: Int,
        saveOgData: Bool
    ) {
        let bridge = AirliftBridge.shared
        guard bridge.airliftFeatureReady() else {
            bridge.appendFeatureLog("dialer", "Get Current Keys requires LocalDevVPN and a pairing file")
            return
        }

        Task {
            bridge.beginFeatureOperationLogScope()
            let containerPath = await bridge.resolveInstalledAppContainerPath(bundleID: "com.apple.mobilephone")
            bridge.endFeatureOperationLogScope()
            guard let containerPath else {
                bridge.appendFeatureLog("dialer", "Get Current Keys failed: MobilePhone container was not found")
                return
            }
            UserDefaults.standard.set(containerPath, forKey: "mpContainerPath")
            UserDefaults.standard.set("installationProxy", forKey: "mpContainerPathSource")

            let target = URL(fileURLWithPath: containerPath, isDirectory: true)
                .appendingPathComponent("Library/Caches/TelephonyUI-10", isDirectory: true)
                .path + "/"
            bridge.readRemoteFolderArchive(path: target, logLabel: "Dialer current keys") { [weak self] archiveData in
                guard let self, let archiveData else {
                    bridge.appendFeatureLog("dialer", "Get Current Keys failed: Airlift could not read the TelephonyUI-10 snapshot")
                    return
                }
                let loaded = self.importCurrentKeypadsArchive(
                    archiveData,
                    size: size,
                    custW: custW,
                    custH: custH,
                    saveOgData: saveOgData
                )
                bridge.appendFeatureLog("dialer", loaded > 0
                    ? "Get Current Keys loaded \(loaded)/12 keypad assets"
                    : "Get Current Keys failed: no recognized keypad images were found in the snapshot")
            }
        }
    }

    /// Imports the existing TelephonyUI-10 ZIP snapshot without changing the
    /// remote read/restore mechanism. Match the same appearance-specific names
    /// that the regular local loader uses.
    private func importCurrentKeypadsArchive(
        _ archiveData: Data,
        size: KPSize,
        custW: Int,
        custH: Int,
        saveOgData: Bool
    ) -> Int {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ErosionDialerCurrentKeys-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = root.appendingPathComponent("TelephonyUI-10.zip")
        let extractedURL = root.appendingPathComponent("Extracted", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            try FileManager.default.createDirectory(at: extractedURL, withIntermediateDirectories: true)
            try archiveData.write(to: archiveURL, options: .atomic)
            try fm.unzipItem(at: archiveURL, to: extractedURL)

            let allFiles = (FileManager.default.enumerator(
                at: extractedURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )?.allObjects.compactMap { $0 as? URL } ?? []).filter { url in
                (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            let filesByName = Dictionary(grouping: allFiles, by: { $0.lastPathComponent })

            var loaded = 0
            for kpID in KeypadID.allCases {
                // Prefer the exact appearance file used by the existing loader,
                // then try the remaining known TelephonyUI-10 variants.
                let preferred = kpID.getAccentedFileName()
                let candidateNames = [preferred] + kpID.allFileNames.filter { $0 != preferred }
                guard let fileURL = candidateNames.lazy.compactMap({ filesByName[$0]?.first }).first,
                      let data = try? Data(contentsOf: fileURL), !data.isEmpty else { continue }

                let processed: Data = {
                    switch size {
                    case .defSize:
                        return resizeAndRet(withData: data, isDefault: true)
                    case .custom:
                        guard let image = UIImage(data: data) else { return data }
                        return resizeAndRet(withData: data, customSize: CGSize(width: custW > 0 ? custW : Int(image.size.width), height: custH > 0 ? custH : Int(image.size.height)))
                    default:
                        return resizeAndRet(withData: data, newSize: size.float)
                    }
                }()
                updateKeypadItem(forID: kpID, withData: processed, ogData: saveOgData ? processed : nil)
                loaded += 1
            }
            return loaded
        } catch {
            AirliftBridge.shared.appendFeatureLog("dialer", "Failed to import current TelephonyUI-10 keys: \(error.localizedDescription)")
            return 0
        }
    }

    func changeSizeOfKeypads(size: KPSize = KPSize.defSize, custW: Int = 0, custH: Int = 0) {
        for kpItem in mpKeypad {
            let data = kpItem.ogImgData
            let imgData = {
                switch size {
                case .defSize: return resizeAndRet(withData: data, isDefault: true)
                case .custom: return resizeAndRet(withData: data, customSize: CGSize(width: custW, height: custH))
                default: return resizeAndRet(withData: data, newSize: size.float)
                }
            }()
            updateKeypadItem(forID: kpItem.kpID, withData: imgData)
        }
    }
    
    func maskKeysIntoCircle(size: KPSize = KPSize.defSize, custW: Int = 0, custH: Int = 0) {
        for kpItem in mpKeypad {
            let data = kpItem.ogImgData
            let imgData = {
                switch size {
                case .defSize: return resizeAndRet(withData: data, shallCircle: true, isDefault: true)
                case .custom: return resizeAndRet(withData: data, customSize: CGSize(width: custW, height: custH), shallCircle: true)
                default: return resizeAndRet(withData: data, newSize: size.float, shallCircle: true)
                }
            }()
            updateKeypadItem(forID: kpItem.kpID, withData: imgData)
        }
    }
    
    /// Imports a keypad theme ZIP by locating known TelephonyUI keypad image names
    /// recursively. Archives may contain extra wrapper folders or metadata files.
    func importTheme(fromURL fileURL: URL) -> Bool {
        lastThemeImportError = nil
        let fm = FileManager.default
        let extractionRoot = fm.temporaryDirectory
            .appendingPathComponent("ErosionKeypadTheme-\(UUID().uuidString)", isDirectory: true)

        do {
            try fm.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: extractionRoot) }
            try fm.unzipItem(at: fileURL, to: extractionRoot)

            let extractedFiles = (fm.enumerator(
                at: extractionRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )?.allObjects.compactMap { $0 as? URL } ?? []).filter { url in
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    return false
                }
                return ["png", "jpg", "jpeg", "heic"].contains(url.pathExtension.lowercased())
            }
            guard !extractedFiles.isEmpty else {
                throw KeypadThemeImportError.noImageFiles
            }

            let preferredAppearance = UIScreen.main.traitCollection.userInterfaceStyle == .dark ? "white" : "mask"
            let alternateAppearance = preferredAppearance == "white" ? "mask" : "white"
            let preferredLanguage = getFileRegCode().lowercased()

            func filenameParts(_ url: URL) -> [String] {
                url.deletingPathExtension().lastPathComponent
                    .lowercased()
                    .split(separator: "-", omittingEmptySubsequences: true)
                    .map(String.init)
            }

            func parsedAppearance(_ url: URL) -> String? {
                let parts = filenameParts(url)
                for part in parts.dropFirst(min(2, parts.count)) {
                    if part.hasPrefix("mask") { return "mask" }
                    if part.hasPrefix("white") { return "white" }
                }
                return nil
            }

            func versionRank(_ url: URL) -> Int {
                let components = url.pathComponents.map { $0.lowercased() }
                if components.contains("telephonyui-10") { return 0 }
                if components.contains("telephonyui-9") { return 1 }
                if components.contains("telephonyui-8") { return 2 }
                return 3
            }

            func languageRank(_ url: URL) -> Int {
                let prefix = filenameParts(url).first ?? ""
                if prefix == preferredLanguage { return 0 }
                if prefix == "other" { return 1 }
                if prefix == "en" { return 2 }
                return 3
            }

            func variantRank(_ url: URL) -> Int {
                let name = url.lastPathComponent.lowercased()
                if name.contains("-bold.") { return 2 }
                if name.contains("-hi-") { return 1 }
                return 0
            }

            func sortedCandidates(for keypad: KeypadID, appearance: String) -> [URL] {
                extractedFiles.filter { url in
                    let parts = filenameParts(url)
                    guard parts.count >= 3,
                          parts[1] == keypad.dialerNumber,
                          parsedAppearance(url) == appearance else {
                        return false
                    }
                    return true
                }.sorted { lhs, rhs in
                    let leftRank = (languageRank(lhs), versionRank(lhs), variantRank(lhs), lhs.path.lowercased())
                    let rightRank = (languageRank(rhs), versionRank(rhs), variantRank(rhs), rhs.path.lowercased())
                    if leftRank.0 != rightRank.0 { return leftRank.0 < rightRank.0 }
                    if leftRank.1 != rightRank.1 { return leftRank.1 < rightRank.1 }
                    if leftRank.2 != rightRank.2 { return leftRank.2 < rightRank.2 }
                    return leftRank.3 < rightRank.3
                }
            }

            var replaceCount = 0
            for keypad in KeypadID.allCases {
                // Prefer the active appearance. If this particular theme contains
                // only the opposite variant for a key, still allow that key through
                // instead of rejecting an otherwise useful archive.
                let preferred = sortedCandidates(for: keypad, appearance: preferredAppearance)
                let candidates = preferred.isEmpty
                    ? sortedCandidates(for: keypad, appearance: alternateAppearance)
                    : preferred

                for candidate in candidates {
                    guard let data = try? Data(contentsOf: candidate),
                          !data.isEmpty,
                          UIImage(data: data) != nil else {
                        continue
                    }
                    updateKeypadItem(forID: keypad, withData: data, ogData: data)
                    replaceCount += 1
                    break
                }
            }

            guard replaceCount > 0 else {
                throw KeypadThemeImportError.noMatchingKeyImages(appearance: preferredAppearance)
            }

            print("(kp) successfully imported theme: \(fileURL.lastPathComponent), imported keys: \(replaceCount), appearance: \(preferredAppearance)")
            return true
        } catch {
            lastThemeImportError = error.localizedDescription
            print("(kp) failed to import theme: \(error.localizedDescription)")
            return false
        }
    }

}

extension UIImage {
    func resized(to size: CGSize, scale: CGFloat = 1.0, shouldCircle: Bool = false) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let ctx = context.cgContext

            if shouldCircle {
                ctx.addEllipse(in: CGRect(origin: .zero, size: size))
                ctx.clip()

                let fillScale = max(size.width / self.size.width, size.height / self.size.height)
                let drawSize = CGSize(width: self.size.width * fillScale, height: self.size.height * fillScale)
                let origin = CGPoint(
                    x: (size.width - drawSize.width) / 2,
                    y: (size.height - drawSize.height) / 2
                )
                draw(in: CGRect(origin: origin, size: drawSize))
            } else {
                draw(in: CGRect(origin: .zero, size: size))
            }
        }
    }
}
