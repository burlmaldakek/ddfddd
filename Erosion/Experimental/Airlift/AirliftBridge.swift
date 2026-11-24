import Foundation
import UIKit
import Combine
import ZIPFoundation

private func airliftFileLogCallback(_ ctx: UnsafeMutableRawPointer?, _ msg: UnsafePointer<CChar>?) {
    guard let msg else { return }
    let bridge = AirliftBridge.shared
    guard !bridge.shouldSuppressContainerScannerLogs else { return }
    bridge.appendLog(String(cString: msg))
}

private func airliftPasscodeLogCallback(_ ctx: UnsafeMutableRawPointer?, _ msg: UnsafePointer<CChar>?) {
    guard let msg else { return }
    let line = String(cString: msg)
    let lower = line.lowercased()
    // The Rust writer emits one line per generated asset/route. Those details
    // are intentionally omitted from the user-facing passcode log; retain errors.
    guard lower.contains("error") || lower.contains("failed") || lower.contains("failure")
            || lower.contains("denied") || lower.contains("not restored") else { return }
    AirliftBridge.shared.appendPasscodeLog("[write] \(line)")
}

struct AirliftAppContainer: Identifiable, Equatable {
    let bundleID: String
    let container: String
    var id: String { bundleID }
}

/// App bundle metadata discovered by InstallationProxy and shown by App Decrypt
/// and the Bundle/Application browser.
struct AirliftAppBundlePath: Identifiable, Equatable, Sendable {
    let bundleID: String
    let displayName: String
    let path: String

    var id: String { path + "|" + bundleID }
    var preparedStorageKey: String { bundleID }
}

struct AirliftAppGroup: Identifiable, Equatable {
    /// Legacy UUID leaf from the physical path; never use as the row title.
    let groupID: String
    let groupIDs: [String]
    let container: String
    let sourceApps: [String]
    var id: String { container }
}

struct AirliftAppGroupIdentifier: Identifiable, Equatable {
    let groupID: String
    let sourceApps: [String]
    var id: String { groupID }
}

/// A physical Shared/AppGroup container discovered from filesystem path metadata.
/// The UUID is deliberately not equated with a group identifier: iOS assigns them independently.
struct AirliftAppGroupContainerPath: Identifiable, Equatable {
    let uuid: String
    let container: String
    var id: String { container }
}

final class AirliftBridge: ObservableObject, @unchecked Sendable {
    static let shared = AirliftBridge()
    enum State: Equatable { case idle, pairing, ready(pairingPath: String), running, done(ok: Bool, message: String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var pairPIN: String? = nil
    @Published private(set) var pairingStatus: String = ""
    @Published private(set) var exploitLog: [String] = []
    @Published private(set) var installedAppContainers: [AirliftAppContainer] = []
    @Published private(set) var installedAppBundlePaths: [AirliftAppBundlePath] = []
    @Published private(set) var installedAppGroups: [AirliftAppGroup] = []
    @Published private(set) var appGroupIdentifiersWithoutPaths: [AirliftAppGroupIdentifier] = []
    @Published private(set) var appGroupContainerPaths: [AirliftAppGroupContainerPath] = []
    @Published private(set) var appGroupAfcContainerPaths: [AirliftAppGroupContainerPath] = []
    @Published private(set) var appGroupPathScanLog: [String] = []
    @Published private(set) var appGroupPathScanRunning = false
    // AFC and BadQuery must have independent state. The old shared running flag
    // caused whichever scanner started second onAppear to be silently skipped.
    @Published private(set) var appGroupAfcScanRunning = false
    @Published private(set) var appGroupBadQueryScanRunning = false
    @Published private(set) var appGroupAfcScanLog: [String] = []
    @Published private(set) var appGroupBadQueryScanLog: [String] = []
    @Published private(set) var internalDaemonAfcPaths: [String] = []
    @Published private(set) var pluginKitPluginAfcPaths: [String] = []
    @Published private(set) var internalDaemonBadQueryPaths: [String] = []
    @Published private(set) var pluginKitPluginBadQueryPaths: [String] = []
    @Published private(set) var pluginKitPluginBadQueryInodeLimit: Int64? = nil
    @Published private(set) var internalDaemonAfcProbeRunning = false
    @Published private(set) var pluginKitPluginAfcProbeRunning = false
    @Published private(set) var internalDaemonBadQueryRunning = false
    @Published private(set) var pluginKitPluginBadQueryRunning = false
    @Published private(set) var internalDaemonAfcProbeLog: [String] = []
    @Published private(set) var pluginKitPluginAfcProbeLog: [String] = []
    @Published private(set) var internalDaemonBadQueryLog: [String] = []
    @Published private(set) var pluginKitPluginBadQueryLog: [String] = []
    // Retained as a compatibility/last-result field; UI now uses per-source logs.
    @Published private(set) var additionalContainerProbeLog: [String] = []
    @Published private(set) var additionalContainerProbeRunning = false
    @Published private(set) var appScanLog: [String] = []
    @Published private(set) var appScanRunning = false
    @Published private(set) var themingReady = UserDefaults.standard.bool(forKey: "airliftThemingReady")
    @Published var target: String = "/var/mobile/Library/SpringBoard"
    @Published var readTarget: String = ""
    @Published private(set) var readRunning = false
    @Published private(set) var readResult: String = ""
    @Published private(set) var lastReadSucceeded: Bool? = nil
    @Published private(set) var lastReadFileCount: Int? = nil
    @Published private(set) var lastReadTotalSize: Int64? = nil
    @Published private(set) var readExportPath: String? = nil
    @Published var showReadView = false
    @Published private(set) var readViewLocalPath: String? = nil
    @Published private(set) var readViewRemotePath: String? = nil
    @Published private(set) var readViewIsFolder = false
    @Published var readKind: ReadKind = .file

    enum ReadKind: String, CaseIterable, Identifiable {
        case file = "File"
        case folder = "Directory"
        var id: String { rawValue }
    }

    // Passcode theme state. This reuses the existing Airlift write primitive;
    // no exploit implementation is duplicated here.
    @Published private(set) var passcodeTheme: ErosionPasscodeTheme? = PasscodeThemeStorage.load()
    @Published private(set) var passcodeFlashRunning = false
    @Published private(set) var passcodeFlashLog: [String] = []
    @Published private(set) var passcodeLastApplySucceeded: Bool? = nil
    @Published var passcodeTelephonyVersion: String = "all"
    @Published var passcodeLanguage: String = "all"
    private var loggedLines: [String] = []
    private var appScanHasRunForPairing = false
    private var appScanHadAirliftReadyConnection = false

    /// Unique physical App Group paths gathered from InstallationProxy metadata,
    /// direct AFC directory listing, and the legacy BadQuery enumerator.
    var discoveredAppGroupPathCount: Int {
        Set(installedAppGroups.map(\.container)
            + appGroupAfcContainerPaths.map(\.container)
            + appGroupContainerPaths.map(\.container)).count
    }

    // Remote File Browser mutations are serialized so AirTraffic/Books state
    // cannot be changed by two concurrent write/delete transactions.
    private let fileMutationQueue = DispatchQueue(
        label: "com.erosion.airlift.file-mutations",
        qos: .userInitiated
    )

    // Airlift can emit hundreds/thousands of callback lines while a write is
    // running. Coalesce those callbacks before publishing to SwiftUI so the
    // main thread does not re-render once per line.
    private let logBufferLock = NSLock()
    private var pendingLogLines: [String] = []
    private var logFlushScheduled = false

    // InstallationProxy/AFC container-discovery calls share Rust's global tracing
    // subscriber with actual Airlift operations. Suppress their callback output while
    // a container scan is in flight so the main Airlift log stays operation-only.
    private let containerScannerLogLock = NSLock()
    private var containerScannerLogSuppressionDepth = 0

    // Keep feature-specific Rust output out of Airlift's general log panel when
    // the same result is being reported in Home's Erosion log instead.
    private let featureOperationLogLock = NSLock()
    private var featureOperationLogSuppressionDepth = 0

    // Passcode writes can produce a burst of FFI log lines. Batch publication so
    // SwiftUI does not redraw the complete editor once for every callback.
    private let passcodeLogBufferLock = NSLock()
    private var pendingPasscodeLogLines: [String] = []
    private var passcodeLogFlushScheduled = false

    private var pendingRemoteImageReads: [(paths: [String], logLabel: String, completion: (Data?) -> Void)] = []
    private var activeRemoteImageReadCompletion: ((Data?) -> Void)?
    private var activeRemoteFolderArchiveCompletion: ((Data?) -> Void)?
    private var activeRemoteImageReadCount = 0
    private var standardReadInProgress = false
    private let maxConcurrentRemoteImageReads = 2

    /// Export all regular files currently inside the app's temporary directory.
    /// The archive is staged in Caches so it is not recursively included in itself.
    nonisolated static func exportTemporaryDirectory() throws -> URL {
        let manager = FileManager.default
        let temporaryRoot = manager.temporaryDirectory.standardizedFileURL
        let cachesRoot = manager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? temporaryRoot
        let exportDirectory = cachesRoot.appendingPathComponent("ErosionAirliftExports", isDirectory: true)
        try manager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let archiveURL = exportDirectory
            .appendingPathComponent("Airlift-tmp-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))")
            .appendingPathExtension("zip")
        guard let archive = try Archive(url: archiveURL, accessMode: .create) else {
            throw NSError(domain: "AirliftTemporaryData", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create the temporary-data archive."])
        }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = manager.enumerator(
            at: temporaryRoot,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            throw NSError(domain: "AirliftTemporaryData", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not enumerate the app's temporary directory."])
        }

        let rootPath = temporaryRoot.path.hasSuffix("/") ? temporaryRoot.path : temporaryRoot.path + "/"
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: keys)
            if values.isDirectory == true || values.isSymbolicLink == true { continue }
            let path = fileURL.standardizedFileURL.path
            guard fileURL.standardizedFileURL != archiveURL.standardizedFileURL,
                  path.hasPrefix(rootPath) else { continue }
            let relativePath = String(path.dropFirst(rootPath.count))
            guard !relativePath.isEmpty else { continue }
            try archive.addEntry(
                with: relativePath,
                fileURL: fileURL,
                compressionMethod: .deflate
            )
        }
        return archiveURL
    }

    /// Remove every top-level item from tmp. Keep the active silent audio file
    /// only while KeepAlive is currently using it, matching the app-wide cache cleaner.
    nonisolated static func clearTemporaryDirectoryContents() -> (removedObjects: Int, failures: [String]) {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
        var removedObjects = 0
        var failures: [String] = []
        do {
            let topLevelItems = try manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
            for item in topLevelItems {
                if item.lastPathComponent == "keepalive.wav" && KeepAlive.shared.audioActive { continue }
                var objectCount = 1
                if let enumerator = manager.enumerator(
                    at: item,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [],
                    errorHandler: { _, _ in true }
                ) {
                    for _ in enumerator { objectCount += 1 }
                }
                do {
                    try manager.removeItem(at: item)
                    removedObjects += objectCount
                } catch {
                    failures.append("\(item.lastPathComponent): \(error.localizedDescription)")
                }
            }
        } catch {
            failures.append("tmp: \(error.localizedDescription)")
        }
        return (removedObjects, failures)
    }

    /// Clear only the in-memory references to read snapshots after tmp cleanup.
    func clearReadSnapshotState() {
        readExportPath = nil
        readViewLocalPath = nil
        readViewRemotePath = nil
        readViewIsFolder = false
        showReadView = false
        readResult = ""
        lastReadSucceeded = nil
        lastReadFileCount = nil
        lastReadTotalSize = nil
    }

    /// Clear the complete Airlift input/result state from the three-dot menu.
    func clearReadState() {
        if let old = readExportPath { removeReadSnapshot(atPath: old) }
        if let old = readViewLocalPath, old != readExportPath { removeReadSnapshot(atPath: old) }
        readTarget = ""
        clearReadSnapshotState()
    }

    private init() {
        al_log_init({ _, msg in
            guard let msg = msg else { return }
            let bridge = AirliftBridge.shared
            // Container-probe FFI calls use the same native logger as normal Airlift
            // operations. Keep their diagnostics in the category-specific log views.
            guard !bridge.shouldSuppressContainerScannerLogs,
                  !bridge.shouldSuppressFeatureOperationLogs else { return }
            let line = String(cString: msg)
            // appendLog is thread-safe and performs its own throttled main-thread
            // publish. Do not dispatch every callback onto the main queue.
            bridge.appendLog(line)
        }, nil)
    }

    nonisolated func appendLog(_ s: String) {
        guard !shouldSuppressFeatureOperationLogs,
              let conciseLine = Self.compactAirliftLogLine(s) else { return }
        logBufferLock.lock()
        pendingLogLines.append(conciseLine)
        if pendingLogLines.count > 700 {
            pendingLogLines.removeFirst(pendingLogLines.count - 650)
        }
        let shouldSchedule = !logFlushScheduled
        if shouldSchedule { logFlushScheduled = true }
        logBufferLock.unlock()

        guard shouldSchedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.flushLogBuffer()
        }
    }

    nonisolated var shouldSuppressFeatureOperationLogs: Bool {
        featureOperationLogLock.lock()
        defer { featureOperationLogLock.unlock() }
        return featureOperationLogSuppressionDepth > 0
    }

