import Foundation
import UIKit
import AirliftFFI
import ZIPFoundation

struct ErosionPasscodeTheme: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let keys: [String: UIImage]
    let rawData: [String: Data]
    let fileCount: Int
}

enum ErosionPasscodeThemeReader {
    /// Reads only archive filenames to populate Library cards. Avoids decoding all theme
    /// images into UIImages just to display a key count while the Library is opening.
    static func keyCount(in url: URL) -> Int? {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("erosion_passthm_meta_\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tempDir) }
            let rc = url.path.withCString { archivePath in
                tempDir.path.withCString { destinationPath in
                    al_passthm_extract(archivePath, destinationPath)
                }
            }
            guard rc == 0 else { return nil }
            let files = (fm.subpaths(atPath: tempDir.path) ?? []).filter { path in
                let lower = path.lowercased()
                return !path.hasPrefix(".") && !lower.contains("__macosx")
                    && (lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg"))
            }
            let digits = Set(files.compactMap { path in
                extractDigit((path as NSString).lastPathComponent)
            })
            return digits.isEmpty ? nil : digits.count
        } catch {
            return nil
        }
    }

    static func inspect(url: URL) -> ErosionPasscodeTheme? {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("erosion_passthm_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rc = url.path.withCString { arcC in
            tempDir.path.withCString { dstC in
                al_passthm_extract(arcC, dstC)
            }
        }
        guard rc == 0 else { return nil }

        let files = (FileManager.default.subpaths(atPath: tempDir.path) ?? []).filter { file in
            let lower = file.lowercased()
            return !file.hasPrefix(".") && !lower.contains("__macosx")
                && (lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg"))
        }
        let preferredLanguage = Locale.preferredLanguages.first
            .map { String($0.prefix(2)).lowercased() } ?? "en"
        let preferWhite = UIScreen.main.traitCollection.userInterfaceStyle == .dark
        var keys: [String: UIImage] = [:]
        var raw: [String: Data] = [:]
        let count = files.count

        func score(_ relativePath: String) -> Int {
            let filename = (relativePath as NSString).lastPathComponent.lowercased()
            let prefix = filename.split(separator: "-", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let languageRank = prefix == preferredLanguage ? 0 : (prefix == "other" ? 1 : (prefix == "en" ? 2 : 3))
            let hasWhite = filename.contains("white")
            let hasMask = filename.contains("mask")
            let appearanceRank = preferWhite
                ? (hasWhite ? 0 : (hasMask ? 1 : 2))
                : (hasMask ? 0 : (hasWhite ? 1 : 2))
            let boldRank = filename.contains("-bold.") ? 1 : 0
            let labeledRank = filename.range(of: #"^[a-zA-Z]+-[0-9]+-[^-].*"#, options: .regularExpression) != nil ? 1 : 0
            return languageRank * 100 + appearanceRank * 10 + boldRank * 2 + labeledRank
        }

        // Archives often contain multiple language, appearance, and bold variants
        // for each digit. Select the variant that matches the current device instead
        // of whichever file ZIPFoundation happens to enumerate first.
        for digit in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"] {
            let candidates = files.filter { file in
                extractDigit((file as NSString).lastPathComponent) == digit
            }.sorted { score($0) < score($1) }
            for file in candidates {
                let path = tempDir.appendingPathComponent(file)
                guard let data = try? Data(contentsOf: path), let image = UIImage(data: data) else { continue }
                raw[digit] = data
                keys[digit] = image
                break
            }
        }

        guard !keys.isEmpty else { return nil }
        return ErosionPasscodeTheme(
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            keys: keys,
            rawData: raw,
            fileCount: count
        )
    }

    private static func extractDigit(_ filename: String) -> String? {
        let stem = (filename as NSString).deletingPathExtension
            .replacingOccurrences(of: "--white", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "-white", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "@3x", with: "")
            .replacingOccurrences(of: "@2x", with: "")

        if let regex = try? NSRegularExpression(
            pattern: #"(?:^[a-zA-Z]+-)?([0-9])"#,
            options: .caseInsensitive
        ) {
            let ns = stem as NSString
            if let match = regex.firstMatch(in: stem, range: NSRange(location: 0, length: ns.length)),
               match.numberOfRanges > 1 {
                let value = ns.substring(with: match.range(at: 1))
                if value.count == 1 { return value }
            }
        }

        for ch in stem where "0123456789".contains(ch) {
            return String(ch)
        }
        return nil
    }
}


/// Persists selected and imported passcode artwork across app launches.
enum PasscodeThemeStorage {
    private static let themeNameKey = "erosion.passcodeTheme.name"
    private static let fileCountKey = "erosion.passcodeTheme.fileCount"

    static var directoryURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("ErosionPasscodeTheme", isDirectory: true)
    }

    static func save(theme: ErosionPasscodeTheme) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let existing = (try? fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)) ?? []
            for url in existing where url.pathExtension == "keydata" {
                try? fm.removeItem(at: url)
            }

            for digit in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"] {
                guard let data = theme.rawData[digit] ?? theme.keys[digit]?.pngData() else { continue }
                try data.write(to: directoryURL.appendingPathComponent("\(digit).keydata"), options: .atomic)
            }
            UserDefaults.standard.set(theme.name, forKey: themeNameKey)
            UserDefaults.standard.set(theme.fileCount, forKey: fileCountKey)
        } catch {
            print("(passcode) failed to persist theme: \(error.localizedDescription)")
        }
    }

    static func load() -> ErosionPasscodeTheme? {
        var keys: [String: UIImage] = [:]
        var rawData: [String: Data] = [:]
        for digit in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"] {
            let url = directoryURL.appendingPathComponent("\(digit).keydata")
            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { continue }
            keys[digit] = image
            rawData[digit] = data
        }
        guard !keys.isEmpty else { return nil }
        let name = UserDefaults.standard.string(forKey: themeNameKey) ?? "Custom Passcode"
        let fileCount = UserDefaults.standard.integer(forKey: fileCountKey)
        return ErosionPasscodeTheme(
            url: directoryURL,
            name: name,
            keys: keys,
            rawData: rawData,
            fileCount: max(fileCount, keys.count)
        )
    }

    static func clear() {
        let fm = FileManager.default
        let existing = (try? fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)) ?? []
        for url in existing where url.pathExtension == "keydata" {
            try? fm.removeItem(at: url)
        }
        UserDefaults.standard.removeObject(forKey: themeNameKey)
        UserDefaults.standard.removeObject(forKey: fileCountKey)
    }
}

