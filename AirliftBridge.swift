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
    AirliftBridge.shared.appendPasscodeLog("  \(String(cString: msg))")
}

struct AirliftAppContainer: Identifiable, Equatable {
    let bundleID: String
    let container: String
    var id: String { bundleID }
}

struct AirliftAppGroup: Identifiable, Equatable {
    /// Legacy UUID leaf from the physical path; never use as the row title.
    let groupID: String
    let groupIDs: [String]
    let container: String
    let sourceApps: [String]
    var id: String { container }
}

struct AirliftAdditionalContainerPath: Identifiable, Equatable {
    let path: String
    let sourceApps: [String]
    var id: String { path }
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
    @Published private(set) var installationProxyInternalDaemonPaths: [AirliftAdditionalContainerPath] = []
    @Published private(set) var installationProxyPluginKitPluginPaths: [AirliftAdditionalContainerPath] = []
    @Published private(set) var internalDaemonAfcPaths: [String] = []
    @Published private(set) var pluginKitPluginAfcPaths: [String] = []
    @Published private(set) var internalDaemonBadQueryPaths: [String] = []
    @Published private(set) var pluginKitPluginBadQueryPaths: [String] = []
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
    @Published var readTarget: String = "/var/mobile/Library/Preferences/com.apple.springboard.plist"
    @Published private(set) var readRunning = false
    @Published private(set) var readResult: String = ""
    @Published private(set) var readExportPath: String? = nil
    @Published var showReadView = false
    @Published private(set) var readViewLocalPath: String? = nil
    @Published private(set) var readViewRemotePath: String? = nil
    @Published private(set) var readViewIsFolder = false
    @Published var readKind: ReadKind = .file

    enum ReadKind: String, CaseIterable, Identifiable {
        case file = "File"
        case folder = "Folder"
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
    private var containerDiagnosticsAutoScannedOnEntry = false

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

    // Passcode writes can produce a burst of FFI log lines. Batch publication so
    // SwiftUI does not redraw the complete editor once for every callback.
    private let passcodeLogBufferLock = NSLock()
    private var pendingPasscodeLogLines: [String] = []
    private var passcodeLogFlushScheduled = false

    private var pendingRemoteImageReads: [(path: String, logLabel: String, completion: (Data?) -> Void)] = []
    private var activeRemoteImageReadCompletion: ((Data?) -> Void)?
    private var activeRemoteImageReadCount = 0
    private var standardReadInProgress = false
    private let maxConcurrentRemoteImageReads = 2

    private init() {
        al_log_init({ _, msg in
            guard let msg = msg else { return }
            let bridge = AirliftBridge.shared
            // Container-probe FFI calls use the same native logger as normal Airlift
            // operations. Keep their diagnostics in the category-specific log views.
            guard !bridge.shouldSuppressContainerScannerLogs else { return }
            let line = String(cString: msg)
            // appendLog is thread-safe and performs its own throttled main-thread
            // publish. Do not dispatch every callback onto the main queue.
            bridge.appendLog(line)
        }, nil)
    }

