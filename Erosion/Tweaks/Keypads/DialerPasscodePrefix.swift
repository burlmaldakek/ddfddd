import Foundation

enum DialerPasscodePrefix {
    static let defaultsKey = "erosion.dialerPasscodePrefix"
    static var defaultDisplayValue: String {
        "\(preferredLanguageCode)-"
    }

    /// Returns a filename prefix without the trailing hyphen. KeypadID and
    /// Passcode both add their existing separator and keep all key labels intact.
    static var currentCode: String {
        let stored = UserDefaults.standard.string(forKey: defaultsKey) ?? defaultDisplayValue
        let code = normalize(stored)
        return code.isEmpty ? preferredLanguageCode : code
    }

    private static var preferredLanguageCode: String {
        let language = Locale.preferredLanguages.first ?? "en"
        let code = String(language.split(separator: "-").first ?? Substring(language.prefix(2)))
        let normalized = normalize(code)
        return normalized.isEmpty ? "en" : normalized
    }

    private static let scanQueue = DispatchQueue(
        label: "com.erosion.dialer-passcode-prefix-scan",
        qos: .background
    )
    private static var scanScheduledForProcess = false

    /// The pathleak implementation searches inode numbers with fsgetpath. Run
    /// it at most once per process and at background QoS, rather than repeating
    /// the expensive scan every time the containing app becomes active.
    static func scanAtAppLaunch() {
        guard !scanScheduledForProcess else { return }
        scanScheduledForProcess = true
        scanQueue.asyncAfter(deadline: .now() + 12) {
            guard let detected = discoverInstalledPrefix() else { return }
            UserDefaults.standard.set("\(detected)-", forKey: defaultsKey)
        }
    }

    private static func discoverInstalledPrefix() -> String? {
        let container = fsHandlers.getContainerPathWithWorseQuery(
            forMatch: "com.apple.InCallService"
        )
        guard !container.isEmpty else { return nil }

        let target = URL(fileURLWithPath: container, isDirectory: true)
            .appendingPathComponent("Library/Caches/TelephonyUI-10", isDirectory: true)

        let access = wq.grantAccess(path: target.path)
        guard access.0, access.1 >= 0 else { return nil }
        defer { releaseSandboxAccess(access.1) }

        guard let names = try? FileManager.default.contentsOfDirectory(atPath: target.path) else {
            return nil
        }

        let available = Set(names.compactMap(prefixFromTelephonyFilename))
        guard !available.isEmpty else { return nil }

        let preferred = preferredLanguageCode
        if available.contains(preferred) { return preferred }
        if available.contains("other") { return "other" }
        if available.contains("en") { return "en" }
        return available.sorted().first
    }

    private static func prefixFromTelephonyFilename(_ filename: String) -> String? {
        guard let separator = filename.firstIndex(of: "-") else { return nil }
        let candidate = String(filename[..<separator]).lowercased()
        guard !candidate.isEmpty,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return nil
        }

        let remainder = filename[filename.index(after: separator)...]
        guard let key = remainder.first,
              key.isNumber || key == "*" || key == "#",
              remainder.contains("--mask") || remainder.contains("--white") else {
            return nil
        }
        return candidate
    }

    private static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let withoutTrailingSeparator = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(withoutTrailingSeparator.filter { $0.isLetter || $0.isNumber || $0 == "_" })
    }
}