    /// Keeps Airlift's dedicated log readable like Home → Logs: one concise
    /// user-facing line per meaningful event, with low-level trace noise omitted.
    nonisolated private static func compactAirliftLogLine(_ raw: String) -> String? {
        var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        // Rust's default tracing formatter prefixes lines with timestamp, level,
        // and module. Drop DEBUG/TRACE records and remove that technical prefix.
        let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        if fields.count == 4 {
            let level = String(fields[1]).uppercased()
            if level == "DEBUG" || level == "TRACE" { return nil }
            if level == "INFO" || level == "WARN" || level == "ERROR" {
                line = String(fields[3])
                if level == "WARN" { line = "[!] " + line }
                if level == "ERROR" { line = "[!] " + line }
            }
        } else if line.hasPrefix("DEBUG ") || line.hasPrefix("TRACE ") {
            return nil
        }

        line = Self.cleanFeatureLogMessage(line)
        let lower = line.lowercased()

        // Shorter Logs hides per-directory enumeration progress only. The read
        // itself, final counts, errors, and operation summaries remain unchanged.
        if UserDefaults.standard.bool(forKey: "airlift.shorterLogs") {
            let enumerationProgress = [
                "airlift-folder: enumerate ",
                "[folder] enumerate "
            ]
            if enumerationProgress.contains(where: { lower.hasPrefix($0) }) { return nil }
        }

        // These are internal protocol details; the operation's meaningful
        // milestones and all warnings/errors remain visible.
        let routineDetails = [
            "atc received '",
            "atc sync state",
            "atc sync notice",
            "atc manifest message",
            "atc manifest notice",
            "captured grappasupportinfo",
            "source-scoped assetid=",
            "token=",
            "rsd published "
        ]
        if routineDetails.contains(where: { lower.contains($0) }) { return nil }

        // Suppress the repeated low-level Remote Pairing / RSD tunnel negotiation
        // trace. These records are emitted for every candidate address and drown
        // out useful Airlift operation results; the higher-level pairing status
        // and actionable operation errors are logged elsewhere.
        let remoteTunnelNoise = [
            "parsed remote pairing credentials, attempting rsd tunnel",
            "trying rsd tunnel on ",
            "remotexpc on ",
            "fallback trying raw rppairing on ",
            "tunnel dial:",
            "pair-verify against ",
            "raw rppairing on ",
            "tunnel connected successfully on ",
            "found rsd shim service ",
            "body length is "
        ]
        if remoteTunnelNoise.contains(where: { lower.contains($0) }) { return nil }
        if lower.contains("airlift:   •") { return nil }

        // Collapse repeated implementation-level progress messages into the
        // same short stage descriptions used by the Home log.
        let compactStages: [(String, String)] = [
            ("airlift: starting on-device exploit", "[exploit] Starting"),
            ("airlift: opening afc client...", "[connect] Connecting to AFC"),
            ("airlift: afc client connected", "[connect] AFC connected"),
            ("airlift: snapshotting books sync state...", "[sync] Preserving sync state"),
            ("airlift: starting streaming_zip_conduit service...", "[connect] Starting StreamingZip"),
            ("airlift: uploading streamingzip payload...", "[write] Uploading payload"),
            ("airlift: streamingzip extracted", "[write] Payload extracted"),
            ("airlift: stage objects verified in afc", "[write] Payload verified"),
            ("airlift: staged books.plist via afc", "[sync] State staged"),
            ("airlift: starting com.apple.atc service...", "[sync] Starting AirTraffic"),
            ("airlift: syncallowed observed", "[sync] Sync allowed"),
            ("airlift: syncallowed not emitted", "[sync] Continuing without SyncAllowed"),
            ("airlift: readyforsync observed", "[sync] Ready for sync"),
            ("airlift: assetmanifest observed", "[sync] Manifest received"),
            ("airlift: airtraffic sync complete", "[sync] Completed"),
            ("airlift: reading back recovered canary via afc...", "[read] Verifying result"),
            ("airlift: cleaning up temporary objects in afc...", "[cleanup] Removing temporary files"),
            ("airlift: restored original books.plist", "[sync] Original state restored"),
            ("airlift: starting repeatable read of ", "[read] Starting read: "),
            ("airlift-read: starting repeatable read of ", "[read] Starting read: "),
            ("airlift-folder: starting folder export of ", "[folder] Exporting: "),
            ("airlift: safely removed afc staging tree", "[cleanup] Staging removed"),
            ("airlift: connecting to restart device / springboard...", "[respring] Connecting"),
            ("airlift: sending restart request to diagnostics_relay...", "[respring] Sending restart request"),
            ("airlift: device restart / respring initiated successfully!", "[respring] Restart started")
        ]
        for (verbose, concise) in compactStages {
            if lower.hasPrefix(verbose) {
                if verbose.hasSuffix(" ") {
                    let suffix = String(line.dropFirst(verbose.count))
                    line = concise + suffix
                } else {
                    line = concise
                }
                break
            }
        }

        // Make remaining Rust output resemble Home's tagged log lines.
        if line.hasPrefix("airlift-read: ") {
            line = "[read] " + String(line.dropFirst("airlift-read: ".count))
        } else if line.hasPrefix("airlift-folder: ") {
            line = "[folder] " + String(line.dropFirst("airlift-folder: ".count))
        } else if line.hasPrefix("airlift-container: ") {
            line = "[scan] " + String(line.dropFirst("airlift-container: ".count))
        } else if line.hasPrefix("airlift: ") {
            line = "[airlift] " + String(line.dropFirst("airlift: ".count))
        } else if line.hasPrefix("RPPairing: ") {
            line = "[pairing] " + String(line.dropFirst("RPPairing: ".count))
        }

        // Keep the complete diagnostic text. Truncation made socket and
        // tunnel errors impossible to troubleshoot from the in-app log.
        return line
    }

    nonisolated func beginFeatureOperationLogScope() {
        featureOperationLogLock.lock()
        featureOperationLogSuppressionDepth += 1
        featureOperationLogLock.unlock()
    }

    nonisolated func endFeatureOperationLogScope() {
        featureOperationLogLock.lock()
        featureOperationLogSuppressionDepth = max(0, featureOperationLogSuppressionDepth - 1)
        featureOperationLogLock.unlock()
    }

    /// Send a concise, emoji-free feature result to Home. `print` is captured by
    /// ErosionApp's stdout pipe; Airlift's dedicated log array remains independent.
    nonisolated func appendFeatureLog(_ feature: String, _ message: String) {
        let clean = Self.cleanFeatureLogMessage(message)
        print("[airlift-\(feature)] \(clean)")
    }

    nonisolated private static func cleanFeatureLogMessage(_ message: String) -> String {
        message
            .replacingOccurrences(of: "❌", with: "[!] ")
            .replacingOccurrences(of: "✅", with: "[+] ")
            .replacingOccurrences(of: "🎉", with: "[+] ")
            .replacingOccurrences(of: "⚠️", with: "[!] ")
            .replacingOccurrences(of: "⚠", with: "[!] ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func flushLogBuffer() {
        logBufferLock.lock()
        let batch = pendingLogLines
        pendingLogLines.removeAll(keepingCapacity: true)
        logFlushScheduled = false
        let needsAnotherFlush = !pendingLogLines.isEmpty
        logBufferLock.unlock()

        guard !batch.isEmpty else { return }
        loggedLines.append(contentsOf: batch)
        if loggedLines.count > 800 {
            loggedLines.removeFirst(loggedLines.count - 600)
        }
        exploitLog = loggedLines

        if needsAnotherFlush {
            logBufferLock.lock()
            if !logFlushScheduled { logFlushScheduled = true }
            logBufferLock.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                self?.flushLogBuffer()
            }
        }
    }
    func clearLog() {
        logBufferLock.lock()
        pendingLogLines.removeAll()
        logFlushScheduled = false
        logBufferLock.unlock()
        loggedLines.removeAll()
        exploitLog = []
    }
    func pairingFilePath() -> String { PairingController.pairingFilePath() }
    /// Single gate used by every Airlift-only UI feature.
    /// A feature is ready only when both LocalDevVPN and a valid pairing file are present.
    func airliftFeatureReady() -> Bool {
        NetworkStatus.loopbackVPNUp() && hasPairing()
    }

    func hasPairing() -> Bool {
        let p = pairingFilePath()
        guard FileManager.default.fileExists(atPath: p) else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int) ?? 0
        return size > 0
    }

    func importPairingFileError(_ error: Error) {
        appendLog("[pairing] ❌ Import cancelled/failed: \(error.localizedDescription)")
        pairingStatus = "Import failed"
    }

    func importPairingFile(from url: URL) {
        do {
            let path = try PairingController.importPairingFile(from: url)
            state = .ready(pairingPath: path)
            pairingStatus = "Imported and validated"
            pairPIN = nil
            appScanHasRunForPairing = false
            appScanHadAirliftReadyConnection = false
            let localDevReady = NetworkStatus.loopbackVPNUp()
            if isAirliftCompatibilityMode() && localDevReady {
                UserDefaults.standard.set(true, forKey: "airliftThemingReady")
                themingReady = true
            }
            appendLog("[pairing] imported and validated: \(url.lastPathComponent)")
            if isAirliftCompatibilityMode() && !localDevReady {
                appendLog("[pairing] LocalDevVPN is not active; Airlift-only theming remains locked")
            }
        } catch {
            appendLog("[pairing] ❌ \(error.localizedDescription)")
            pairingStatus = "Invalid pairing file"
        }
    }