    nonisolated func appendLog(_ s: String) {
        logBufferLock.lock()
        pendingLogLines.append(s)
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
                self.pairingStatus = ctrl.pairingStatus
                self.pairPIN = ctrl.pairingPIN
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
        installedAppContainers = []
        appScanLog = []
        state = .idle; pairingStatus = ""; pairPIN = nil
    }
    func runExploit() {
        let pairingPath = pairingFilePath()
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            state = .done(ok: false, message: "No pairing file"); return
        }
        state = .running; loggedLines.removeAll(); exploitLog = []
        appendLog("[exploit] path=\(pairingPath) target=\(target)")
        let targetDir = target
        Task.detached {
            var outJson: UnsafeMutablePointer<CChar>? = nil
            var outError: UnsafeMutablePointer<CChar>? = nil
            let rc: Int32 = pairingPath.withCString { pc in
                targetDir.withCString { tc in
                    al_exploit_run(pc, tc, nil, nil, &outJson, &outError)
                }
            }
            let jsonStr = outJson.flatMap { p -> String? in let s = String(cString: p); al_string_free(p); return s }
            let errStr = outError.flatMap { p -> String? in let s = String(cString: p); al_string_free(p); return s }
            await MainActor.run {
                if rc == 0 {
                    let msg = jsonStr ?? "OK"
                    self.appendLog("[exploit] ok: \(msg)")
                    self.state = .done(ok: true, message: msg)
                } else {
                    let msg = errStr ?? "rc=\(rc)"
                    self.appendLog("[exploit] fail: \(msg)")
                    self.state = .done(ok: false, message: msg)
                }
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

    var totalContainerResultCount: Int {
        Set(installedAppContainers.map { normalizeContainerPath($0.container) }
            + installedAppGroups.map { normalizeContainerPath($0.container) }
            + appGroupAfcContainerPaths.map { normalizeContainerPath($0.container) }
            + appGroupContainerPaths.map { normalizeContainerPath($0.container) }
            + installationProxyInternalDaemonPaths.map { normalizeContainerPath($0.path) }
            + installationProxyPluginKitPluginPaths.map { normalizeContainerPath($0.path) }
            + internalDaemonAfcPaths.map(normalizeContainerPath)
            + pluginKitPluginAfcPaths.map(normalizeContainerPath)
            + internalDaemonBadQueryPaths.map(normalizeContainerPath)
            + pluginKitPluginBadQueryPaths.map(normalizeContainerPath)).count
    }

    /// These local BadQuery scans run when the Airlift screen opens, rather than
    /// waiting until the user opens each individual container category.
    func autoScanContainerDiagnosticsOnEntry() {
        guard !containerDiagnosticsAutoScannedOnEntry else {
            maybeAutoScanInstalledAppContainers()
            return
        }
        containerDiagnosticsAutoScannedOnEntry = true
        maybeAutoScanInstalledAppContainers()
        scanAppGroupContainerPaths(maxInode: 500_000)
        scanAdditionalContainerRootWithBadQuery("/var/mobile/Containers/Data/InternalDaemon", maxInode: 500_000)
        scanAdditionalContainerRootWithBadQuery("/var/mobile/Containers/Data/PluginKitPlugin", maxInode: 500_000)
    }

    /// Manually refresh every known container source from the unified Containers screen.
    func rescanAllContainers() {
        scanInstalledAppContainers()
        scanAppGroupContainerPathsViaAirlift()
        scanAppGroupContainerPaths(maxInode: 500_000)
        for root in ["/var/mobile/Containers/Data/InternalDaemon", "/var/mobile/Containers/Data/PluginKitPlugin"] {
            probeAdditionalContainerRootViaAirlift(root)
            scanAdditionalContainerRootWithBadQuery(root, maxInode: 500_000)
        }
    }

    /// Enumerates installed application Data containers through InstallationProxy only.
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

    func scanInstalledAppContainers() {
        let pairingPath = pairingFilePath()
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            appScanLog.append("[scan] no pairing file")
            return
        }
        guard !appScanRunning else { return }

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

            func parseAdditionalPaths(_ key: String) -> [AirliftAdditionalContainerPath] {
                let values = (payload["additionalContainerPaths"] as? [String: Any])?[key] as? [[String: Any]] ?? []
                return values.compactMap { item in
                    guard let path = item["path"] as? String else { return nil }
                    return AirliftAdditionalContainerPath(path: path, sourceApps: item["sourceApps"] as? [String] ?? [])
                }
            }
            let internalDaemonPaths = parseAdditionalPaths("InternalDaemon")
            let pluginKitPluginPaths = parseAdditionalPaths("PluginKitPlugin")

            await MainActor.run {
                self?.installedAppContainers = parsed
                self?.installedAppGroups = parsedGroups
                self?.appGroupIdentifiersWithoutPaths = identifiersWithoutPaths
                self?.installationProxyInternalDaemonPaths = internalDaemonPaths
                self?.installationProxyPluginKitPluginPaths = pluginKitPluginPaths
                self?.appScanLog = [
                    "[scan] InstallationProxy returned \(parsed.count) Data/Application container(s)",
                    "[scan] source: InstallationProxy application-container metadata",
                    "[scan] complete — no application files were read or written"
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
    func scanAppGroupContainerPaths(maxInode: Int64 = 100_000) {
        guard !appGroupBadQueryScanRunning else { return }
        appGroupBadQueryScanRunning = true
        appGroupPathScanRunning = true
        appGroupBadQueryScanLog = [
            "[bad_query] scanning /var/mobile/Containers/Shared/AppGroup",
            "[bad_query] path-only scan; inode ceiling: \(maxInode)",
            "[bad_query] getPathsOfDir"
        ]
        appGroupPathScanLog = appGroupAfcScanLog + appGroupBadQueryScanLog

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let root = "/var/mobile/Containers/Shared/AppGroup"
            let rawPaths = BadQuery().getPathsOfDir(atPath: root, maxInode: maxInode)
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
                    "[bad_query] inode ceiling: \(maxInode)",
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
    func scanAdditionalContainerRootWithBadQuery(_ root: String, maxInode: Int64 = 500_000) {
        guard isSupportedAdditionalContainerRoot(root) else {
            additionalContainerProbeLog = ["[bad_query] unsupported root; no scan run"]
            return
        }
        guard !additionalProbeIsRunning(root: root, source: "BadQuery") else { return }
        setAdditionalProbeRunning(true, root: root, source: "BadQuery")
        setAdditionalProbeLog([
            "[bad_query] scanning \(root)",
            "[bad_query] inode ceiling: \(maxInode)"
        ], root: root, source: "BadQuery")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let rawPaths = BadQuery().getPathsOfDir(atPath: root, maxInode: maxInode)
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
                    "[bad_query] inode ceiling: \(maxInode)",
                ], root: root, source: "BadQuery")
                self.setAdditionalProbeRunning(false, root: root, source: "BadQuery")
            }
        }
    }

    func readRemoteFile() {
        runRemoteRead(kind: .file)
    }

    func readRemoteFolder() {
        runRemoteRead(kind: .folder)
    }

    /// Card-artwork wrapper retained for the Wallet editor's existing call sites.
    func readRemoteImageFile(path: String, completion: @escaping (Data?) -> Void) {
        enqueueRemoteFileRead(path: path, logLabel: "card artwork", completion: completion)
    }

    private func enqueueRemoteFileRead(
        path: String,
        logLabel: String,
        completion: @escaping (Data?) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                completion(nil)
                return
            }
            self.pendingRemoteImageReads.append((path: path, logLabel: logLabel, completion: completion))
            self.startNextRemoteImageRead()
        }
    }