extension ErosionPasscodeThemeReader {
    /// Parse the ZIP produced by Airlift's existing generic folder-read primitive.
    static func inspectTelephonyFolderArchive(at archiveURL: URL) -> ErosionPasscodeTheme? {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(
            "erosion_current_keys_\(UUID().uuidString)", isDirectory: true
        )
        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tempDir) }
            try fm.unzipItem(at: archiveURL, to: tempDir)

            let paths = (fm.subpaths(atPath: tempDir.path) ?? []).filter { path in
                let lower = path.lowercased()
                return lower.hasSuffix(".png") || lower.hasSuffix(".jpg")
                    || lower.hasSuffix(".jpeg") || lower.hasSuffix(".heic")
            }
            guard !paths.isEmpty else { return nil }

            let preferredLanguage = Locale.preferredLanguages.first
                .map { String($0.prefix(2)).lowercased() } ?? "en"
            let preferWhite = UIScreen.main.traitCollection.userInterfaceStyle == .dark

            func digit(for path: String) -> String? {
                let filename = (path as NSString).lastPathComponent
                let stem = (filename as NSString).deletingPathExtension
                guard let regex = try? NSRegularExpression(pattern: #"^(?:[a-zA-Z]+-)?([0-9])(?:-|$)"#) else {
                    return nil
                }
                let ns = stem as NSString
                guard let match = regex.firstMatch(in: stem, range: NSRange(location: 0, length: ns.length)),
                      match.numberOfRanges > 1 else { return nil }
                return ns.substring(with: match.range(at: 1))
            }

            func score(_ path: String) -> Int {
                let filename = (path as NSString).lastPathComponent.lowercased()
                let prefix = filename.split(separator: "-", omittingEmptySubsequences: false).first.map(String.init) ?? ""
                let languageRank = prefix == preferredLanguage ? 0 : (prefix == "other" ? 1 : (prefix == "en" ? 2 : 3))
                let hasWhite = filename.contains("white")
                let hasMask = filename.contains("mask")
                let appearanceRank = preferWhite
                    ? (hasWhite ? 0 : (hasMask ? 1 : 2))
                    : (hasMask ? 0 : (hasWhite ? 1 : 2))
                let boldRank = filename.contains("-bold.") ? 1 : 0
                let labeledRank = filename.range(of: #"^[a-zA-Z]+-[0-9]+-[^-].*"#, options: .regularExpression) != nil ? 1 : 0
                return languageRank * 100 + appearanceRank * 10 + boldRank * 2 + labeledRank
            }

            var keys: [String: UIImage] = [:]
            var dataByDigit: [String: Data] = [:]
            for digitValue in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"] {
                let candidates = paths.filter { digit(for: $0) == digitValue }.sorted { score($0) < score($1) }
                for relativePath in candidates {
                    let url = tempDir.appendingPathComponent(relativePath)
                    guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { continue }
                    keys[digitValue] = image
                    dataByDigit[digitValue] = data
                    break
                }
            }

            guard !keys.isEmpty else { return nil }
            return ErosionPasscodeTheme(
                url: archiveURL,
                name: "Current Keys",
                keys: keys,
                rawData: dataByDigit,
                fileCount: paths.count
            )
        } catch {
            print("(passcode) failed to inspect current keys archive: \(error.localizedDescription)")
            return nil
        }
    }
}


/// Applies the same size and circular-mask processing used by Dialer Themer.
/// The original theme data is kept separately so changing options never compounds resizes.
func processPasscodeKeyData(
    _ data: Data,
    size: KPSize,
    customWidth: Int,
    customHeight: Int,
    mask: Bool
) -> Data {
    let manager = KeypadManager.shared
    switch size {
    case .defSize:
        guard mask else { return data }
        return manager.resizeAndRet(withData: data, shallCircle: true, isDefault: true)
    case .small, .medium, .large:
        return manager.resizeAndRet(withData: data, newSize: size.float, shallCircle: mask)
    case .custom:
        return manager.resizeAndRet(
            withData: data,
            customSize: CGSize(width: customWidth, height: customHeight),
            shallCircle: mask
        )
    }
}