    func runPairing() {
        guard !hasPairing() else { state = .ready(pairingPath: pairingFilePath()); return }
        state = .pairing; pairingStatus = "Starting host..."; pairPIN = nil
        let ctrl = PairingController.shared
        Task {
            do {
                let path = try await ctrl.startAndWait()
                self.state = .ready(pairingPath: path)
                self.pairingStatus = "Paired"; self.pairPIN = nil
            } catch is CancellationError {
                self.state = .idle; self.pairingStatus = "Cancelled"
            } catch {
                self.state = .idle
                self.pairingStatus = "Failed: \(error.localizedDescription)"
            }
        }
        Task {
            while case .pairing = self.state {
                try? await Task.sleep(nanoseconds: 200_000_000)
                let nextStatus = ctrl.pairingStatus
                let nextPIN = ctrl.pairingPIN
                // Avoid publishing identical values on every poll. SwiftUI was
                // rebuilding the toolbar menu repeatedly while pairing, making
                // its actions appear to flicker.
                if self.pairingStatus != nextStatus { self.pairingStatus = nextStatus }
                if self.pairPIN != nextPIN { self.pairPIN = nextPIN }
            }
        }
    }
    func cancelPairing() {
        PairingController.shared.softCancel()
        state = .idle; pairingStatus = ""; pairPIN = nil
    }
    func deletePairing() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let canonicalURL = docs.appendingPathComponent("erosion_pairing.plist")
        if fm.fileExists(atPath: canonicalURL.path) { try? fm.removeItem(at: canonicalURL) }
        if let custom = PairingController.customPairingFilePath, fm.fileExists(atPath: custom) {
            try? fm.removeItem(atPath: custom)
        }
        PairingController.customPairingFilePath = nil
        UserDefaults.standard.removeObject(forKey: "erosionPairingActiveFilePath")
        if let files = try? fm.contentsOfDirectory(atPath: docs.path) {
            for f in files {
                guard f.hasSuffix(".plist") || f.hasSuffix(".mobilepairing") || f.hasSuffix(".mobilepair") else { continue }
                try? fm.removeItem(at: docs.appendingPathComponent(f))
            }
        }
        UserDefaults.standard.removeObject(forKey: "erosionPairingHostAltIRK")
        UserDefaults.standard.removeObject(forKey: "airliftThemingReady")
        themingReady = false
        appScanHasRunForPairing = false
        appScanHadAirliftReadyConnection = false
        installedAppContainers = []
        installedAppBundlePaths = []
        appScanLog = []
        state = .idle; pairingStatus = ""; pairPIN = nil
    }
    func runExploit(
        logDetails: Bool = true,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        guard state != .running, state != .pairing else {
            completion?(false)
            return
        }

        state = .running
        loggedLines.removeAll()
        exploitLog = []
        let targetDir = Self.normalizedRemotePath(target)
        guard !targetDir.isEmpty else {
            state = .done(ok: false, message: "Invalid target")
            if logDetails { appendLog("[exploit] blocked: Target path is empty") }
            completion?(false)
            return
        }

        if logDetails {
            appendLog("[exploit] starting")
        }

        Task.detached(priority: .userInitiated) {
            // PairingController may recover a previously imported file from Documents.
            // Resolve it away from the main thread so Settings remains responsive.
            let pairingPath = PairingController.pairingFilePath()
            let pairingURL = URL(fileURLWithPath: pairingPath)
            let pairingReady = FileManager.default.fileExists(atPath: pairingPath)
                && ((try? FileManager.default.attributesOfItem(atPath: pairingPath)[.size] as? NSNumber)?.intValue ?? 0) > 0
            let vpnReady = NetworkStatus.loopbackVPNUp()

            guard pairingReady, vpnReady else {
                await MainActor.run {
                    let message = pairingReady ? "LocalDevVPN is not active" : "No pairing file"
                    self.state = .done(ok: false, message: logDetails ? message : "Airlift unavailable")
                    if logDetails { self.appendLog("[exploit] blocked: \(message)") }
                    completion?(false)
                }
                return
            }

            // Keep the settings probe's detailed Rust diagnostics (which may include
            // target paths) out of Airlift and Home logs. The caller records one result.
            self.beginFeatureOperationLogScope()
            defer { self.endFeatureOperationLogScope() }

            var outJson: UnsafeMutablePointer<CChar>? = nil
            var outError: UnsafeMutablePointer<CChar>? = nil
            let rc: Int32 = pairingURL.path.withCString { pc in
                targetDir.withCString { tc in
                    al_exploit_run(pc, tc, nil, nil, &outJson, &outError)
                }
            }
            let jsonStr = outJson.flatMap { p -> String? in
                let value = String(cString: p)
                al_string_free(p)
                return value
            }
            let errStr = outError.flatMap { p -> String? in
                let value = String(cString: p)
                al_string_free(p)
                return value
            }

            await MainActor.run {
                let succeeded = rc == 0
                if logDetails {
                    if succeeded {
                        self.appendLog("[exploit] ok: \(jsonStr ?? "OK")")
                    } else {
                        self.appendLog("[exploit] fail: \(errStr ?? "rc=\(rc)")")
                    }
                }
                self.state = .done(
                    ok: succeeded,
                    message: logDetails ? (succeeded ? (jsonStr ?? "OK") : (errStr ?? "rc=\(rc)"))
                                        : (succeeded ? "Exploit succeeded" : "Exploit failed")
                )
                completion?(succeeded)
            }
        }
    }
    nonisolated var shouldSuppressContainerScannerLogs: Bool {
        containerScannerLogLock.lock()
        defer { containerScannerLogLock.unlock() }
        return containerScannerLogSuppressionDepth > 0
    }

    nonisolated private func beginContainerScannerLogSuppression() {
        containerScannerLogLock.lock()
        containerScannerLogSuppressionDepth += 1
        containerScannerLogLock.unlock()
    }

    nonisolated private func endContainerScannerLogSuppression() {
        containerScannerLogLock.lock()
        containerScannerLogSuppressionDepth = max(0, containerScannerLogSuppressionDepth - 1)
        containerScannerLogLock.unlock()
    }

    var containerScansRunning: Bool {
        appScanRunning || appGroupAfcScanRunning || appGroupBadQueryScanRunning
            || internalDaemonAfcProbeRunning || pluginKitPluginAfcProbeRunning
            || internalDaemonBadQueryRunning || pluginKitPluginBadQueryRunning
    }

    /// True only after the current pairing's InstallationProxy scan completed successfully.
    /// File Browser uses this to avoid mixing stale paths from a previous pairing into WQ rows.
    var installedAppContainerScanReady: Bool {
        appScanHasRunForPairing && appScanHadAirliftReadyConnection && !appScanRunning
    }

    /// Uses the same persisted File Browser inode setting in normal and Airlift
    /// modes. The SwiftUI default is 7,500,000 when the preference has not been saved.
    func configuredFileBrowserMaxInode() -> Int64 {
        let stored = UserDefaults.standard.object(forKey: "maxInode") as? NSNumber
        let value = stored?.int64Value ?? 7_500_000
        return max(1, value)
    }

    var totalContainerResultCount: Int {
        Set(installedAppContainers.map { normalizeContainerPath($0.container) }
            + installedAppGroups.map { normalizeContainerPath($0.container) }
            + appGroupAfcContainerPaths.map { normalizeContainerPath($0.container) }
            + appGroupContainerPaths.map { normalizeContainerPath($0.container) }
            + internalDaemonAfcPaths.map(normalizeContainerPath)
            + pluginKitPluginAfcPaths.map(normalizeContainerPath)
            + internalDaemonBadQueryPaths.map(normalizeContainerPath)
            + pluginKitPluginBadQueryPaths.map(normalizeContainerPath)).count
    }

    /// Manually refresh every known container source from the unified Containers screen.
    func rescanAllContainers() {
        scanInstalledAppContainers()
        scanAppGroupContainerPathsViaAirlift()
        let inodeLimit = configuredFileBrowserMaxInode()
        scanAppGroupContainerPaths(maxInode: inodeLimit)
        let internalDaemonRoot = "/var/mobile/Containers/Data/InternalDaemon"
        let pluginKitPluginRoot = "/var/mobile/Containers/Data/PluginKitPlugin"
        // Keep AFC probing available for InternalDaemon, but never use AFC for
        // PluginKitPlugin: that root is enumerated through BadQuery only.
        probeAdditionalContainerRootViaAirlift(internalDaemonRoot)
        scanAdditionalContainerRootWithBadQuery(internalDaemonRoot, maxInode: inodeLimit)
        scanAdditionalContainerRootWithBadQuery(pluginKitPluginRoot, maxInode: inodeLimit)
    }

    /// Starts the metadata-only InstallationProxy scan used by both container labels
    /// and Apps → Bundles. No filesystem listing or access grant is requested.
    func scanInstalledAppBundlePathsIfNeeded() {
        guard !appScanRunning, !appScanHasRunForPairing else { return }
        guard FileManager.default.fileExists(atPath: pairingFilePath()) else {
            appScanLog = ["Please ensure you turned localdev on and have valid pairing file."]
            return
        }
        if airliftUIAccessRequired() && !airliftFeatureReady() {
            appScanLog = ["[scan] waiting: enable LocalDevVPN and provide a valid pairing file"]
            return
        }
        appScanHasRunForPairing = true
        scanInstalledAppContainers()
    }

    /// Adds InstallationProxy as an optional path-discovery layer for Apps → Data Containers.
    /// This is deliberately independent of the iOS compatibility-mode UI gate: when a valid
    /// pairing and LocalDevVPN are both active, InstallationProxy contributes paths only.
    /// FileBrowser still obtains access and performs every directory/file operation through WQ.
    func scanInstalledAppContainersForDataBrowserIfNeeded() {
        guard airliftFeatureReady(),
              !appScanRunning,
              (!appScanHasRunForPairing || !appScanHadAirliftReadyConnection) else { return }
        appScanHasRunForPairing = true
        scanInstalledAppContainers()
    }

    /// Enumerates installed application metadata through InstallationProxy only.
    /// This is kept separate from the normal Airlift exploit/read log.
    func maybeAutoScanInstalledAppContainers() {
        guard isAirliftCompatibilityMode(),
              NetworkStatus.loopbackVPNUp(),
              hasPairing(),
              !appScanRunning,
              !appScanHasRunForPairing else { return }
        appScanHasRunForPairing = true
        scanInstalledAppContainers()
    }

    /// Resolve an app's data-container path from InstallationProxy metadata.
    /// If the cache is empty, use the same embedded InstallationProxy scan already
    /// used by the Containers browser and wait briefly for its result.
    @MainActor
    func resolveInstalledAppContainerPath(bundleID: String) async -> String? {
        guard FileManager.default.fileExists(atPath: pairingFilePath()) else {
            appendLog("[scan] cannot resolve \(bundleID): pairing file is missing")
            return nil
        }

        if let cached = installedAppContainers.first(where: {
            $0.bundleID == bundleID && $0.container.hasPrefix("/var/mobile/Containers/Data/Application/")
        }) {
            return cached.container
        }

        if !appScanRunning {
            scanInstalledAppContainers()
        }

        for _ in 0..<120 {
            if let match = installedAppContainers.first(where: {
                $0.bundleID == bundleID && $0.container.hasPrefix("/var/mobile/Containers/Data/Application/")
            }) {
                return match.container
            }
            if !appScanRunning { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        appendLog("[scan] InstallationProxy did not return a Data/Application container for \(bundleID)")
        return nil
    }

    func scanInstalledAppContainers() {
        let pairingPath = pairingFilePath()
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            appScanLog = ["Please ensure you turned localdev on and have valid pairing file."]
            return
        }
        if airliftUIAccessRequired() && !airliftFeatureReady() {
            appScanLog = ["[scan] waiting: enable LocalDevVPN and provide a valid pairing file"]
            return
        }
        guard !appScanRunning else { return }

        appScanHadAirliftReadyConnection = airliftFeatureReady()
        appScanRunning = true
        appScanLog = ["[scan] starting InstallationProxy app scan…"]
        beginContainerScannerLogSuppression()

        Task.detached { [weak self] in
            defer { self?.endContainerScannerLogSuppression() }
            var outJSON: UnsafeMutablePointer<CChar>?
            var outError: UnsafeMutablePointer<CChar>?
            let rc = pairingPath.withCString { pc in
                al_list_app_containers(pc, nil, nil, &outJSON, &outError)
            }

            let jsonString = outJSON.flatMap { ptr -> String? in
                let value = String(cString: ptr)
                al_string_free(ptr)
                return value
            }
            let errorString = outError.flatMap { ptr -> String? in
                let value = String(cString: ptr)
                al_string_free(ptr)
                return value
            }

            guard rc == 0, let jsonString,
                  let data = jsonString.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                await MainActor.run {
                    self?.appScanLog = ["[scan] failed: \(errorString ?? "rc=\(rc)")"]
                    self?.installedAppBundlePaths = []
                    // Permit a retry after re-entering File Browser if a transient
                    // InstallationProxy failure occurred during automatic app-entry scan.
                    self?.appScanHasRunForPairing = false
                    self?.appScanHadAirliftReadyConnection = false
                    self?.appScanRunning = false
                }
                return
            }

            let apps = payload["applications"] as? [[String: Any]] ?? []
            let parsed = apps.compactMap { app -> AirliftAppContainer? in
                guard let bundleID = app["bundleID"] as? String,
                      let rawContainer = app["container"] as? String else { return nil }
                let container = rawContainer.hasPrefix("/private/var/")
                    ? String(rawContainer.dropFirst("/private".count))
                    : rawContainer
                guard container.hasPrefix("/var/mobile/Containers/Data/Application/")
                        || container.hasPrefix("/var/containers/Data/Application/") else { return nil }
                return AirliftAppContainer(bundleID: bundleID, container: container)
            }

            let bundleValues = payload["bundles"] as? [[String: Any]] ?? []
            let parsedBundles = bundleValues.compactMap { item -> AirliftAppBundlePath? in
                guard let bundleID = item["bundleID"] as? String,
                      !bundleID.isEmpty,
                      let rawPath = item["path"] as? String else { return nil }
                let path = rawPath.hasPrefix("/private/var/")
                    ? String(rawPath.dropFirst("/private".count))
                    : rawPath
                let root = "/var/containers/Bundle/Application/"
                guard path.hasPrefix(root) else { return nil }
                let relativePath = String(path.dropFirst(root.count))
                let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
                guard components.count == 2,
                      UUID(uuidString: String(components[0])) != nil else { return nil }
                let appBundleName = String(components[1])
                guard appBundleName.count > 4,
                      appBundleName.lowercased().hasSuffix(".app") else { return nil }
                let metadataName = (item["displayName"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let displayName = metadataName.flatMap { name in
                    name.isEmpty ? nil : name
                } ?? "Unknown"
                return AirliftAppBundlePath(
                    bundleID: bundleID,
                    displayName: displayName,
                    path: path
                )
            }

            let groupValues = payload["appGroups"] as? [[String: Any]] ?? []
            let parsedGroups = groupValues.compactMap { group -> AirliftAppGroup? in
                guard let groupID = group["groupID"] as? String,
                      let container = group["container"] as? String else { return nil }
                return AirliftAppGroup(
                    groupID: groupID,
                    groupIDs: group["groupIDs"] as? [String] ?? [],
                    container: container,
                    sourceApps: group["sourceApps"] as? [String] ?? []
                )
            }

            let identifierValues = payload["groupIdentifiers"] as? [[String: Any]] ?? []
            let identifiersWithoutPaths = identifierValues.compactMap { item -> AirliftAppGroupIdentifier? in
                guard let groupID = item["groupID"] as? String else { return nil }
                // Keep the second list honest: only report identifiers that do not
                // correspond to a directory path in the actual path results.
                guard !parsedGroups.contains(where: {
                    $0.groupIDs.contains(groupID) || $0.groupID == groupID || $0.container.hasSuffix("/\(groupID)")
                }) else { return nil }
                return AirliftAppGroupIdentifier(groupID: groupID, sourceApps: item["sourceApps"] as? [String] ?? [])
            }

            let bundleMetadataPathCount = payload["bundleMetadataPathCount"] as? Int ?? parsedBundles.count
            let bundlePathParseCount = payload["bundlePathParseCount"] as? Int ?? parsedBundles.count

            await MainActor.run {
                self?.installedAppContainers = parsed
                self?.installedAppBundlePaths = parsedBundles
                self?.installedAppGroups = parsedGroups
                self?.appGroupIdentifiersWithoutPaths = identifiersWithoutPaths
                self?.appScanLog = [
                    "[scan] InstallationProxy returned \(parsed.count) Data/Application container(s)",
                    "[scan] InstallationProxy returned \(parsedBundles.count) Bundle/Application path(s)",
                    "[scan] app records with Path/ApplicationPath: \(bundleMetadataPathCount); valid Bundle/Application paths: \(bundlePathParseCount)",
                    "[scan] Bundle paths came from app plist metadata; no directories were opened, enumerated, or read"
                ]
                self?.appScanRunning = false
            }
        }
    }

    /// Probe Shared/AppGroup via AFC directory-entry listing only. This deliberately
    /// does not call al_exploit_read_folder / al_exploit_read_file and does not move,
    /// create, rename, delete, or write any device-side path.
    func scanAppGroupContainerPathsViaAirlift() {
        guard !appGroupAfcScanRunning else { return }
        let pairingPath = pairingFilePath()
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            appGroupAfcScanLog = [
                "[app-group-afc] no pairing file; import pairing and enable the existing Airlift connection first",
                "[app-group-afc] no directory query was sent to the device"
            ]
            appGroupPathScanLog = appGroupAfcScanLog + appGroupBadQueryScanLog
            return
        }

        appGroupAfcScanRunning = true
        appGroupPathScanRunning = true
        appGroupAfcScanLog = [
            "[app-group-afc] direct AFC listing probe for /var/mobile/Containers/Shared/AppGroup",
            "[app-group-afc] directory names only; no file contents, Airlift Read, staging, or device writes"
        ]
        appGroupPathScanLog = appGroupAfcScanLog + appGroupBadQueryScanLog
        beginContainerScannerLogSuppression()

        Task.detached { [weak self] in
            defer { self?.endContainerScannerLogSuppression() }
            var outJSON: UnsafeMutablePointer<CChar>?
            var outError: UnsafeMutablePointer<CChar>?
            let rc = pairingPath.withCString { pc in
                al_list_app_group_container_paths(pc, nil, nil, &outJSON, &outError)
            }
            let jsonString = outJSON.flatMap { ptr -> String? in
                let value = String(cString: ptr)
                al_string_free(ptr)
                return value
            }
            let errorString = outError.flatMap { ptr -> String? in
                let value = String(cString: ptr)
                al_string_free(ptr)
                return value
            }

            guard rc == 0, let jsonString,
                  let data = jsonString.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                await MainActor.run {
                    guard let self else { return }
                    self.appGroupAfcScanLog = [
                        "[app-group-afc] probe failed: \(errorString ?? "rc=\(rc)")",
                        "[app-group-afc] this path probe did not fall back to Airlift Read"
                    ]
                    self.appGroupAfcScanRunning = false
                    self.appGroupPathScanRunning = self.appGroupBadQueryScanRunning
                    self.appGroupPathScanLog = self.appGroupAfcScanLog + self.appGroupBadQueryScanLog
                }
                return
            }

            let paths = payload["paths"] as? [String] ?? []
            let parsed = paths.compactMap { path -> AirliftAppGroupContainerPath? in
                let normalized = path.hasPrefix("/private/var/")
                    ? String(path.dropFirst("/private".count))
                    : path
                let uuid = URL(fileURLWithPath: normalized).lastPathComponent
                guard UUID(uuidString: uuid) != nil else { return nil }
                return AirliftAppGroupContainerPath(uuid: uuid, container: normalized)
            }
            let attempts = payload["attempts"] as? [[String: Any]] ?? []
            var lines = [
                "[app-group-afc] method: direct AFC list_dir (directory entries only)",
                "[app-group-afc] UUID container paths returned: \(parsed.count)"
            ]
            for attempt in attempts {
                let path = attempt["path"] as? String ?? "(unknown path)"
                let status = attempt["status"] as? String ?? "unknown"
                if status == "listed" {
                    let entryCount = attempt["entryCount"] as? Int ?? 0
                    let uuidCount = attempt["uuidEntryCount"] as? Int ?? 0
                    lines.append("[app-group-afc] \(path): listed \(entryCount) entries; \(uuidCount) UUID-shaped")
                    let samples = attempt["sampleEntries"] as? [String] ?? []
                    if !samples.isEmpty { lines.append("[app-group-afc] sample names: \(samples.joined(separator: ", "))") }
                } else {
                    let error = attempt["error"] as? String ?? status
                    lines.append("[app-group-afc] \(path): \(error)")
                }
            }
            if parsed.isEmpty {
                lines.append("[app-group-afc] AFC did not expose UUID children at that absolute path; no Airlift Read fallback was attempted")
            } else {
                lines.append("[app-group-afc] paths came from direct directory enumeration, not from file reads")
            }
            lines.append("[app-group-afc] complete — no file payloads read and no device filesystem mutations requested")

            await MainActor.run {
                guard let self else { return }
                self.appGroupAfcContainerPaths = parsed
                self.appGroupAfcScanLog = lines
                self.appGroupAfcScanRunning = false
                self.appGroupPathScanRunning = self.appGroupBadQueryScanRunning
                self.appGroupPathScanLog = self.appGroupAfcScanLog + self.appGroupBadQueryScanLog
            }
        }
    }

    /// Enumerate only the immediate UUID-named children of Shared/AppGroup using
    /// the existing fsgetpath-based BadQuery path enumerator. This does not call
    /// either Airlift read primitive and does not stage, move, read, or write files.
    /// The scan is local and metadata-only; it does not require pairing/VPN.
    func scanAppGroupContainerPaths(maxInode: Int64? = nil) {
        let inodeLimit = maxInode ?? configuredFileBrowserMaxInode()
        guard !appGroupBadQueryScanRunning else { return }
        appGroupBadQueryScanRunning = true
        appGroupPathScanRunning = true
        appGroupBadQueryScanLog = [
            "[bad_query] scanning /var/mobile/Containers/Shared/AppGroup",
            "[bad_query] path-only scan; inode ceiling: \(inodeLimit)",
            "[bad_query] getPathsOfDir"
        ]
        appGroupPathScanLog = appGroupAfcScanLog + appGroupBadQueryScanLog

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let root = "/var/mobile/Containers/Shared/AppGroup"
            let rawPaths = BadQuery().getPathsOfDir(atPath: root, maxInode: inodeLimit)
            var discovered = Set<String>()
            for rawPath in rawPaths {
                let normalized: String
                if rawPath.hasPrefix("/private/var/") {
                    normalized = String(rawPath.dropFirst("/private".count))
                } else {
                    normalized = rawPath
                }
                let prefix = root + "/"
                guard normalized.hasPrefix(prefix) else { continue }
                let leaf = String(normalized.dropFirst(prefix.count))
                guard !leaf.isEmpty, !leaf.contains("/"), UUID(uuidString: leaf) != nil else { continue }
                discovered.insert(root + "/" + leaf)
            }
            let sortedPaths = discovered.sorted()
            let parsed = sortedPaths.compactMap { path -> AirliftAppGroupContainerPath? in
                let uuid = URL(fileURLWithPath: path).lastPathComponent
                guard UUID(uuidString: uuid) != nil else { return nil }
                return AirliftAppGroupContainerPath(uuid: uuid, container: path)
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.appGroupContainerPaths = parsed
                self.appGroupBadQueryScanLog = [
                    "[bad_query] raw fsgetpath matches: \(rawPaths.count)",
                    "[bad_query] UUID container paths: \(parsed.count)",
                    "[bad_query] source: bad_query_list (local path enumeration)",
                    "[bad_query] inode ceiling: \(inodeLimit)",
                    parsed.isEmpty
                        ? "[bad_query] no UUID paths found within this inode range; existing scanner returned no match"
                        : "[bad_query] listing complete; group identifiers are not assumed to map to these UUIDs",
                    "[bad_query] complete — no device files were read, moved, or written"
                ]
                self.appGroupBadQueryScanRunning = false
                self.appGroupPathScanRunning = self.appGroupAfcScanRunning
                self.appGroupPathScanLog = self.appGroupAfcScanLog + self.appGroupBadQueryScanLog
            }
        }
    }

    /// Return an App Group identifier only when it is directly associated in
    /// InstallationProxy metadata or can be uniquely inferred from a single
    /// group and single physical path for the same app. Never label a UUID as an ID.
    func appGroupDisplayName(for rawPath: String) -> String {
        let path = normalizeContainerPath(rawPath)
        guard let item = installedAppGroups.first(where: { normalizeContainerPath($0.container) == path }) else {
            return "?"
        }
        let directIDs = Array(Set(item.groupIDs)).sorted()
        if !directIDs.isEmpty { return directIDs.joined(separator: ", ") }

        var candidates = Set<String>()
        for app in item.sourceApps {
            let idsForApp = appGroupIdentifiersWithoutPaths.filter { $0.sourceApps.contains(app) }
            let pathsForApp = installedAppGroups.filter { $0.sourceApps.contains(app) }
            if idsForApp.count == 1 && pathsForApp.count == 1 {
                candidates.insert(idsForApp[0].groupID)
            }
        }
        return candidates.count == 1 ? (candidates.first ?? "?") : "?"
    }

    private func normalizeContainerPath(_ path: String) -> String {
        path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
    }

    private func isSupportedAdditionalContainerRoot(_ root: String) -> Bool {
        root == "/var/mobile/Containers/Data/InternalDaemon"
            || root == "/var/mobile/Containers/Data/PluginKitPlugin"
    }

    private func publishAdditionalProbePaths(_ paths: [String], root: String, source: String) {
        if root.hasSuffix("/InternalDaemon") {
            if source == "AFC" { internalDaemonAfcPaths = paths }
            else { internalDaemonBadQueryPaths = paths }
        } else if root.hasSuffix("/PluginKitPlugin") {
            if source == "AFC" { pluginKitPluginAfcPaths = paths }
            else { pluginKitPluginBadQueryPaths = paths }
        }
    }

    private func additionalProbeIsRunning(root: String, source: String) -> Bool {
        if root.hasSuffix("/InternalDaemon") {
            return source == "AFC" ? internalDaemonAfcProbeRunning : internalDaemonBadQueryRunning
        }
        return source == "AFC" ? pluginKitPluginAfcProbeRunning : pluginKitPluginBadQueryRunning
    }

    private func setAdditionalProbeRunning(_ running: Bool, root: String, source: String) {
        if root.hasSuffix("/InternalDaemon") {
            if source == "AFC" { internalDaemonAfcProbeRunning = running }
            else { internalDaemonBadQueryRunning = running }
        } else if root.hasSuffix("/PluginKitPlugin") {
            if source == "AFC" { pluginKitPluginAfcProbeRunning = running }
            else { pluginKitPluginBadQueryRunning = running }
        }
        additionalContainerProbeRunning = internalDaemonAfcProbeRunning || pluginKitPluginAfcProbeRunning || internalDaemonBadQueryRunning || pluginKitPluginBadQueryRunning
    }

    private func setAdditionalProbeLog(_ lines: [String], root: String, source: String) {
        if root.hasSuffix("/InternalDaemon") {
            if source == "AFC" { internalDaemonAfcProbeLog = lines }
            else { internalDaemonBadQueryLog = lines }
        } else if root.hasSuffix("/PluginKitPlugin") {
            if source == "AFC" { pluginKitPluginAfcProbeLog = lines }
            else { pluginKitPluginBadQueryLog = lines }
        }
        additionalContainerProbeLog = lines
    }

    func additionalContainerAfcLog(for root: String) -> [String] {
        root.hasSuffix("/InternalDaemon") ? internalDaemonAfcProbeLog : pluginKitPluginAfcProbeLog
    }

    func additionalContainerBadQueryLog(for root: String) -> [String] {
        root.hasSuffix("/InternalDaemon") ? internalDaemonBadQueryLog : pluginKitPluginBadQueryLog
    }

    /// Direct AFC directory-entry listing for a fixed allowlist of container roots.
    /// Does not invoke Airlift Read, open file payloads, or mutate device-side paths.
    func probeAdditionalContainerRootViaAirlift(_ root: String) {
        guard !root.hasSuffix("/PluginKitPlugin") else {
            additionalContainerProbeLog = ["[container-probe-afc] PluginKitPlugin is BadQuery-only; AFC request skipped"]
            return
        }
        guard isSupportedAdditionalContainerRoot(root) else {
            additionalContainerProbeLog = ["[container-probe] unsupported root; no request sent"]
            return
        }
        guard !additionalProbeIsRunning(root: root, source: "AFC") else { return }
        let pairingPath = pairingFilePath()
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            setAdditionalProbeLog(["[container-probe-afc] no pairing file; no device request sent"], root: root, source: "AFC")
            return
        }
        setAdditionalProbeRunning(true, root: root, source: "AFC")
        setAdditionalProbeLog([
            "[container-probe-afc] requested root: \(root)",
            "[container-probe-afc] AFC list_dir only; no Airlift Read, file payloads, or writes"
        ], root: root, source: "AFC")
        beginContainerScannerLogSuppression()

        Task.detached { [weak self] in
            defer { self?.endContainerScannerLogSuppression() }
            var outJSON: UnsafeMutablePointer<CChar>?
            var outError: UnsafeMutablePointer<CChar>?
            let rc = pairingPath.withCString { pc in
                root.withCString { rp in
                    al_probe_directory_entries(pc, rp, nil, nil, &outJSON, &outError)
                }
            }
            let jsonString = outJSON.flatMap { ptr -> String? in
                let value = String(cString: ptr); al_string_free(ptr); return value
            }
            let errorString = outError.flatMap { ptr -> String? in
                let value = String(cString: ptr); al_string_free(ptr); return value
            }
            guard rc == 0, let jsonString, let data = jsonString.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                await MainActor.run {
                    guard let self else { return }
                    self.setAdditionalProbeLog([
                        "[container-probe-afc] failed: \(errorString ?? "rc=\(rc)")",
                        "[container-probe-afc] no fallback to Airlift Read was attempted"
                    ], root: root, source: "AFC")
                    self.setAdditionalProbeRunning(false, root: root, source: "AFC")
                }
                return
            }
            let paths = payload["paths"] as? [String] ?? []
            let attempts = payload["attempts"] as? [[String: Any]] ?? []
            var lines = ["[container-probe-afc] root entries found: \(paths.count)"]
            for attempt in attempts {
                let attemptedPath = attempt["path"] as? String ?? "(unknown path)"
                let status = attempt["status"] as? String ?? "unknown"
                if status == "listed" {
                    let count = attempt["entryCount"] as? Int ?? 0
                    let samples = attempt["sampleEntries"] as? [String] ?? []
                    lines.append("[container-probe-afc] \(attemptedPath): listed \(count) entries")
                    if !samples.isEmpty { lines.append("[container-probe-afc] samples: \(samples.joined(separator: ", "))") }
                } else {
                    lines.append("[container-probe-afc] \(attemptedPath): \(attempt["error"] as? String ?? status)")
                }
            }
            lines.append("[container-probe-afc] no file contents read; no device writes requested")
            await MainActor.run {
                guard let self else { return }
                self.publishAdditionalProbePaths(paths, root: root, source: "AFC")
                self.setAdditionalProbeLog(lines, root: root, source: "AFC")
                self.setAdditionalProbeRunning(false, root: root, source: "AFC")
            }
        }
    }

    /// Reuses the existing BadQuery path enumerator unchanged, limited to the
    /// two requested roots. Only immediate UUID-shaped child paths are retained.
    func scanAdditionalContainerRootWithBadQuery(_ root: String, maxInode: Int64? = nil) {
        let inodeLimit = maxInode ?? configuredFileBrowserMaxInode()
        guard isSupportedAdditionalContainerRoot(root) else {
            additionalContainerProbeLog = ["[bad_query] unsupported root; no scan run"]
            return
        }
        guard !additionalProbeIsRunning(root: root, source: "BadQuery") else { return }
        if root.hasSuffix("/PluginKitPlugin") {
            pluginKitPluginBadQueryInodeLimit = inodeLimit
        }
        setAdditionalProbeRunning(true, root: root, source: "BadQuery")
        setAdditionalProbeLog([
            "[bad_query] scanning \(root)",
            "[bad_query] inode ceiling: \(inodeLimit)"
        ], root: root, source: "BadQuery")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let rawPaths = BadQuery().getPathsOfDir(atPath: root, maxInode: inodeLimit)
            var found = Set<String>()
            for rawPath in rawPaths {
                let normalized = rawPath.hasPrefix("/private/var/") ? String(rawPath.dropFirst("/private".count)) : rawPath
                let prefix = root + "/"
                guard normalized.hasPrefix(prefix) else { continue }
                let leaf = String(normalized.dropFirst(prefix.count))
                guard !leaf.isEmpty, !leaf.contains("/"), UUID(uuidString: leaf) != nil else { continue }
                found.insert(root + "/" + leaf)
            }
            let paths = found.sorted()
            DispatchQueue.main.async {
                guard let self else { return }
                self.publishAdditionalProbePaths(paths, root: root, source: "BadQuery")
                self.setAdditionalProbeLog([
                    "[bad_query] raw paths returned: \(rawPaths.count)",
                    "[bad_query] immediate UUID-shaped container paths: \(paths.count)",
                    "[bad_query] root: \(root)",
                    "[bad_query] inode ceiling: \(inodeLimit)",
                ], root: root, source: "BadQuery")
                self.setAdditionalProbeRunning(false, root: root, source: "BadQuery")
            }
        }
    }

    private static let appIconCache = NSCache<NSString, UIImage>()
    private static let appIconFetchSemaphore = DispatchSemaphore(value: 2)

    /// Returns a cached SpringBoard Services PNG icon for an installed app.
    /// At most two icon tunnel requests run at once to avoid overwhelming RSD.
    func fetchAppIcon(bundleID: String) async -> UIImage? {
        let cacheKey = bundleID as NSString
        if let cached = Self.appIconCache.object(forKey: cacheKey) { return cached }
        guard !bundleID.isEmpty,
              airliftFeatureReady(),
              !readRunning,
              !standardReadInProgress,
              activeRemoteImageReadCount == 0,
              !passcodeFlashRunning else { return nil }
        let pairingPath = pairingFilePath()
        guard FileManager.default.fileExists(atPath: pairingPath) else { return nil }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("erosion-app-icon-\(UUID().uuidString).png")
        let (code, message) = await Task.detached(priority: .utility) {
            Self.appIconFetchSemaphore.wait()
            defer { Self.appIconFetchSemaphore.signal() }
            var outError: UnsafeMutablePointer<CChar>? = nil
            let code = pairingPath.withCString { pairingCString in
                bundleID.withCString { bundleCString in
                    outputURL.path.withCString { outputCString in
                        al_get_app_icon_png(pairingCString, bundleCString, outputCString, nil, nil, &outError)
                    }
                }
            }
            let message = outError.flatMap { pointer -> String? in
                let value = String(cString: pointer)
                al_string_free(pointer)
                return value
            }
            return (code, message)
        }.value
        defer { try? FileManager.default.removeItem(at: outputURL) }

        guard code == 0,
              let data = try? Data(contentsOf: outputURL),
              let image = UIImage(data: data) else {
            if let message, !message.isEmpty {
                appendFeatureLog("apps-management", "Icon fetch failed for \(bundleID): \(message)")
            }
            return nil
        }
        Self.appIconCache.setObject(image, forKey: cacheKey)
        return image
    }

    /// Treat the canonical /var namespace and its /private/var alias as the same
    /// remote device path. Do not standardize dot-components or resolve symlinks.
    static func normalizedRemotePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "/private/var" { return "/var" }
        if trimmed.hasPrefix("/private/var/") {
            return String(trimmed.dropFirst("/private".count))
        }
        return trimmed
    }

    /// Keep each export in its own directory to avoid filename collisions while
    /// presenting the exact remote leaf name in Share/Files.
    private static func moveReadExportToRemoteFilename(localPath: String, remotePath: String) -> String? {
        let leaf = URL(fileURLWithPath: remotePath).lastPathComponent
        guard !leaf.isEmpty, leaf != "/", leaf != ".", leaf != ".." else { return nil }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("erosion_airlift_named_read_\(UUID().uuidString)", isDirectory: true)
        let destination = directory.appendingPathComponent(leaf, isDirectory: false)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try manager.moveItem(at: URL(fileURLWithPath: localPath), to: destination)
            return destination.path
        } catch {
            try? manager.removeItem(at: directory)
            return nil
        }
    }

    private func removeReadSnapshot(atPath path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: url)
        let parent = url.deletingLastPathComponent()
        if parent.lastPathComponent.hasPrefix("erosion_airlift_named_read_") {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    func readRemoteFile(afcOnly: Bool = false) {
        runRemoteRead(kind: .file, afcOnly: afcOnly)
    }

    func readRemoteFolder(afcOnly: Bool = false) {
        runRemoteRead(kind: .folder, afcOnly: afcOnly)
    }

    /// Reads the explicitly selected file/folder primitive for File Operations.
    /// The snapshot is copied into an independent app-support location so Export
    /// can share it later without re-running Airlift or interfering with the
    /// main File Browser's current read snapshot.
    func readRemotePathForFileOperations(
        path: String,
        kind: ReadKind,
        feature: String = "file-operations",
        quiet: Bool = false,
        completion: @escaping (Bool, URL?, String) -> Void
    ) {
        let remote = Self.normalizedRemotePath(path)
        guard remote.hasPrefix("/"), !remote.isEmpty else {
            if !quiet { appendFeatureLog(feature, "Blocked: enter an absolute target path") }
            completion(false, nil, "Enter an absolute target path")
            return
        }
        guard airliftFeatureReady() else {
            if !quiet { appendFeatureLog(feature, "Blocked: LocalDevVPN and pairing are required") }
            completion(false, nil, "Enable LocalDevVPN and import a valid pairing file")
            return
        }
        guard !readRunning, !standardReadInProgress, activeRemoteImageReadCount == 0, !passcodeFlashRunning else {
            if !quiet { appendFeatureLog(feature, "Blocked: another Airlift operation is running") }
            completion(false, nil, "Another Airlift operation is running")
            return
        }

        runRemoteRead(
            kind: kind,
            targetOverride: remote,
            featureLogPrefix: quiet ? nil : feature,
            suppressOperationLogs: quiet,
            dedicatedSnapshot: true
        ) { success, _, sourceURL, detail in
            guard success, let sourceURL else {
                completion(false, nil, detail)
                return
            }

            let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let destinationDirectory = supportRoot.appendingPathComponent("ErosionFileOperationsSnapshots", isDirectory: true)

            DispatchQueue.global(qos: .utility).async {
                do {
                    try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                    if kind == .folder {
                        var isDirectory: ObjCBool = false
                        if FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                            // Preserve the extracted tree directly when the Rust
                            // folder exporter could not finish its ZIP snapshot.
                            let destinationURL = destinationDirectory.appendingPathComponent(
                                "snapshot-\(UUID().uuidString)",
                                isDirectory: true
                            )
                            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                            try? FileManager.default.removeItem(at: sourceURL)
                            DispatchQueue.main.async {
                                completion(true, destinationURL, detail)
                            }
                            return
                        } else {
                            let destinationURL = destinationDirectory.appendingPathComponent("snapshot-\(UUID().uuidString).zip")
                            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                            try? FileManager.default.removeItem(at: sourceURL)
                            DispatchQueue.main.async {
                                completion(true, destinationURL, detail)
                            }
                            return
                        }
                    } else {
                        let ext = sourceURL.pathExtension.isEmpty ? "bin" : sourceURL.pathExtension
                        let destinationURL = destinationDirectory.appendingPathComponent("snapshot-\(UUID().uuidString).\(ext)")
                        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                        try? FileManager.default.removeItem(at: sourceURL)
                        DispatchQueue.main.async {
                            completion(true, destinationURL, detail)
                        }
                        return
                    }
                } catch {
                    DispatchQueue.main.async {
                        completion(false, nil, "The read completed, but its snapshot could not be saved: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// Reads a remote folder through the existing Airlift snapshot route and
    /// returns its ZIP bytes to a feature-specific caller.
    func readRemoteFolderArchive(
        path: String,
        logLabel: String,
        feature: String = "dialer",
        completion: @escaping (Data?) -> Void
    ) {
        let effectiveFeature = feature.isEmpty ? "dialer" : feature
        guard airliftFeatureReady() else {
            appendFeatureLog(effectiveFeature, "Read blocked: LocalDevVPN and pairing are required")
            completion(nil)
            return
        }
        guard !readRunning, !standardReadInProgress, activeRemoteImageReadCount == 0,
              !passcodeFlashRunning, activeRemoteFolderArchiveCompletion == nil else {
            appendFeatureLog(effectiveFeature, "Read blocked: another Airlift read/write is running")
            completion(nil)
            return
        }
        activeRemoteFolderArchiveCompletion = completion
        let message = effectiveFeature == "dialer"
            ? "Reading current keypad assets from \(path)"
            : "Reading \(logLabel) from \(path)"
        appendFeatureLog(effectiveFeature, message)
        runRemoteRead(
            kind: .folder,
            targetOverride: path,
            returningFolderArchiveForQueuedRead: true,
            featureLogPrefix: effectiveFeature
        )
    }

    /// Card-artwork wrapper retained for the Wallet editor's existing call sites.
    func readRemoteImageFile(path: String, completion: @escaping (Data?) -> Void) {
        enqueueRemoteFileRead(paths: [path], logLabel: "card artwork", completion: completion)
    }

    /// Reads the preferred artwork path and silently tries the fallback path if
    /// the first export fails or does not contain decodable image data. Both paths
    /// are handled as one queued operation and produce one pair of feature-log lines.
    func readRemoteImageFile(
        preferredPath: String,
        fallbackPath: String,
        completion: @escaping (Data?) -> Void
    ) {
        enqueueRemoteFileRead(
            paths: [preferredPath, fallbackPath],
            logLabel: "card artwork",
            completion: completion
        )
    }

    private func enqueueRemoteFileRead(
        paths: [String],
        logLabel: String,
        completion: @escaping (Data?) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                completion(nil)
                return
            }
            let nonEmptyPaths = paths.filter { !$0.isEmpty }
            guard !nonEmptyPaths.isEmpty else {
                completion(nil)
                return
            }
            self.pendingRemoteImageReads.append((paths: nonEmptyPaths, logLabel: logLabel, completion: completion))
            self.startNextRemoteImageRead()
        }
    }

    private static func performRemoteImageRead(
        pairingPath: String,
        targetPath: String
    ) -> (rc: Int32, contents: Data?, error: String?) {
        var outJSON: UnsafeMutablePointer<CChar>? = nil
        var outError: UnsafeMutablePointer<CChar>? = nil
        let rc = pairingPath.withCString { pairingCString in
            targetPath.withCString { targetCString in
                al_exploit_read_file(pairingCString, targetCString, nil, nil, &outJSON, &outError)
            }
        }
        let jsonString = outJSON.flatMap { pointer -> String? in
            let value = String(cString: pointer)
            al_string_free(pointer)
            return value
        }
        let errorString = outError.flatMap { pointer -> String? in
            let value = String(cString: pointer)
            al_string_free(pointer)
            return value
        }

        var contents: Data?
        var exportedPath: String?
        if rc == 0,
           let jsonString,
           let jsonData = jsonString.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let localPath = object["localPath"] as? String,
           !localPath.isEmpty {
            exportedPath = localPath
            contents = try? Data(contentsOf: URL(fileURLWithPath: localPath))
        }
        if let exportedPath {
            try? FileManager.default.removeItem(atPath: exportedPath)
        }
        return (rc, contents, errorString)
    }

    private func startNextRemoteImageRead() {
        guard !standardReadInProgress else { return }

        while activeRemoteImageReadCount < maxConcurrentRemoteImageReads,
              !pendingRemoteImageReads.isEmpty {
            let request = pendingRemoteImageReads.removeFirst()
            let normalizedRequestPaths = request.paths.map(Self.normalizedRemotePath)
            guard let normalizedRequestPath = normalizedRequestPaths.first else {
                request.completion(nil)
                continue
            }
            guard airliftFeatureReady() else {
                appendLog("[read] \(request.logLabel) read blocked: LocalDevVPN + pairing are required")
                request.completion(nil)
                continue
            }
            let pairingPath = pairingFilePath()
            guard FileManager.default.fileExists(atPath: pairingPath) else {
                appendLog("[read] \(request.logLabel) read blocked: pairing file is missing")
                request.completion(nil)
                continue
            }

            activeRemoteImageReadCount += 1
            readRunning = true
            // Log the preferred path only. The fallback is an internal retry within
            // this same operation, so the visible log remains one read + one result.
            appendFeatureLog("cards", "Reading \(request.logLabel): \(normalizedRequestPath)")
            beginFeatureOperationLogScope()

            Task.detached { [weak self] in
                var contents: Data?
                var finalError: String?
                var finalRC: Int32 = -1

                for targetPath in normalizedRequestPaths {
                    let result = Self.performRemoteImageRead(pairingPath: pairingPath, targetPath: targetPath)
                    finalRC = result.rc
                    finalError = result.error

                    if let data = result.contents, UIImage(data: data) != nil {
                        contents = data
                        break
                    }
                    if result.rc == 0, result.contents != nil {
                        finalError = "Exported data is not a valid image"
                    }
                }

                await MainActor.run {
                    guard let self else {
                        request.completion(nil)
                        return
                    }
                    self.endFeatureOperationLogScope()
                    self.activeRemoteImageReadCount = max(0, self.activeRemoteImageReadCount - 1)
                    self.readRunning = self.standardReadInProgress || self.activeRemoteImageReadCount > 0
                    if let contents {
                        self.appendFeatureLog("cards", "Read succeeded (\(contents.count) bytes)")
                        request.completion(contents)
                    } else {
                        self.appendFeatureLog("cards", "Read failed: \(finalError ?? "no exported file (rc=\(finalRC))")")
                        request.completion(nil)
                    }
                    self.startNextRemoteImageRead()
                }
            }
        }
    }

    /// Returns the number of uncompressed bytes represented by a successful
    /// Airlift export. Folder reads are ZIP snapshots, so use each entry's
    /// uncompressed size rather than the compressed archive file size.
    private static func uncompressedReadSize(at path: String, kind: ReadKind) -> Int64? {
        let url = URL(fileURLWithPath: path)
        if kind == .file {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber else { return nil }
            return size.int64Value
        }

        guard let archive = try? Archive(url: url, accessMode: .read) else { return nil }
        var total: Int64 = 0
        for entry in archive {
            let entrySize = Int64(entry.uncompressedSize)
            let (nextTotal, overflow) = total.addingReportingOverflow(entrySize)
            guard !overflow else { return nil }
            total = nextTotal
        }
        return total
    }

    private func runRemoteRead(
        kind: ReadKind,
        targetOverride: String? = nil,
        afcOnly: Bool = false,
        importingCurrentPasscodeKeys: Bool = false,
        returningFileDataForQueuedRead: Bool = false,
        returningFolderArchiveForQueuedRead: Bool = false,
        featureLogPrefix: String? = nil,
        suppressOperationLogs: Bool = false,
        dedicatedSnapshot: Bool = false,
        onCompletion: ((Bool, ReadKind, URL?, String) -> Void)? = nil
    ) {
        let effectiveFeatureLogPrefix = featureLogPrefix ?? (importingCurrentPasscodeKeys ? "passcode" : nil)
        let shouldSuppressOperationLogs = suppressOperationLogs || effectiveFeatureLogPrefix != nil
        let updatesAirliftStatus = effectiveFeatureLogPrefix == nil
            && !importingCurrentPasscodeKeys
            && !returningFileDataForQueuedRead
            && !returningFolderArchiveForQueuedRead
            && !dedicatedSnapshot
        let pairingPath = pairingFilePath()
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            if !dedicatedSnapshot {
                readResult = "No pairing file"
            }
            if updatesAirliftStatus {
                lastReadSucceeded = false
                lastReadFileCount = nil
                lastReadTotalSize = nil
            }
            if let effectiveFeatureLogPrefix { appendFeatureLog(effectiveFeatureLogPrefix, "Read blocked: pairing file is missing") }
            onCompletion?(false, kind, nil, "Pairing file is missing")
            if returningFileDataForQueuedRead {
                let completion = activeRemoteImageReadCompletion
                activeRemoteImageReadCompletion = nil
                completion?(nil)
                startNextRemoteImageRead()
            }
            if returningFolderArchiveForQueuedRead {
                let completion = activeRemoteFolderArchiveCompletion
                activeRemoteFolderArchiveCompletion = nil
                completion?(nil)
            }
            return
        }
        let remote = Self.normalizedRemotePath(targetOverride ?? readTarget)
        guard !remote.isEmpty else {
            if !dedicatedSnapshot {
                readResult = "Enter a remote path"
            }
            if updatesAirliftStatus {
                lastReadSucceeded = false
                lastReadFileCount = nil
                lastReadTotalSize = nil
            }
            if let effectiveFeatureLogPrefix { appendFeatureLog(effectiveFeatureLogPrefix, "Read blocked: target path is empty") }
            onCompletion?(false, kind, nil, "Enter a target path")
            if returningFileDataForQueuedRead {
                let completion = activeRemoteImageReadCompletion
                activeRemoteImageReadCompletion = nil
                completion?(nil)
                startNextRemoteImageRead()
            }
            if returningFolderArchiveForQueuedRead {
                let completion = activeRemoteFolderArchiveCompletion
                activeRemoteFolderArchiveCompletion = nil
                completion?(nil)
            }
            return
        }
        if readRunning {
            if let effectiveFeatureLogPrefix { appendFeatureLog(effectiveFeatureLogPrefix, "Read blocked: another Airlift operation is running") }
            onCompletion?(false, kind, nil, "Another Airlift operation is running")
            if returningFolderArchiveForQueuedRead {
                let completion = activeRemoteFolderArchiveCompletion
                activeRemoteFolderArchiveCompletion = nil
                completion?(nil)
            }
            return
        }
        standardReadInProgress = true
        if updatesAirliftStatus {
            lastReadSucceeded = nil
            lastReadFileCount = nil
            lastReadTotalSize = nil
        }

        if !importingCurrentPasscodeKeys && !returningFileDataForQueuedRead && !returningFolderArchiveForQueuedRead && !dedicatedSnapshot {
            if let old = readExportPath { removeReadSnapshot(atPath: old) }
            if let old = readViewLocalPath, old != readExportPath { removeReadSnapshot(atPath: old) }
            readViewLocalPath = nil
            readViewRemotePath = nil
            readExportPath = nil
        }
        readRunning = true
        if !returningFileDataForQueuedRead && !returningFolderArchiveForQueuedRead && !dedicatedSnapshot {
            readResult = kind == .file ? "Reading…" : "Reading directory…"
        }
        if let effectiveFeatureLogPrefix {
            appendFeatureLog(effectiveFeatureLogPrefix, "Reading target: \(remote) (\(kind.rawValue.lowercased()))")
            beginFeatureOperationLogScope()
        } else if suppressOperationLogs {
            beginFeatureOperationLogScope()
        } else {
            appendLog("[read] target=\(remote) kind=\(kind.rawValue.lowercased())")
        }

        Task.detached { [weak self] in
            var outJSON: UnsafeMutablePointer<CChar>? = nil
            var outError: UnsafeMutablePointer<CChar>? = nil
            let rc: Int32 = pairingPath.withCString { pc in
                remote.withCString { tc in
                    if afcOnly {
                        switch kind {
                        case .file:
                            return al_exploit_read_afc_only_file(pc, tc, nil, nil, &outJSON, &outError)
                        case .folder:
                            return al_exploit_read_afc_only_folder(pc, tc, nil, nil, &outJSON, &outError)
                        }
                    }
                    switch kind {
                    case .file:
                        return al_exploit_read_file(pc, tc, nil, nil, &outJSON, &outError)
                    case .folder:
                        return al_exploit_read_folder(pc, tc, nil, nil, &outJSON, &outError)
                    }
                }
            }
            let jsonString = outJSON.flatMap { p -> String? in
                let s = String(cString: p); al_string_free(p); return s
            }
            let errorString = outError.flatMap { p -> String? in
                let s = String(cString: p); al_string_free(p); return s
            }

            var display = ""
            var logSummary = ""
            var exportedPath: String? = nil
            var loadedCurrentPasscodeTheme: ErosionPasscodeTheme? = nil
            var loadedRemoteFileData: Data? = nil
            var loadedRemoteFolderArchive: Data? = nil
            var resultingFileCount: Int? = nil
            var resultingReadSize: Int64? = nil
            // Detailed recovery warnings belong only to the experimental
            // Data/Application container reader. Keep the public UI for all
            // other paths consistent with the original reader.
            let normalizedRemote = remote.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let isApplicationDataContainerTarget = normalizedRemote == "var/mobile/Containers/Data/Application"
                || normalizedRemote.hasPrefix("var/mobile/Containers/Data/Application/")
            if rc == 0, let jsonString,
               let jsonData = jsonString.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                let localPath = obj["localPath"] as? String
                let localRecoveryPath = obj["localRecoveryPath"] as? String
                let recoveryPath = obj["recoveryPath"] as? String
                let restoreHandoff = obj["restoreHandoffCompleted"] as? Bool ?? true
                let restoreConfirmed = obj["restoreConfirmed"] as? Bool ?? true
                let restoreWarning = obj["restoreWarning"] as? String
                let restoreError = obj["restoreError"] as? String
                let count = obj["fileCount"] as? Int ?? 0
                resultingFileCount = obj["fileCount"] as? Int
                let isPartialFolderResult = obj["partial"] as? Bool == true
                // If ZIP creation failed, ordinary folder reads keep the
                // extracted local tree. It is still useful output and must not
                // be discarded just because packaging the temporary ZIP failed.
                let localFolderTreePath = kind == .folder && !isApplicationDataContainerTarget
                    ? localRecoveryPath
                    : nil
                let candidateLocalPath = localPath ?? localFolderTreePath

                if let candidateLocalPath, !candidateLocalPath.isEmpty,
                   FileManager.default.fileExists(atPath: candidateLocalPath) {
                    exportedPath = candidateLocalPath
                    if updatesAirliftStatus {
                        resultingReadSize = Self.uncompressedReadSize(at: candidateLocalPath, kind: kind)
                    }
                    if importingCurrentPasscodeKeys && kind == .folder {
                        loadedCurrentPasscodeTheme = ErosionPasscodeThemeReader.inspectTelephonyFolderArchive(
                            at: URL(fileURLWithPath: candidateLocalPath)
                        )
                        if let loadedCurrentPasscodeTheme {
                            display = "Current keys loaded — \(loadedCurrentPasscodeTheme.keys.count)/10"
                        } else {
                            display = "Directory was read, but no valid passcode key images were found."
                        }
                    } else if returningFolderArchiveForQueuedRead && kind == .folder
                                && (!isApplicationDataContainerTarget
                                    || (restoreHandoff && restoreConfirmed && obj["partial"] as? Bool != true)) {
                        loadedRemoteFolderArchive = try? Data(contentsOf: URL(fileURLWithPath: candidateLocalPath))
                        if let loadedRemoteFolderArchive {
                            display = "Directory archive ready — \(loadedRemoteFolderArchive.count) bytes"
                        } else {
                            display = "Directory snapshot was created, but its ZIP could not be opened."
                        }
                    } else if kind == .file, let data = try? Data(contentsOf: URL(fileURLWithPath: candidateLocalPath)) {
                        if !returningFileDataForQueuedRead { resultingFileCount = resultingFileCount ?? 1 }
                        if returningFileDataForQueuedRead {
                            loadedRemoteFileData = data
                            display = "Artwork file read OK — \(data.count) bytes"
                        } else {
                            let sha256 = (obj["sha256"] as? String) ?? "?"
                            let filename = URL(fileURLWithPath: remote).lastPathComponent
                            display = "Read OK — \(data.count) bytes\nSHA256: \(sha256)"
                            logSummary = "Read OK: \(filename) — \(data.count) bytes | SHA256: \(sha256)"
                        }
                    } else if importingCurrentPasscodeKeys {
                        // The current-key import result was set above.
                    } else if isApplicationDataContainerTarget && !restoreHandoff {
                        display = "SAFETY STOP — read snapshot saved, but the original directory was NOT confirmed restored. Do not open the target app until recovery is resolved.\nFiles: \(count)\nRecovery staging: \(recoveryPath ?? "path not returned; inspect the Airlift log")\nRestore error: \(restoreError ?? "unknown")\nZIP: \(candidateLocalPath)"
                    } else if isApplicationDataContainerTarget && (obj["partial"] as? Bool == true || !restoreConfirmed) {
                        let errors = obj["subdirectoryErrors"] as? [String: Any] ?? [:]
                        let warnings = obj["restoreWarnings"] as? [String: Any] ?? [:]
                        var details = errors.keys.sorted().map { "Incomplete: \($0)" }
                        details.append(contentsOf: warnings.keys.sorted().map { "Restore not directly verified: \($0)" })
                        if let restoreWarning, !restoreWarning.isEmpty { details.append(restoreWarning) }
                        if let exportError = obj["exportError"] as? String, !exportError.isEmpty { details.append(exportError) }
                        let detailText = details.isEmpty ? (restoreWarning ?? "see log") : details.joined(separator: "\n")
                        display = "Directory read PARTIAL — \(count) file(s)\n\(detailText)\n\(candidateLocalPath)"
                        logSummary = "Directory read PARTIAL: \(remote) — \(count) file(s)"
                    } else if isPartialFolderResult || localPath == nil {
                        let warning = (obj["exportError"] as? String)
                            ?? restoreWarning
                            ?? "Some directory entries could not be read."
                        display = "Directory read PARTIAL — \(count) file(s)\n\(warning)\n\(candidateLocalPath)"
                        logSummary = "Directory read PARTIAL: \(remote) — \(count) file(s)"
                    } else {
                        display = "Directory read OK — \(count) file(s)\n\(localPath)"
                        logSummary = "Directory read OK: \(remote) — \(count) file(s)"
                    }
                } else if isApplicationDataContainerTarget && !restoreHandoff {
                    display = "SAFETY STOP — original directory restoration was NOT confirmed. Do not open the target app until recovery is resolved.\nRecovery staging: \(recoveryPath ?? "path not returned; inspect the Airlift log")\nRestore error: \(restoreError ?? "unknown")\nLocal partial files: \(localRecoveryPath ?? "not available")"
                } else if isApplicationDataContainerTarget {
                    let exportError = obj["exportError"] as? String ?? "The ZIP snapshot could not be completed."
                    display = "Directory read PARTIAL — \(count) file(s)\n\(restoreWarning ?? exportError)\nLocal partial files: \(localRecoveryPath ?? "not available")"
                } else {
                    display = errorString ?? jsonString ?? "Read failed (rc=\(rc))"
                }
            } else {
                display = errorString ?? jsonString ?? "Read failed (rc=\(rc))"
            }
            if logSummary.isEmpty && !display.isEmpty { logSummary = display.components(separatedBy: "\n").first ?? display }

            if !importingCurrentPasscodeKeys,
               !returningFileDataForQueuedRead,
               !returningFolderArchiveForQueuedRead,
               !dedicatedSnapshot,
               kind == .file,
               let originalExport = exportedPath,
               let namedExport = Self.moveReadExportToRemoteFilename(localPath: originalExport, remotePath: remote) {
                exportedPath = namedExport
            }

            if (importingCurrentPasscodeKeys || returningFileDataForQueuedRead || returningFolderArchiveForQueuedRead), let exportedPath {
                // These consumers read the exported snapshot immediately; avoid
                // leaving temporary duplicates in the app's shared file-browser state.
                try? FileManager.default.removeItem(atPath: exportedPath)
            }

            await MainActor.run {
                self?.standardReadInProgress = false
                self?.readRunning = (self?.activeRemoteImageReadCount ?? 0) > 0
                if !returningFileDataForQueuedRead && !returningFolderArchiveForQueuedRead && !dedicatedSnapshot {
                    self?.readResult = logSummary.isEmpty ? display : logSummary
                }
                if !importingCurrentPasscodeKeys && !returningFileDataForQueuedRead && !returningFolderArchiveForQueuedRead && !dedicatedSnapshot {
                    self?.readExportPath = exportedPath
                    if rc == 0, let exportedPath {
                        self?.readViewRemotePath = remote
                        self?.readViewIsFolder = (kind == .folder)
                        if kind == .file { self?.readViewLocalPath = exportedPath }
                    }
                }
                let isComplete = rc == 0 && exportedPath != nil && !display.hasPrefix("SAFETY STOP")
                if updatesAirliftStatus {
                    let statusSucceeded = isComplete
                        && !display.hasPrefix("Directory read PARTIAL")
                        && (display.hasPrefix("Read OK") || display.hasPrefix("Directory read OK"))
                    self?.lastReadSucceeded = statusSucceeded
                    self?.lastReadFileCount = statusSucceeded ? resultingFileCount : nil
                    self?.lastReadTotalSize = statusSucceeded ? resultingReadSize : nil
                }
                if let effectiveFeatureLogPrefix {
                    self?.endFeatureOperationLogScope()
                    self?.appendFeatureLog(effectiveFeatureLogPrefix, isComplete ? "Read succeeded: \(remote)" : "Read failed: \(display)")
                } else if !shouldSuppressOperationLogs && !dedicatedSnapshot {
                    self?.appendLog(rc == 0
                        ? "[read] \(logSummary.isEmpty ? "success" : logSummary)"
                        : "[read] failed: \(logSummary.isEmpty ? display : logSummary)")
                }
                if shouldSuppressOperationLogs && effectiveFeatureLogPrefix == nil {
                    self?.endFeatureOperationLogScope()
                }
                if importingCurrentPasscodeKeys {
                    if rc == 0, let loadedCurrentPasscodeTheme {
                        self?.installPasscodeTheme(loadedCurrentPasscodeTheme)
                        self?.appendPasscodeLog("Loaded current keys: \(loadedCurrentPasscodeTheme.keys.count)/10")
                    } else {
                        self?.appendPasscodeLog("Failed to get current keys: \(display)")
                    }
                }
                if let onCompletion {
                    onCompletion(isComplete, kind, exportedPath.map { URL(fileURLWithPath: $0) }, display)
                }
                if returningFileDataForQueuedRead {
                    let completion = self?.activeRemoteImageReadCompletion
                    self?.activeRemoteImageReadCompletion = nil
                    completion?(rc == 0 ? loadedRemoteFileData : nil)
                }
                if returningFolderArchiveForQueuedRead {
                    let completion = self?.activeRemoteFolderArchiveCompletion
                    self?.activeRemoteFolderArchiveCompletion = nil
                    completion?(rc == 0 ? loadedRemoteFolderArchive : nil)
                }
                self?.startNextRemoteImageRead()
            }
        }
    }


    /// Read a file or directory without modifying the remote object. It first
    /// tries the file primitive and retries the folder primitive if that fails.
    /// `keepSnapshot` is false for Grant Access (probe only) and true for Export.
    func readRemotePathAutomatically(
        path: String,
        feature: String = "file-operations",
        keepSnapshot: Bool,
        completion: @escaping (Bool, ReadKind?, URL?, String) -> Void
    ) {
        let remote = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard remote.hasPrefix("/"), !remote.isEmpty else {
            appendFeatureLog(feature, "Blocked: enter an absolute target path")
            completion(false, nil, nil, "Enter an absolute target path")
            return
        }
        guard airliftFeatureReady() else {
            appendFeatureLog(feature, "Blocked: LocalDevVPN and pairing are required")
            completion(false, nil, nil, "Enable LocalDevVPN and import a valid pairing file")
            return
        }
        guard !readRunning, !standardReadInProgress, activeRemoteImageReadCount == 0, !passcodeFlashRunning else {
            appendFeatureLog(feature, "Blocked: another Airlift operation is running")
            completion(false, nil, nil, "Another Airlift operation is running")
            return
        }

        runRemoteRead(kind: .file, targetOverride: remote, featureLogPrefix: feature) { [weak self] success, resolvedKind, url, detail in
            guard let self else { completion(false, nil, nil, "Airlift is unavailable"); return }
            if success, let url {
                self.finishAutomaticPathRead(success: true, kind: resolvedKind, url: url, detail: detail, feature: feature, keepSnapshot: keepSnapshot, completion: completion)
                return
            }

            self.appendFeatureLog(feature, "File read did not succeed; trying the directory reader")
            self.runRemoteRead(kind: .folder, targetOverride: remote, featureLogPrefix: feature) { [weak self] folderSuccess, folderKind, folderURL, folderDetail in
                guard let self else { completion(false, nil, nil, "Airlift is unavailable"); return }
                guard folderSuccess, let folderURL else {
                    self.finishAutomaticPathRead(success: false, kind: nil, url: nil, detail: folderDetail.isEmpty ? detail : folderDetail, feature: feature, keepSnapshot: false, completion: completion)
                    return
                }
                self.finishAutomaticPathRead(success: true, kind: folderKind, url: folderURL, detail: folderDetail, feature: feature, keepSnapshot: keepSnapshot, completion: completion)
            }
        }
    }

    private func finishAutomaticPathRead(
        success: Bool,
        kind: ReadKind?,
        url: URL?,
        detail: String,
        feature: String,
        keepSnapshot: Bool,
        completion: @escaping (Bool, ReadKind?, URL?, String) -> Void
    ) {
        var resultURL = url
        if success, !keepSnapshot, let url {
            removeReadSnapshot(atPath: url.path)
            if readExportPath == url.path { readExportPath = nil }
            if readViewLocalPath == url.path { readViewLocalPath = nil }
            readViewRemotePath = nil
            resultURL = nil
        }
        appendFeatureLog(feature, success ? "Target check succeeded: \(kind?.rawValue.lowercased() ?? "object")" : "Target check failed: \(detail)")
        completion(success, kind, resultURL, detail)
    }

    static func remotePath(remoteRoot: String, localRoot: String, localURL: URL) -> String {
        let rootURL = URL(fileURLWithPath: localRoot, isDirectory: true).standardizedFileURL
        let fileURL = localURL.standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard fileURL.path.hasPrefix(rootPath) else {
            return URL(fileURLWithPath: remoteRoot, isDirectory: true).appendingPathComponent(fileURL.lastPathComponent).path
        }
        let relative = String(fileURL.path.dropFirst(rootPath.count))
        return URL(fileURLWithPath: remoteRoot, isDirectory: true).appendingPathComponent(relative).path
    }

    func openReadView() {
        guard let exported = readExportPath else { return }
        if readViewIsFolder {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("erosion_airlift_view_\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try FileManager.default.unzipItem(at: URL(fileURLWithPath: exported), to: destination)
                readViewLocalPath = destination.path
                showReadView = true
            } catch {
                readResult = "Could not open directory snapshot: \(error.localizedDescription)"
                try? FileManager.default.removeItem(at: destination)
            }
        } else {
            readViewLocalPath = exported
            showReadView = true
        }
    }

    /// True only when the Airlift transport has both required pieces for a
    /// remote File Browser mutation: LocalDevVPN and a valid pairing file.
    func fileBrowserWriteReady() -> Bool {
        NetworkStatus.loopbackVPNUp() && hasPairing()
    }

    /// Writes the flat contents of a local directory to a remote directory in one Airlift operation.
    /// Used by image features that need to replace several assets efficiently.
    func writeDirectoryBatch(localDirectoryURL: URL, remotePath: String, logFeature: String) async -> Bool {
        let remotePath = Self.normalizedRemotePath(remotePath)
        guard fileBrowserWriteReady() else {
            appendFeatureLog(logFeature, "Batch write blocked: LocalDevVPN and pairing are required")
            return false
        }
        guard remotePath.hasPrefix("/") else {
            appendFeatureLog(logFeature, "Batch write blocked: invalid target path \(remotePath)")
            return false
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: localDirectoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            appendFeatureLog(logFeature, "Batch write blocked: local staging directory is missing")
            return false
        }
        let fileCount = ((try? FileManager.default.contentsOfDirectory(at: localDirectoryURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.first != "." }
            .count
        guard fileCount > 0 else {
            appendFeatureLog(logFeature, "Batch write blocked: no staged files were found")
            return false
        }

        let pairing = pairingFilePath()
        let sourcePath = localDirectoryURL.path
        beginFeatureOperationLogScope()
        appendFeatureLog(logFeature, "Writing \(fileCount) file(s) to \(remotePath) in one directory batch")

        let result: (Bool, String?) = await withCheckedContinuation { continuation in
            fileMutationQueue.async {
                var error: UnsafeMutablePointer<CChar>? = nil
                let rc = pairing.withCString { pc in
                    sourcePath.withCString { sc in
                        remotePath.withCString { tc in
                            al_exploit_write_dir(pc, sc, tc, airliftFileLogCallback, nil, &error)
                        }
                    }
                }
                let message = error.map { ptr -> String in
                    let value = String(cString: ptr)
                    al_string_free(ptr)
                    return value
                }
                continuation.resume(returning: (rc == 0, message))
            }
        }

        endFeatureOperationLogScope()
        if let message = result.1, !message.isEmpty {
            appendFeatureLog(logFeature, message)
        }
        appendFeatureLog(logFeature, result.0
            ? "Batch write succeeded: \(fileCount) file(s) to \(remotePath)"
            : "Batch write failed: \(remotePath)")
        return result.0
    }

    /// Writes the edited local snapshot directly back to the exact remote file.
    /// This is a remote operation: it never reports success merely because the
    /// local snapshot was changed.
    func writeBack(localURL: URL, remotePath: String, logFeature: String? = nil) async -> Bool {
        let remotePath = Self.normalizedRemotePath(remotePath)
        guard fileBrowserWriteReady() else {
            if let logFeature { appendFeatureLog(logFeature, "Write blocked: LocalDevVPN and pairing are required") }
            else { appendLog("[write] blocked: LocalDevVPN + pairing are both required") }
            return false
        }
        guard remotePath.hasPrefix("/") else {
            if let logFeature { appendFeatureLog(logFeature, "Write blocked: invalid target path \(remotePath)") }
            else { appendLog("[write] blocked: invalid remote path \(remotePath)") }
            return false
        }
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            if let logFeature { appendFeatureLog(logFeature, "Write blocked: imported source file is missing") }
            else { appendLog("[write] local source missing: \(localURL.path)") }
            return false
        }

        let pairing = pairingFilePath()
        let sourcePath = localURL.path
        if let logFeature {
            beginFeatureOperationLogScope()
            appendFeatureLog(logFeature, "Writing imported file to \(remotePath)")
        } else {
            appendLog("[write] exact target=\(remotePath)")
        }

        let result: (Bool, String?) = await withCheckedContinuation { continuation in
            fileMutationQueue.async {
                var error: UnsafeMutablePointer<CChar>? = nil
                let rc = pairing.withCString { pc in
                    sourcePath.withCString { sc in
                        remotePath.withCString { tc in
                            al_exploit_write_file(
                                pc,
                                sc,
                                tc,
                                airliftFileLogCallback,
                                nil,
                                &error
                            )
                        }
                    }
                }
                let message = error.map { ptr -> String in
                    let value = String(cString: ptr)
                    al_string_free(ptr)
                    return value
                }
                continuation.resume(returning: (rc == 0, message))
            }
        }

        if let logFeature {
            endFeatureOperationLogScope()
            if let message = result.1, !message.isEmpty { appendFeatureLog(logFeature, message) }
            appendFeatureLog(logFeature, result.0 ? "Write succeeded: \(remotePath)" : "Write failed: \(remotePath)")
        } else {
            if let message = result.1, !message.isEmpty { appendLog("[write] \(message)") }
            appendLog(result.0 ? "[write] success: \(remotePath)" : "[write] failed: \(remotePath)")
        }
        return result.0
    }

    /// Removes exactly one remote file or directory. The operation is performed
    /// before the local snapshot item is deleted by the File Browser.
    func removeRemotePath(_ remotePath: String, logFeature: String? = nil) async -> Bool {
        let remotePath = Self.normalizedRemotePath(remotePath)
        guard fileBrowserWriteReady() else {
            if let logFeature { appendFeatureLog(logFeature, "Delete blocked: LocalDevVPN and pairing are required") }
            else { appendLog("[delete] blocked: LocalDevVPN + pairing are both required") }
            return false
        }
        guard remotePath.hasPrefix("/") else {
            if let logFeature { appendFeatureLog(logFeature, "Delete blocked: invalid target path \(remotePath)") }
            else { appendLog("[delete] blocked: invalid remote path \(remotePath)") }
            return false
        }

        let pairing = pairingFilePath()
        if let logFeature {
            beginFeatureOperationLogScope()
            appendFeatureLog(logFeature, "Deleting remote path \(remotePath)")
        } else {
            appendLog("[delete] exact target=\(remotePath)")
        }
        let result: (Bool, String?) = await withCheckedContinuation { continuation in
            fileMutationQueue.async {
                var error: UnsafeMutablePointer<CChar>? = nil
                let rc = pairing.withCString { pc in
                    remotePath.withCString { tc in
                        al_exploit_remove_path(
                            pc,
                            tc,
                            airliftFileLogCallback,
                            nil,
                            &error
                        )
                    }
                }
                let message = error.map { ptr -> String in
                    let value = String(cString: ptr)
                    al_string_free(ptr)
                    return value
                }
                continuation.resume(returning: (rc == 0, message))
            }
        }

        if let logFeature {
            endFeatureOperationLogScope()
            if let message = result.1, !message.isEmpty { appendFeatureLog(logFeature, message) }
            appendFeatureLog(logFeature, result.0 ? "Delete succeeded: \(remotePath)" : "Delete failed: \(remotePath)")
        } else {
            if let message = result.1, !message.isEmpty { appendLog("[delete] \(message)") }
            appendLog(result.0 ? "[delete] success: \(remotePath)" : "[delete] failed: \(remotePath)")
        }
        return result.0
    }

    /// Resets the Dialer Themer cache through Airlift. The cache is inside the
    /// MobilePhone data container on iOS 27; a local mpContainerPath is not a
    /// valid device path in compatibility mode.
    func resetDialerKeyCache() async -> Bool {
        guard fileBrowserWriteReady() else {
            appendFeatureLog("dialer", "Reset blocked: LocalDevVPN and pairing are required")
            return false
        }

        let pairing = pairingFilePath()
        appendFeatureLog("dialer", "Resolving MobilePhone data container for keypad reset")

        let lookup: (Int32, String?, String?) = await withCheckedContinuation { continuation in
            fileMutationQueue.async {
                var containerPointer: UnsafeMutablePointer<CChar>?
                var errorPointer: UnsafeMutablePointer<CChar>?
                let rc = pairing.withCString { pairingCString in
                    "com.apple.mobilephone".withCString { bundleCString in
                        al_find_app_container(
                            pairingCString,
                            bundleCString,
                            airliftFileLogCallback,
                            nil,
                            &containerPointer,
                            &errorPointer
                        )
                    }
                }
                let container = containerPointer.map { pointer -> String in
                    let value = String(cString: pointer)
                    al_string_free(pointer)
                    return value
                }
                let error = errorPointer.map { pointer -> String in
                    let value = String(cString: pointer)
                    al_string_free(pointer)
                    return value
                }
                continuation.resume(returning: (rc, container, error))
            }
        }

        guard lookup.0 == 0, let container = lookup.1, !container.isEmpty else {
            appendFeatureLog("dialer", "Could not resolve MobilePhone container: \(lookup.2 ?? "unknown error")")
            return false
        }

        let target = Self.normalizedRemotePath(URL(fileURLWithPath: container)
            .appendingPathComponent("Library/Caches/TelephonyUI-10", isDirectory: true)
            .path)
        appendFeatureLog("dialer", "Resetting keypad cache at \(target)")

        let removal: (Int32, String?) = await withCheckedContinuation { continuation in
            fileMutationQueue.async {
                var errorPointer: UnsafeMutablePointer<CChar>?
                let rc = pairing.withCString { pairingCString in
                    target.withCString { targetCString in
                        al_exploit_remove_path(
                            pairingCString,
                            targetCString,
                            airliftFileLogCallback,
                            nil,
                            &errorPointer
                        )
                    }
                }
                let error = errorPointer.map { pointer -> String in
                    let value = String(cString: pointer)
                    al_string_free(pointer)
                    return value
                }
                continuation.resume(returning: (rc, error))
            }
        }

        let removalMessage = removal.1 ?? ""
        let lowerRemovalMessage = removalMessage.lowercased()
        let alreadyAbsent = lowerRemovalMessage.contains("no such file")
            || lowerRemovalMessage.contains("not found")
            || lowerRemovalMessage.contains("objectnotfound")
        guard removal.0 == 0 || alreadyAbsent else {
            appendFeatureLog("dialer", "Failed to remove keypad cache: \(removalMessage.isEmpty ? "remote remove failed" : removalMessage)")
            return false
        }

        // Keep the cache directory present, matching the regular Dialer Themer
        // reset behavior. If it did not exist, this simply creates an empty one.
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("erosion_dialer_reset_\(UUID().uuidString)", isDirectory: true)
        let emptyFolder = stagingRoot.appendingPathComponent("TelephonyUI-10", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
            let recreated = await createRemoteDirectory(localURL: emptyFolder, remotePath: target)
            try? FileManager.default.removeItem(at: stagingRoot)
            if recreated {
                appendFeatureLog("dialer", "Keypad cache reset successfully")
            } else {
                appendFeatureLog("dialer", "Keypad assets were removed, but the empty cache directory could not be restored")
            }
            return recreated
        } catch {
            try? FileManager.default.removeItem(at: stagingRoot)
            appendFeatureLog("dialer", "Failed to stage empty keypad cache: \(error.localizedDescription)")
            return false
        }
    }

    /// Injects a local directory as one exact remote directory. This is also
    /// useful for creating an empty folder because the Airlift folder archive
    /// contains an explicit `payload/` directory entry.
    func createRemoteDirectory(localURL: URL, remotePath: String) async -> Bool {
        let remotePath = Self.normalizedRemotePath(remotePath)
        guard fileBrowserWriteReady() else {
            appendLog("[mkdir] blocked: LocalDevVPN + pairing are both required")
            return false
        }
        let isDirectory = (try? localURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard isDirectory else {
            appendLog("[mkdir] local directory missing: \(localURL.path)")
            return false
        }
        guard remotePath.hasPrefix("/") else {
            appendLog("[mkdir] blocked: invalid remote path \(remotePath)")
            return false
        }

        let remoteURL = URL(fileURLWithPath: remotePath, isDirectory: true)
        let parent = remoteURL.deletingLastPathComponent().path
        let name = remoteURL.lastPathComponent
        let pairing = pairingFilePath()
        let sourcePath = localURL.path

        appendLog("[mkdir] exact target=\(remotePath)")
        let result: (Bool, String?) = await withCheckedContinuation { continuation in
            fileMutationQueue.async {
                var error: UnsafeMutablePointer<CChar>? = nil
                let rc = pairing.withCString { pc in
                    sourcePath.withCString { sc in
                        parent.withCString { tc in
                            name.withCString { nc in
                                al_exploit_inject_folder(
                                    pc,
                                    sc,
                                    tc,
                                    nc,
                                    airliftFileLogCallback,
                                    nil,
                                    &error
                                )
                            }
                        }
                    }
                }
                let message = error.map { ptr -> String in
                    let value = String(cString: ptr)
                    al_string_free(ptr)
                    return value
                }
                continuation.resume(returning: (rc == 0, message))
            }
        }

        if let message = result.1, !message.isEmpty {
            appendLog("[mkdir] \(message)")
        }
        appendLog(result.0 ? "[mkdir] success: \(remotePath)" : "[mkdir] failed: \(remotePath)")
        return result.0
    }

    @discardableResult
    func loadPasscodeTheme(url: URL, logMessages: Bool = true) -> Bool {
        guard let theme = ErosionPasscodeThemeReader.inspect(url: url) else {
            if logMessages {
                appendPasscodeLog("❌ Failed to read .passthm")
            }
            return false
        }
        installPasscodeTheme(theme)
        passcodeFlashLog.removeAll()
        if logMessages {
            appendPasscodeLog("Loaded theme: \(theme.name)")
            appendPasscodeLog("Key images: \(theme.keys.count)/10; assets: \(theme.fileCount)")
        }
        return true
    }

    func clearPasscodeTheme() {
        passcodeTheme = nil
        PasscodeThemeStorage.clear()
        UserDefaults.standard.removeObject(forKey: "erosion.passcodeLibrary.selectedFilename")
        passcodeFlashLog.removeAll()
    }

    /// Clear only the theme being edited, matching Dialer Themer's Clear Keys.
    /// This intentionally does not delete anything from the device.
    func clearPasscodeKeys() {
        passcodeTheme = nil
        PasscodeThemeStorage.clear()
        UserDefaults.standard.removeObject(forKey: "erosion.passcodeLibrary.selectedFilename")
        appendPasscodeLog("Cleared selected passcode keys")
    }

    /// Run the existing general folder-read route against TelephonyUI-10.
    /// The specialized Media and Data/Application paths remain unchanged.
    func getCurrentPasscodeKeys() {
        guard !passcodeFlashRunning, !readRunning else {
            appendPasscodeLog("❌ Another Airlift operation is already running")
            return
        }
        guard airliftFeatureReady() else {
            appendPasscodeLog("❌ LocalDevVPN + pairing are required to get current keys")
            return
        }
        let target = "/var/mobile/Library/Caches/TelephonyUI-10/"
        appendPasscodeLog("Reading current keys from \(target)…")
        runRemoteRead(kind: .folder, targetOverride: target, importingCurrentPasscodeKeys: true)
    }

    private func installPasscodeTheme(_ theme: ErosionPasscodeTheme) {
        passcodeTheme = theme
        PasscodeThemeStorage.save(theme: theme)
    }

    func setPasscodeKeyImage(digit: String, image: UIImage, data: Data) {
        guard let theme = passcodeTheme else {
            let theme = ErosionPasscodeTheme(
                url: FileManager.default.temporaryDirectory,
                name: "Custom Passcode",
                keys: [digit: image],
                rawData: [digit: data],
                fileCount: 1
            )
            installPasscodeTheme(theme)
            appendPasscodeLog("Selected artwork for key \(digit)")
            return
        }
        var keys = theme.keys
        var raw = theme.rawData
        keys[digit] = image
        raw[digit] = data
        let updatedTheme = ErosionPasscodeTheme(
            url: theme.url,
            name: theme.name,
            keys: keys,
            rawData: raw,
            fileCount: max(theme.fileCount, raw.count)
        )
        installPasscodeTheme(updatedTheme)
        appendPasscodeLog("Selected artwork for key \(digit)")
    }

    func flashPasscodeTheme(
        keySize: KPSize = .defSize,
        customWidth: Int = 0,
        customHeight: Int = 0,
        maskKeys: Bool = false
    ) {
        guard !passcodeFlashRunning, let theme = passcodeTheme else { return }
        guard NetworkStatus.loopbackVPNUp() && hasPairing() else {
            appendPasscodeLog("❌ LocalDevVPN + pairing file are required")
            return
        }
        let pairingPath = pairingFilePath()

        clearPasscodeLogBuffer()
        passcodeFlashLog.removeAll()
        passcodeLastApplySucceeded = nil
        passcodeFlashRunning = true
        // Modern iOS passcode artwork is written to TelephonyUI-10.
        // Use the shared prefix detected from InCallService or entered in Settings.
        let selectedPrefix = DialerPasscodePrefix.currentCode
        var rawPayloads: [String: Data] = theme.rawData
        for (digit, image) in theme.keys where rawPayloads[digit] == nil {
            if let data = image.pngData() {
                rawPayloads[digit] = data
            }
        }
        let payloads = rawPayloads.mapValues { data in
            return processPasscodeKeyData(
                data,
                size: keySize,
                customWidth: customWidth,
                customHeight: customHeight,
                mask: maskKeys
            )
        }

        Task.detached { [weak self] in
            guard let self else { return }
            let stage = FileManager.default.temporaryDirectory
                .appendingPathComponent("erosion_passthm_stage_\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)

            // Write only the selected prefix's target artwork pair for each key.
            // Regular and bold are the two existing targets; no blank/no-space or
            // fallback `other-` duplicates are generated.
            let boldSuffixes = ["", "-bold"]

            // Keep the physical key labels stable. Only the configurable filename
            // prefix changes. The zero key
            // has no letter label in TelephonyUI-10, so its middle field is empty.
            let subtexts: [String: String] = [
                "0": "", "1": "", "2": "A B C", "3": "D E F",
                "4": "G H I", "5": "J K L", "6": "M N O",
                "7": "P Q R S", "8": "T U V", "9": "W X Y Z"
            ]

            for (digit, imageData) in payloads {
                let keyLabel = subtexts[digit] ?? ""

                for suffix in boldSuffixes {
                    let filename = "\(selectedPrefix)-\(digit)-\(keyLabel)--white\(suffix).png"
                    try? imageData.write(to: stage.appendingPathComponent(filename))
                }
            }
            try? Data().write(to: stage.appendingPathComponent("_big"))

            let target = "/var/mobile/Library/Caches/TelephonyUI-10"
            await MainActor.run { self.appendPasscodeLog("Writing \(target)…") }
            let allOK = await self.writeDirectory(
                pairingPath: pairingPath,
                source: stage.path,
                target: target
            )
            await MainActor.run {
                self.appendPasscodeLog(allOK ? "✅ Injected \(target)" : "❌ Failed \(target)")
            }

            try? FileManager.default.removeItem(at: stage)
            let finalOK = allOK
            await MainActor.run {
                self.passcodeLastApplySucceeded = finalOK
                self.appendPasscodeLog(finalOK
                    ? "🎉 Passcode theme applied. Lock the device to see it."
                    : "❌ TelephonyUI-10 write failed.")
                self.passcodeFlashRunning = false
            }
        }
    }

    func resetPasscodeKeys() async -> Bool {
        guard !passcodeFlashRunning else {
            appendPasscodeLog("❌ A passcode operation is already running")
            return false
        }
        guard airliftFeatureReady() else {
            appendPasscodeLog("❌ LocalDevVPN + pairing are required to reset keys")
            return false
        }

        passcodeFlashRunning = true
        let target = "/var/mobile/Library/Caches/TelephonyUI-10"
        appendPasscodeLog("Resetting keys in \(target)…")

        let removed = await removeRemotePath(target)
        guard removed else {
            passcodeFlashRunning = false
            appendPasscodeLog("❌ Could not remove \(target)")
            return false
        }

        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("erosion_passcode_reset_\(UUID().uuidString)", isDirectory: true)
        let emptyFolder = stagingRoot.appendingPathComponent("TelephonyUI-10", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
            let recreated = await createRemoteDirectory(localURL: emptyFolder, remotePath: target)
            try? FileManager.default.removeItem(at: stagingRoot)
            passcodeFlashRunning = false
            appendPasscodeLog(recreated
                ? "✅ Reset keys. Empty TelephonyUI-10 directory restored."
                : "❌ Keys were removed, but the empty TelephonyUI-10 directory could not be recreated.")
            return recreated
        } catch {
            try? FileManager.default.removeItem(at: stagingRoot)
            passcodeFlashRunning = false
            appendPasscodeLog("❌ Failed to prepare the reset directory: \(error.localizedDescription)")
            return false
        }
    }

    nonisolated func appendPasscodeLog(_ line: String) {
        if isAirliftCompatibilityMode() {
            appendFeatureLog("passcode", line)
        }
        passcodeLogBufferLock.lock()
        pendingPasscodeLogLines.append(line)
        if pendingPasscodeLogLines.count > 700 {
            pendingPasscodeLogLines.removeFirst(pendingPasscodeLogLines.count - 650)
        }
        let shouldSchedule = !passcodeLogFlushScheduled
        if shouldSchedule { passcodeLogFlushScheduled = true }
        passcodeLogBufferLock.unlock()

        guard shouldSchedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.flushPasscodeLogBuffer()
        }
    }

    @MainActor
    private func flushPasscodeLogBuffer() {
        passcodeLogBufferLock.lock()
        let batch = pendingPasscodeLogLines
        pendingPasscodeLogLines.removeAll(keepingCapacity: true)
        passcodeLogFlushScheduled = false
        let needsAnotherFlush = !pendingPasscodeLogLines.isEmpty
        passcodeLogBufferLock.unlock()

        if !batch.isEmpty {
            passcodeFlashLog.append(contentsOf: batch)
            if passcodeFlashLog.count > 700 {
                passcodeFlashLog.removeFirst(passcodeFlashLog.count - 600)
            }
        }

        if needsAnotherFlush {
            passcodeLogBufferLock.lock()
            if !passcodeLogFlushScheduled { passcodeLogFlushScheduled = true }
            passcodeLogBufferLock.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                self?.flushPasscodeLogBuffer()
            }
        }
    }

    private func clearPasscodeLogBuffer() {
        passcodeLogBufferLock.lock()
        pendingPasscodeLogLines.removeAll()
        passcodeLogFlushScheduled = false
        passcodeLogBufferLock.unlock()
    }

    private func writeDirectory(pairingPath: String, source: String, target: String) async -> Bool {
        let target = Self.normalizedRemotePath(target)
        beginFeatureOperationLogScope()
        let result: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: UnsafeMutablePointer<CChar>?
                let rc = pairingPath.withCString { p in
                    source.withCString { s in
                        target.withCString { t in
                            al_exploit_write_dir(p, s, t, airliftPasscodeLogCallback, nil, &error)
                        }
                    }
                }
                if let error {
                    let message = String(cString: error)
                    al_string_free(error)
                    DispatchQueue.main.async {
                        self.appendPasscodeLog("  \(message)")
                    }
                }
                continuation.resume(returning: rc == 0)
            }
        }
        endFeatureOperationLogScope()
        return result
    }

    func cancelExploit() { /* natsuk1-cancel-v1 */
        appendLog("[exploit] cancel requested")
        state = .done(ok: false, message: "cancelled")
    }

}