    private func startNextRemoteImageRead() {
        guard !standardReadInProgress else { return }

        while activeRemoteImageReadCount < maxConcurrentRemoteImageReads,
              !pendingRemoteImageReads.isEmpty {
            let request = pendingRemoteImageReads.removeFirst()
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
            appendLog("[read] \(request.logLabel) target=\(request.path)")

            Task.detached { [weak self] in
                var outJSON: UnsafeMutablePointer<CChar>? = nil
                var outError: UnsafeMutablePointer<CChar>? = nil
                let rc = pairingPath.withCString { pairingCString in
                    request.path.withCString { targetCString in
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

                await MainActor.run {
                    guard let self else {
                        request.completion(nil)
                        return
                    }
                    self.activeRemoteImageReadCount = max(0, self.activeRemoteImageReadCount - 1)
                    self.readRunning = self.standardReadInProgress || self.activeRemoteImageReadCount > 0
                    if rc == 0, let contents {
                        self.appendLog("[read] \(request.logLabel) success — \(contents.count) bytes")
                        request.completion(contents)
                    } else {
                        self.appendLog("[read] \(request.logLabel) failed: \(errorString ?? "no exported file (rc=\(rc))")")
                        request.completion(nil)
                    }
                    self.startNextRemoteImageRead()
                }
            }
        }
    }

    private func runRemoteRead(
        kind: ReadKind,
        targetOverride: String? = nil,
        importingCurrentPasscodeKeys: Bool = false,
        returningFileDataForQueuedRead: Bool = false
    ) {
        let pairingPath = pairingFilePath()
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            readResult = "No pairing file"
            if returningFileDataForQueuedRead {
                let completion = activeRemoteImageReadCompletion
                activeRemoteImageReadCompletion = nil
                completion?(nil)
                startNextRemoteImageRead()
            }
            return
        }
        let remote = (targetOverride ?? readTarget).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty else {
            readResult = "Enter a remote path"
            if returningFileDataForQueuedRead {
                let completion = activeRemoteImageReadCompletion
                activeRemoteImageReadCompletion = nil
                completion?(nil)
                startNextRemoteImageRead()
            }
            return
        }
        if readRunning { return }
        standardReadInProgress = true

        if !importingCurrentPasscodeKeys && !returningFileDataForQueuedRead {
            if let old = readExportPath { try? FileManager.default.removeItem(atPath: old) }
            if let old = readViewLocalPath, old != readExportPath { try? FileManager.default.removeItem(atPath: old) }
            readViewLocalPath = nil
            readViewRemotePath = nil
            readExportPath = nil
        }
        readRunning = true
        if !returningFileDataForQueuedRead {
            readResult = kind == .file ? "Reading…" : "Reading folder…"
        }
        appendLog("[read] target=\(remote) kind=\(kind.rawValue.lowercased())")

        Task.detached { [weak self] in
            var outJSON: UnsafeMutablePointer<CChar>? = nil
            var outError: UnsafeMutablePointer<CChar>? = nil
            let rc: Int32 = pairingPath.withCString { pc in
                remote.withCString { tc in
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
            var exportedPath: String? = nil
            var loadedCurrentPasscodeTheme: ErosionPasscodeTheme? = nil
            var loadedRemoteFileData: Data? = nil
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

                if let localPath, !localPath.isEmpty {
                    exportedPath = localPath
                    if importingCurrentPasscodeKeys && kind == .folder {
                        loadedCurrentPasscodeTheme = ErosionPasscodeThemeReader.inspectTelephonyFolderArchive(
                            at: URL(fileURLWithPath: localPath)
                        )
                        if let loadedCurrentPasscodeTheme {
                            display = "Current keys loaded — \(loadedCurrentPasscodeTheme.keys.count)/10"
                        } else {
                            display = "Folder was read, but no valid passcode key images were found."
                        }
                    } else if kind == .file, let data = try? Data(contentsOf: URL(fileURLWithPath: localPath)) {
                        if returningFileDataForQueuedRead {
                            loadedRemoteFileData = data
                            display = "Artwork file read OK — \(data.count) bytes"
                        } else {
                            let preview: String
                            if let text = String(data: data, encoding: .utf8) {
                                preview = String(text.prefix(12000))
                            } else {
                                preview = data.prefix(256).map { String(format: "%02x", $0) }.joined(separator: " ")
                            }
                            display = "Read OK — \(data.count) bytes\nSHA256: \((obj["sha256"] as? String) ?? "?")\n\n\(preview)"
                        }
                    } else if importingCurrentPasscodeKeys {
                        // The current-key import result was set above.
                    } else if isApplicationDataContainerTarget && !restoreHandoff {
                        display = "SAFETY STOP — read snapshot saved, but the original folder was NOT confirmed restored. Do not open the target app until recovery is resolved.\nFiles: \(count)\nRecovery staging: \(recoveryPath ?? "path not returned; inspect the Airlift log")\nRestore error: \(restoreError ?? "unknown")\nZIP: \(localPath)"
                    } else if isApplicationDataContainerTarget && (obj["partial"] as? Bool == true || !restoreConfirmed) {
                        let errors = obj["subdirectoryErrors"] as? [String: Any] ?? [:]
                        let warnings = obj["restoreWarnings"] as? [String: Any] ?? [:]
                        var details = errors.keys.sorted().map { "Incomplete: \($0)" }
                        details.append(contentsOf: warnings.keys.sorted().map { "Restore not directly verified: \($0)" })
                        if let restoreWarning, !restoreWarning.isEmpty { details.append(restoreWarning) }
                        if let exportError = obj["exportError"] as? String, !exportError.isEmpty { details.append(exportError) }
                        let detailText = details.isEmpty ? (restoreWarning ?? "see log") : details.joined(separator: "\n")
                        display = "Folder read PARTIAL — \(count) file(s)\n\(detailText)\n\(localPath)"
                    } else {
                        display = "Folder read OK — \(count) file(s)\n\(localPath)"
                    }
                } else if isApplicationDataContainerTarget && !restoreHandoff {
                    display = "SAFETY STOP — original folder restoration was NOT confirmed. Do not open the target app until recovery is resolved.\nRecovery staging: \(recoveryPath ?? "path not returned; inspect the Airlift log")\nRestore error: \(restoreError ?? "unknown")\nLocal partial files: \(localRecoveryPath ?? "not available")"
                } else if isApplicationDataContainerTarget {
                    let exportError = obj["exportError"] as? String ?? "The ZIP snapshot could not be completed."
                    display = "Folder read PARTIAL — \(count) file(s)\n\(restoreWarning ?? exportError)\nLocal partial files: \(localRecoveryPath ?? "not available")"
                } else {
                    display = errorString ?? jsonString ?? "Read failed (rc=\(rc))"
                }
            } else {
                display = errorString ?? jsonString ?? "Read failed (rc=\(rc))"
            }

            if (importingCurrentPasscodeKeys || returningFileDataForQueuedRead), let exportedPath {
                // Both these consumers read the exported snapshot immediately; avoid
                // leaving temporary duplicates in the app's shared file-browser state.
                try? FileManager.default.removeItem(atPath: exportedPath)
            }

            await MainActor.run {
                self?.standardReadInProgress = false
                self?.readRunning = (self?.activeRemoteImageReadCount ?? 0) > 0
                if !returningFileDataForQueuedRead {
                    self?.readResult = display
                }
                if !importingCurrentPasscodeKeys && !returningFileDataForQueuedRead {
                    self?.readExportPath = exportedPath
                    if rc == 0, let exportedPath {
                        self?.readViewRemotePath = remote
                        self?.readViewIsFolder = (kind == .folder)
                        if kind == .file { self?.readViewLocalPath = exportedPath }
                    }
                }
                self?.appendLog(rc == 0 ? "[read] success" : "[read] failed: \(display)")
                if importingCurrentPasscodeKeys {
                    if rc == 0, let loadedCurrentPasscodeTheme {
                        self?.installPasscodeTheme(loadedCurrentPasscodeTheme)
                        self?.appendPasscodeLog("✅ Loaded current keys — \(loadedCurrentPasscodeTheme.keys.count)/10")
                    } else {
                        self?.appendPasscodeLog("❌ Failed to get current keys: \(display)")
                    }
                }
                if returningFileDataForQueuedRead {
                    let completion = self?.activeRemoteImageReadCompletion
                    self?.activeRemoteImageReadCompletion = nil
                    completion?(rc == 0 ? loadedRemoteFileData : nil)
                }
                self?.startNextRemoteImageRead()
            }
        }
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
                readResult = "Could not open folder snapshot: \(error.localizedDescription)"
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

    /// Writes the edited local snapshot directly back to the exact remote file.
    /// This is a remote operation: it never reports success merely because the
    /// local snapshot was changed.
    func writeBack(localURL: URL, remotePath: String) async -> Bool {
        guard fileBrowserWriteReady() else {
            appendLog("[write] blocked: LocalDevVPN + pairing are both required")
            return false
        }
        guard remotePath.hasPrefix("/") else {
            appendLog("[write] blocked: invalid remote path \(remotePath)")
            return false
        }
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            appendLog("[write] local source missing: \(localURL.path)")
            return false
        }

        let pairing = pairingFilePath()
        let sourcePath = localURL.path
        appendLog("[write] exact target=\(remotePath)")

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

        if let message = result.1, !message.isEmpty {
            appendLog("[write] \(message)")
        }
        appendLog(result.0 ? "[write] success: \(remotePath)" : "[write] failed: \(remotePath)")
        return result.0
    }

    /// Removes exactly one remote file or directory. The operation is performed
    /// before the local snapshot item is deleted by the File Browser.
    func removeRemotePath(_ remotePath: String) async -> Bool {
        guard fileBrowserWriteReady() else {
            appendLog("[delete] blocked: LocalDevVPN + pairing are both required")
            return false
        }
        guard remotePath.hasPrefix("/") else {
            appendLog("[delete] blocked: invalid remote path \(remotePath)")
            return false
        }

        let pairing = pairingFilePath()
        appendLog("[delete] exact target=\(remotePath)")
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

        if let message = result.1, !message.isEmpty {
            appendLog("[delete] \(message)")
        }
        appendLog(result.0 ? "[delete] success: \(remotePath)" : "[delete] failed: \(remotePath)")
        return result.0
    }

    /// Injects a local directory as one exact remote directory. This is also
    /// useful for creating an empty folder because the Airlift folder archive
    /// contains an explicit `payload/` directory entry.
    func createRemoteDirectory(localURL: URL, remotePath: String) async -> Bool {
        guard fileBrowserWriteReady() else {
            appendLog("[mkdir] blocked: LocalDevVPN + pairing are both required")
            return false
        }
        let isDirectory = (try? localURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard isDirectory else {
            appendLog("[mkdir] local folder missing: \(localURL.path)")
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

    func loadPasscodeTheme(url: URL) {
        guard let theme = ErosionPasscodeThemeReader.inspect(url: url) else {
            appendPasscodeLog("❌ Failed to read .passthm")
            return
        }
        installPasscodeTheme(theme)
        passcodeFlashLog = [
            "Loaded: \(theme.name)",
            "Key images: \(theme.keys.count)/10",
            "Theme assets: \(theme.fileCount)"
        ]
    }

    func clearPasscodeTheme() {
        passcodeTheme = nil
        PasscodeThemeStorage.clear()
        passcodeFlashLog.removeAll()
    }

    /// Clear only the theme being edited, matching Dialer Themer's Clear Keys.
    /// This intentionally does not delete anything from the device.
    func clearPasscodeKeys() {
        passcodeTheme = nil
        PasscodeThemeStorage.clear()
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
        // Derive the language from the current system locale.
        let language = Locale.preferredLanguages.first
            .map { String($0.prefix(2)).lowercased() } ?? "en"
        var rawPayloads: [String: Data] = theme.rawData
        for (digit, image) in theme.keys where rawPayloads[digit] == nil {
            if let data = image.pngData() {
                rawPayloads[digit] = data
            }
        }
        let payloads = rawPayloads.mapValues { data in
            processPasscodeKeyData(
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

            let supportedLanguages: Set<String> = ["en", "uk", "ru", "es", "fr", "de", "it", "pt", "tr", "pl", "nl", "ja", "ko", "zh", "ar", "he"]
            let selectedLanguage = supportedLanguages.contains(language) ? language : "en"
            let langs: [String] = [selectedLanguage, "other"]

            // Always create both regular and bold assets automatically.
            let boldSuffixes = ["", "-bold"]

            let subtexts: [String: String] = [
                "0": "+", "1": "", "2": "A B C", "3": "D E F",
                "4": "G H I", "5": "J K L", "6": "M N O",
                "7": "P Q R S", "8": "T U V", "9": "W X Y Z"
            ]
            let ru: [String: String] = [
                "2": "А Б В Г", "3": "Д Е Ж З", "4": "И Й К Л",
                "5": "М Н О П", "6": "Р С Т У", "7": "Ф Х Ц Ч",
                "8": "Ш Щ Ъ Ы", "9": "Ь Э Ю Я"
            ]
            let uk: [String: String] = [
                "2": "А Б В Г", "3": "Д Е Ж З", "4": "І Ї Й К",
                "5": "Л М Н О", "6": "П Р С Т", "7": "У Ф Х Ц",
                "8": "Ч Ш Щ Ь", "9": "Ю Я"
            ]

            for (digit, imageData) in payloads {
                let std = subtexts[digit] ?? ""

                for lang in langs {
                    for suffix in boldSuffixes {
                        let blank = "\(lang)-\(digit)---white\(suffix).png"
                        try? imageData.write(to: stage.appendingPathComponent(blank))

                        if !std.isEmpty {
                            try? imageData.write(to: stage.appendingPathComponent(
                                "\(lang)-\(digit)-\(std)--white\(suffix).png"))
                            let noSpace = std.replacingOccurrences(of: " ", with: "")
                            if noSpace != std {
                                try? imageData.write(to: stage.appendingPathComponent(
                                    "\(lang)-\(digit)-\(noSpace)--white\(suffix).png"))
                            }
                        }

                        if lang == "ru", let v = ru[digit] {
                            try? imageData.write(to: stage.appendingPathComponent(
                                "\(lang)-\(digit)-\(v)--white\(suffix).png"))
                        }
                        if lang == "uk", let v = uk[digit] {
                            try? imageData.write(to: stage.appendingPathComponent(
                                "\(lang)-\(digit)-\(v)--white\(suffix).png"))
                        }
                    }
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
        await withCheckedContinuation { continuation in
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
    }

    func cancelExploit() { /* natsuk1-cancel-v1 */
        appendLog("[exploit] cancel requested")
        state = .done(ok: false, message: "cancelled")
    }

}
