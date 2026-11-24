import SwiftUI
import UIKit
import ZIPFoundation
import UniformTypeIdentifiers
import CryptoKit

struct AppsManagementView: View {
    @EnvironmentObject private var airlift: AirliftBridge
    @State private var preparedDirectories: [String: URL] = [:]
    @State private var preparingBundleIDs: Set<String> = []
    @State private var processingBundleIDs: Set<String> = []
    @State private var partialPreparationIDs: Set<String> = []
    @State private var alertMessage: String?
    @State private var appIcons: [String: UIImage] = [:]
    @State private var selectedInfoApp: AirliftAppBundlePath?
    @State private var initialLoadCompleted = false
    @State private var initialLoadStarted = false
    @State private var searchText = ""
    @AppStorage("listStyle") private var listStyle = 1

    private var sortedApps: [AirliftAppBundlePath] {
        airlift.installedAppBundlePaths.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private var visibleApps: [AirliftAppBundlePath] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sortedApps }
        return sortedApps.filter { app in
            app.displayName.localizedCaseInsensitiveContains(query)
                || app.bundleID.localizedCaseInsensitiveContains(query)
                || app.path.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        appList
            .onAppear {
                startInitialLoadIfNeeded()
            }
            .onChange(of: airlift.installedAppBundlePaths) { _, _ in
                reloadPreparedApps()
            }
            .alert("App Decrypt", isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("OK", role: .cancel) { alertMessage = nil }
            } message: {
                Text(alertMessage ?? "")
            }
            .sheet(item: $selectedInfoApp) { app in
                InfoViewer(bundleInfoItem(for: app))
            }
    }

    /// Root list for installed application bundles.
    private var appList: some View {
        List {
            if !initialLoadCompleted {
                Section {
                    VStack(alignment: .leading) {
                        HStack {
                            ProgressView()
                                .offset(y: 0.5)
                            Text("Loading Files...")
                                .fontWeight(.medium)
                        }
                        Text("This may take up to 5 seconds. Ensure you have a valid pairing and LocalDevVPN on.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    if sortedApps.isEmpty {
                        ContentUnavailableView(
                            "No apps found",
                            systemImage: "app.dashed",
                            description: Text("No installed app bundles were found.")
                        )
                    } else if visibleApps.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        ForEach(visibleApps) { app in
                            appRow(app)
                        }
                    }
                }
            }
        }
        .navigationTitle("App Decrypt")
        .navigationBarTitleDisplayMode(.inline)
        .customListStyle(listStyle)
        .adaptiveListMargin()
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search apps"
        )
        .refreshable {
            await refreshInstalledApps()
        }
    }

    @ViewBuilder
    private func appRow(_ app: AirliftAppBundlePath) -> some View {
        HStack(spacing: 12) {
            AppsManagementAppIcon(app: app) { image in
                appIcons[app.preparedStorageKey] = image
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(app.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(app.bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if preparedDirectories[app.preparedStorageKey] != nil {
                    Text("Prepared")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                } else if preparingBundleIDs.contains(app.preparedStorageKey) {
                    Text("Preparing…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if preparingBundleIDs.contains(app.preparedStorageKey) || processingBundleIDs.contains(app.preparedStorageKey) {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                selectedInfoApp = app
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.primary)
            .accessibilityLabel("Get Info for \(app.displayName)")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Menu {
                Button("Bundle ID") {
                    UIPasteboard.general.string = app.bundleID
                    Haptic.shared.play(.soft)
                }
                Button("Icon") {
                    copyAppIcon(for: app)
                }
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            Button {
                prepare(app)
            } label: {
                Label("Prepare", systemImage: "arrow.down.doc")
            }
            .disabled(preparingBundleIDs.contains(app.preparedStorageKey) || processingBundleIDs.contains(app.preparedStorageKey))

            Button {
                createIPA(for: app)
            } label: {
                Label("Decrypt", systemImage: "doc.zipper")
            }
            .disabled(preparedDirectories[app.preparedStorageKey] == nil
                || preparingBundleIDs.contains(app.preparedStorageKey)
                || processingBundleIDs.contains(app.preparedStorageKey))
        }
    }

    private func copyAppIcon(for app: AirliftAppBundlePath) {
        Task { @MainActor in
            var image = appIcons[app.preparedStorageKey]
            if image == nil {
                image = await airlift.fetchAppIcon(bundleID: app.bundleID)
                if image == nil, app.bundleID != "com.apple.Posters.UnityPosterApp" {
                    image = await airlift.fetchAppIcon(bundleID: "com.apple.Posters.UnityPosterApp")
                }
                appIcons[app.preparedStorageKey] = image
            }
            guard let image else {
                alertMessage = "The app icon could not be loaded."
                return
            }
            UIPasteboard.general.image = image
            Haptic.shared.play(.soft)
        }
    }

    private func bundleInfoItem(for app: AirliftAppBundlePath) -> FileItem {
        var item = getFileItem(at: URL(fileURLWithPath: app.path, isDirectory: true))
        item.name = app.displayName
        item.type = .folder
        item.uttype = .folder
        return item
    }

    private func reloadPreparedApps() {
        preparedDirectories = PreparedAppsStorage.preparedDirectories()
    }

    private func startInitialLoadIfNeeded() {
        guard !initialLoadStarted else { return }
        initialLoadStarted = true
        reloadPreparedApps()

        airlift.scanInstalledAppBundlePathsIfNeeded()

        Task { @MainActor in
            // InstallationProxy may already be running from File Browser. Keep
            // the loading card visible until that metadata scan reaches a result.
            while airlift.appScanRunning {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            initialLoadCompleted = true
        }
    }

    /// Re-run the same InstallationProxy metadata scan used by the File Browser.
    /// SwiftUI keeps the native refresh indicator visible until the scan finishes.
    @MainActor
    private func refreshInstalledApps() async {
        while airlift.appScanRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        airlift.scanInstalledAppContainers()
        while airlift.appScanRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        reloadPreparedApps()
    }

    private func prepare(_ app: AirliftAppBundlePath) {
        let storageKey = app.preparedStorageKey
        guard !preparingBundleIDs.contains(storageKey),
              !processingBundleIDs.contains(storageKey) else { return }
        preparingBundleIDs.insert(storageKey)
        partialPreparationIDs.remove(storageKey)

        airlift.appendFeatureLog("app-decrypt", "Preparing \(app.displayName) (\(app.bundleID)) through Airlift")
        airlift.readRemotePathForFileOperations(path: app.path, kind: .folder, feature: "apps-management", quiet: true) { success, archiveURL, detail in
            guard success, let archiveURL else {
                failPreparation(
                    app,
                    stagingAppURL: nil,
                    message: detail.isEmpty ? "Airlift could not read this app bundle." : detail
                )
                return
            }

            Task { @MainActor in
                var stagingAppURL: URL?
                do {
                    if detail.localizedCaseInsensitiveContains("partial") {
                        partialPreparationIDs.insert(storageKey)
                    }
                    let stagedURL = try await Task.detached(priority: .utility) {
                        try PreparedAppsStorage.stageSnapshot(archiveURL, for: app)
                    }.value
                    stagingAppURL = stagedURL
                    // Supplement the directory snapshot with the executable and
                    // important root files. A failed supplemental read must not
                    // discard content already collected in the initial snapshot.
                    readSupplementalFiles(
                        ["Info.plist"],
                        index: 0,
                        for: app,
                        stagingAppURL: stagedURL
                    )
                } catch {
                    failPreparation(app, stagingAppURL: stagingAppURL, message: error.localizedDescription)
                }
            }
        }
    }

    /// Read high-value bundle files separately after staging the app directory.
    /// Individual failures are non-fatal: keep the first snapshot and continue.
    private func readSupplementalFiles(
        _ fileNames: [String],
        index: Int,
        for app: AirliftAppBundlePath,
        stagingAppURL: URL
    ) {
        guard index < fileNames.count else {
            if fileNames.count == 1 && fileNames.first == "Info.plist" {
                Task { @MainActor in
                    if let executableName = try? await Task.detached(priority: .utility, operation: {
                        try PreparedAppsStorage.executableName(in: stagingAppURL)
                    }).value {
                        readSupplementalFiles(
                            [executableName, "Assets.car", "PkgInfo"],
                            index: 0,
                            for: app,
                            stagingAppURL: stagingAppURL
                        )
                    } else {
                        partialPreparationIDs.insert(app.preparedStorageKey)
                        readSupplementalFiles(
                            ["Assets.car", "PkgInfo"],
                            index: 0,
                            for: app,
                            stagingAppURL: stagingAppURL
                        )
                    }
                }
            } else {
                readOptionalAppDirectories(for: app, stagingAppURL: stagingAppURL)
            }
            return
        }

        let fileName = fileNames[index]
        let isOptionalResource = fileName == "Assets.car" || fileName == "PkgInfo"
        let remoteFilePath = app.path + "/" + fileName

        airlift.readRemotePathForFileOperations(
            path: remoteFilePath,
            kind: .file,
            feature: "apps-management",
            quiet: true
        ) { success, snapshotURL, detail in
            guard success, let snapshotURL else {
                if !isOptionalResource {
                    partialPreparationIDs.insert(app.preparedStorageKey)
                }
                continueAfterSupplementalRead(fileNames, index: index, failedFile: fileName, for: app, stagingAppURL: stagingAppURL)
                return
            }

            Task { @MainActor in
                do {
                    try await Task.detached(priority: .utility) {
                        try PreparedAppsStorage.mergeFileSnapshot(
                            snapshotURL,
                            named: fileName,
                            remoteReadDetail: detail,
                            into: stagingAppURL
                        )
                    }.value
                    readSupplementalFiles(
                        fileNames,
                        index: index + 1,
                        for: app,
                        stagingAppURL: stagingAppURL
                    )
                } catch {
                    if !isOptionalResource {
                        partialPreparationIDs.insert(app.preparedStorageKey)
                    }
                    continueAfterSupplementalRead(fileNames, index: index, failedFile: fileName, for: app, stagingAppURL: stagingAppURL)
                }
            }
        }
    }

    private func continueAfterSupplementalRead(
        _ fileNames: [String],
        index: Int,
        failedFile: String,
        for app: AirliftAppBundlePath,
        stagingAppURL: URL
    ) {
        if failedFile == "Info.plist" {
            // The broad .app snapshot may already contain a usable Info.plist.
            // Prefer its executable name; if unavailable, skip that one read
            // and still try optional root resources and embedded directories.
            let remainingNames: [String]
            if let executableName = try? PreparedAppsStorage.executableName(in: stagingAppURL) {
                remainingNames = [executableName, "Assets.car", "PkgInfo"]
            } else {
                remainingNames = ["Assets.car", "PkgInfo"]
            }
            readSupplementalFiles(remainingNames, index: 0, for: app, stagingAppURL: stagingAppURL)
        } else {
            readSupplementalFiles(fileNames, index: index + 1, for: app, stagingAppURL: stagingAppURL)
        }
    }

    /// Frameworks and PlugIns are optional in app bundles. Retain a copy from
    /// the broad snapshot if the dedicated directory read fails; replace it
    /// only after a complete, safely extracted dedicated snapshot is available.
    private func readOptionalAppDirectories(
        directoryNames names: [String] = ["Frameworks", "PlugIns"],
        index: Int = 0,
        for app: AirliftAppBundlePath,
        stagingAppURL: URL
    ) {
        guard index < names.count else {
            finalizePreparation(app, stagingAppURL: stagingAppURL)
            return
        }

        let directoryName = names[index]
        let directoryPath = app.path + "/" + directoryName
        airlift.readRemotePathForFileOperations(
            path: directoryPath,
            kind: .folder,
            feature: "apps-management",
            quiet: true
        ) { success, snapshotURL, detail in
            guard success, let snapshotURL else {
                readOptionalAppDirectories(directoryNames: names, index: index + 1, for: app, stagingAppURL: stagingAppURL)
                return
            }

            Task { @MainActor in
                do {
                    try await Task.detached(priority: .utility) {
                        try PreparedAppsStorage.mergeFolderSnapshot(
                            snapshotURL,
                            named: directoryName,
                            into: stagingAppURL
                        )
                    }.value
                } catch {
                    // A previous copy from the broad bundle snapshot, if any,
                    // remains intact when the dedicated merge cannot be used.
                }
                readOptionalAppDirectories(directoryNames: names, index: index + 1, for: app, stagingAppURL: stagingAppURL)
            }
        }
    }

    private func finalizePreparation(_ app: AirliftAppBundlePath, stagingAppURL: URL) {
        let storageKey = app.preparedStorageKey
        Task { @MainActor in
            do {
                let preparedURL = try await Task.detached(priority: .utility) {
                    try PreparedAppsStorage.finalizeStagedBundle(stagingAppURL, for: app)
                }.value
                preparedDirectories[storageKey] = preparedURL
                preparingBundleIDs.remove(storageKey)
                let wasPartial = partialPreparationIDs.remove(storageKey) != nil
                airlift.appendFeatureLog(
                    "app-decrypt",
                    wasPartial
                        ? "Prepared \(app.displayName) with partial data; all successfully read files were retained."
                        : "Prepared \(app.displayName)."
                )
            } catch {
                failPreparation(app, stagingAppURL: stagingAppURL, message: error.localizedDescription)
            }
        }
    }

    private func failPreparation(
        _ app: AirliftAppBundlePath,
        stagingAppURL: URL?,
        message: String
    ) {
        if let stagingAppURL {
            Task.detached(priority: .utility) {
                PreparedAppsStorage.discardStagedBundle(at: stagingAppURL)
            }
        }
        preparingBundleIDs.remove(app.preparedStorageKey)
        airlift.appendFeatureLog("app-decrypt", "Prepare failed for \(app.displayName): \(message)")
        alertMessage = message
    }

    private func createIPA(for app: AirliftAppBundlePath) {
        let storageKey = app.preparedStorageKey
        guard let preparedURL = preparedDirectories[storageKey] else { return }
        guard !processingBundleIDs.contains(storageKey) else { return }
        processingBundleIDs.insert(storageKey)
        airlift.appendFeatureLog("app-decrypt", "Building Payload and packaging \(app.displayName).ipa")
        Task {
            do {
                let ipaURL = try await Task.detached(priority: .utility) {
                    try PreparedAppsStorage.makeIPA(from: preparedURL, displayName: app.displayName)
                }.value
                processingBundleIDs.remove(storageKey)
                airlift.appendFeatureLog("app-decrypt", "IPA package ready: \(ipaURL.lastPathComponent)")
                presentShareSheet(with: ipaURL)
            } catch {
                processingBundleIDs.remove(storageKey)
                airlift.appendFeatureLog("app-decrypt", "IPA packaging failed for \(app.displayName): \(error.localizedDescription)")
                alertMessage = error.localizedDescription
            }
        }
    }
}

private struct AppsManagementAppIcon: View {
    @EnvironmentObject private var airlift: AirliftBridge
    let app: AirliftAppBundlePath
    let onImageLoaded: (UIImage?) -> Void
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(uiColor: .systemGray4))
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .task(id: app.id) {
            image = nil
            image = await airlift.fetchAppIcon(bundleID: app.bundleID)

            // Use the stock Posters app icon as the shared fallback for every
            // bundle whose own icon could not be loaded.
            if image == nil, app.bundleID != "com.apple.Posters.UnityPosterApp" {
                image = await airlift.fetchAppIcon(bundleID: "com.apple.Posters.UnityPosterApp")
            }
            onImageLoaded(image)
        }
    }
}

private struct PreparedAppManifest: Codable {
    let bundleID: String
    let displayName: String
    let sourcePath: String
    let appDirectoryName: String
    let preparedAt: Date
    let storageKey: String?
    let validationVersion: Int?
}

private enum PreparedAppsStorage {
    private struct BundleFileFingerprint {
        let size: Int64
        let sha256: String
    }

    private static var rootURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("ErosionAppsManagement", isDirectory: true)
    }

    private static var preparedRootURL: URL {
        rootURL.appendingPathComponent("Prepared", isDirectory: true)
    }

    private static var exportRootURL: URL {
        rootURL.appendingPathComponent("Exports", isDirectory: true)
    }

    static func preparedDirectories() -> [String: URL] {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(
            at: preparedRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var results: [String: URL] = [:]
        for directory in children {
            let manifestURL = directory.appendingPathComponent("prepared.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(PreparedAppManifest.self, from: data),
                  manifest.validationVersion == 2 else { continue }
            let appURL = directory.appendingPathComponent(manifest.appDirectoryName, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: appURL.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            results[manifest.storageKey ?? manifest.bundleID] = appURL
        }
        return results
    }

    /// Stage either a complete Airlift ZIP or its retained extracted partial tree.
    /// The previous successful preparation remains untouched until final commit.
    static func stageSnapshot(_ archiveURL: URL, for app: AirliftAppBundlePath) throws -> URL {
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        let appName = URL(fileURLWithPath: app.path).lastPathComponent
        guard isValidBundlePath(app.path), appName.lowercased().hasSuffix(".app") else {
            throw StorageError.invalidBundlePath
        }

        let fileManager = FileManager.default
        let stagingRoot = rootURL.appendingPathComponent("Preparing-\(UUID().uuidString)", isDirectory: true)
        let appURL = stagingRoot.appendingPathComponent(appName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: appURL, withIntermediateDirectories: true)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: archiveURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                // The local folder reader can retain a tree when ZIP export
                // itself failed. Copy its contents without another ZIP step.
                for child in try fileManager.contentsOfDirectory(at: archiveURL, includingPropertiesForKeys: nil) {
                    try fileManager.copyItem(at: child, to: appURL.appendingPathComponent(child.lastPathComponent))
                }
            } else {
                // Airlift's directory ZIP contains the .app directory contents at its root.
                try fileManager.unzipItem(at: archiveURL, to: appURL)
            }
            let entries = try fileManager.contentsOfDirectory(atPath: appURL.path)
            guard !entries.isEmpty else { throw StorageError.emptyBundle }
            return appURL
        } catch {
            try? fileManager.removeItem(at: stagingRoot)
            throw error
        }
    }

    /// Reads CFBundleExecutable from the directly-read Info.plist so the next
    /// Airlift request targets the exact executable file name.
    static func executableName(in appURL: URL) throws -> String {
        let infoURL = appURL.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: infoURL)
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let value = plist["CFBundleExecutable"] as? String,
              isSafeBundleFileName(value) else {
            throw StorageError.invalidExecutableName
        }
        return value
    }

    /// Merges a separately-read Airlift file into the staged .app. Copy to a
    /// temporary sibling first so the original snapshot is not truncated if
    /// the copy fails midway.
    static func mergeFileSnapshot(
        _ snapshotURL: URL,
        named fileName: String,
        remoteReadDetail: String,
        into appURL: URL
    ) throws {
        defer { try? FileManager.default.removeItem(at: snapshotURL) }
        guard isSafeBundleFileName(fileName) else { throw StorageError.invalidSupplementalFileName }

        // Airlift returns the device-side SHA-256 with every successful file read.
        // Verify those bytes before merging them into the prepared .app.
        let remoteHash = try remoteSHA256(from: remoteReadDetail, fileName: fileName)
        let fileManager = FileManager.default
        let standardizedAppURL = appURL.standardizedFileURL
        let destinationURL = standardizedAppURL.appendingPathComponent(fileName, isDirectory: false)
        guard destinationURL.deletingLastPathComponent().standardizedFileURL == standardizedAppURL else {
            throw StorageError.invalidSupplementalFileName
        }

        let sourceAttributes = try fileManager.attributesOfItem(atPath: snapshotURL.path)
        guard (sourceAttributes[.type] as? FileAttributeType) == .typeRegular,
              let sourceSize = sourceAttributes[.size] as? NSNumber,
              sourceSize.int64Value > 0 else {
            throw StorageError.emptySupplementalFile(fileName)
        }
        let sourceHash = try sha256File(at: snapshotURL)
        guard sourceHash == remoteHash else { throw StorageError.remoteChecksumMismatch(fileName) }

        let temporaryURL = standardizedAppURL.appendingPathComponent(".erosion-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try fileManager.copyItem(at: snapshotURL, to: temporaryURL)
        let copiedAttributes = try fileManager.attributesOfItem(atPath: temporaryURL.path)
        guard let copiedSize = copiedAttributes[.size] as? NSNumber,
              copiedSize.int64Value == sourceSize.int64Value,
              copiedSize.int64Value > 0 else {
            throw StorageError.incompleteSupplementalFile(fileName)
        }
        guard try sha256File(at: temporaryURL) == remoteHash else {
            throw StorageError.snapshotCopyChecksumMismatch(fileName)
        }

        // The app is still private staging data, so replacing the local copy
        // after the complete temporary copy is safe.
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }

    /// Adds a separately-read directory snapshot as a real child folder inside
    /// the staged .app. ZIP archives and retained partial trees are unpacked in
    /// a temporary sibling before replacing the staged directory.
    static func mergeFolderSnapshot(
        _ snapshotURL: URL,
        named folderName: String,
        into appURL: URL
    ) throws {
        defer { try? FileManager.default.removeItem(at: snapshotURL) }
        guard folderName == "Frameworks" || folderName == "PlugIns" else {
            throw StorageError.invalidSupplementalFileName
        }
        let fileManager = FileManager.default
        var snapshotIsDirectory: ObjCBool = false
        let hasSnapshot = fileManager.fileExists(atPath: snapshotURL.path, isDirectory: &snapshotIsDirectory)
        guard hasSnapshot else { throw StorageError.invalidFolderSnapshot(folderName) }
        if !snapshotIsDirectory.boolValue {
            guard let archive = try? Archive(url: snapshotURL, accessMode: .read) else {
                throw StorageError.invalidFolderSnapshot(folderName)
            }
            let entries = Array(archive)
            guard !entries.isEmpty else { throw StorageError.invalidFolderSnapshot(folderName) }
            for entry in entries {
                let path = entry.path
                let components = path.split(separator: "/", omittingEmptySubsequences: true)
                guard !path.isEmpty,
                      !path.hasPrefix("/"),
                      !path.contains("\\"),
                      !components.isEmpty,
                      !components.contains("."),
                      !components.contains("..") else {
                    throw StorageError.invalidFolderSnapshot(folderName)
                }
            }
        }

        let standardizedAppURL = appURL.standardizedFileURL
        let destinationURL = standardizedAppURL.appendingPathComponent(folderName, isDirectory: true)
        guard destinationURL.deletingLastPathComponent().standardizedFileURL == standardizedAppURL else {
            throw StorageError.invalidSupplementalFileName
        }

        let temporaryURL = standardizedAppURL.appendingPathComponent(
            ".erosion-\(UUID().uuidString)-\(folderName)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
        if snapshotIsDirectory.boolValue {
            let children = try fileManager.contentsOfDirectory(at: snapshotURL, includingPropertiesForKeys: nil)
            guard !children.isEmpty else { throw StorageError.invalidFolderSnapshot(folderName) }
            for child in children {
                try fileManager.copyItem(at: child, to: temporaryURL.appendingPathComponent(child.lastPathComponent))
            }
        } else {
            try fileManager.unzipItem(at: snapshotURL, to: temporaryURL)
        }
        guard fileManager.fileExists(atPath: temporaryURL.path) else {
            throw StorageError.invalidFolderSnapshot(folderName)
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }

    private static func remoteSHA256(from detail: String, fileName: String) throws -> String {
        guard let line = detail.components(separatedBy: .newlines).first(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("sha256:")
        }) else {
            throw StorageError.missingRemoteChecksum(fileName)
        }
        guard let separator = line.firstIndex(of: ":") else {
            throw StorageError.missingRemoteChecksum(fileName)
        }
        let hash = line[line.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else {
            throw StorageError.missingRemoteChecksum(fileName)
        }
        return hash
    }

    private static func sha256File(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Validates the final bundle and only then atomically commits it as the
    /// currently prepared copy for this bundle identifier.
    static func finalizeStagedBundle(_ appURL: URL, for app: AirliftAppBundlePath) throws -> URL {
        let fileManager = FileManager.default
        let appName = URL(fileURLWithPath: app.path).lastPathComponent
        let stagingRoot = appURL.deletingLastPathComponent().standardizedFileURL
        let expectedStagingParent = rootURL.standardizedFileURL.path + "/"
        guard stagingRoot.path.hasPrefix(expectedStagingParent),
              stagingRoot.lastPathComponent.hasPrefix("Preparing-"),
              appURL.lastPathComponent == appName,
              appName.lowercased().hasSuffix(".app") else {
            throw StorageError.invalidStagingBundle
        }

        let stagedEntries = try fileManager.contentsOfDirectory(atPath: appURL.path)
        guard !stagedEntries.isEmpty else { throw StorageError.emptyBundle }

        // A partially readable app is still a useful preparation result. Restore
        // executable permissions wherever its Info.plist files expose a target,
        // but do not throw away the rest of the snapshot if some are unavailable.
        _ = try? restoreExecutablePermissions(in: appURL)

        let manifest = PreparedAppManifest(
            bundleID: app.bundleID,
            displayName: app.displayName,
            sourcePath: app.path,
            appDirectoryName: appName,
            preparedAt: Date(),
            storageKey: app.preparedStorageKey,
            validationVersion: 2
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: stagingRoot.appendingPathComponent("prepared.json"),
            options: .atomic
        )

        try fileManager.createDirectory(at: preparedRootURL, withIntermediateDirectories: true)
        let committedRoot = preparedRootURL.appendingPathComponent(safeComponent(app.preparedStorageKey), isDirectory: true)
        let backupRoot = rootURL.appendingPathComponent("Previous-\(UUID().uuidString)", isDirectory: true)
        let hadPrevious = fileManager.fileExists(atPath: committedRoot.path)

        do {
            if hadPrevious { try fileManager.moveItem(at: committedRoot, to: backupRoot) }
            try fileManager.moveItem(at: stagingRoot, to: committedRoot)
            if hadPrevious { try? fileManager.removeItem(at: backupRoot) }
            return committedRoot.appendingPathComponent(appName, isDirectory: true)
        } catch {
            if hadPrevious,
               !fileManager.fileExists(atPath: committedRoot.path),
               fileManager.fileExists(atPath: backupRoot.path) {
                try? fileManager.moveItem(at: backupRoot, to: committedRoot)
            }
            throw error
        }
    }

    static func discardStagedBundle(at appURL: URL) {
        let stagingRoot = appURL.deletingLastPathComponent()
        guard stagingRoot.lastPathComponent.hasPrefix("Preparing-") else { return }
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    private static func isSafeBundleFileName(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains(":")
    }

    /// AFC folder snapshots do not consistently expose remote st_mode bits.
    /// Restore the executable bit for each bundle's declared CFBundleExecutable
    /// so the prepared app and the resulting IPA do not inherit ZIP's 0600 file
    /// mode for every regular file.
    @discardableResult
    private static func restoreExecutablePermissions(in appURL: URL) throws -> Int {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: appURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var executablePaths = Set<String>()
        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "Info.plist" {
            guard let data = try? Data(contentsOf: fileURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let dictionary = plist as? [String: Any],
                  let executable = dictionary["CFBundleExecutable"] as? String,
                  !executable.isEmpty,
                  !executable.contains("/"),
                  executable != ".", executable != ".." else { continue }

            let executableURL = fileURL.deletingLastPathComponent().appendingPathComponent(executable)
            let path = executableURL.standardizedFileURL.path
            guard path == appURL.standardizedFileURL.path
                    || path.hasPrefix(appURL.standardizedFileURL.path + "/") else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            executablePaths.insert(path)
        }

        // Embedded dynamic libraries are loadable Mach-O images as well. They
        // are not guaranteed to have a separate Info.plist in every package.
        if let enumerator = fileManager.enumerator(at: appURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "dylib" {
                executablePaths.insert(fileURL.standardizedFileURL.path)
            }
        }

        for path in executablePaths {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        return executablePaths.count
    }

    static func makeIPA(from appURL: URL, displayName: String) throws -> URL {
        guard appURL.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: appURL.path) else {
            throw StorageError.preparedBundleMissing
        }
        let expectedFiles = try bundleFilesForPackaging(in: appURL)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: exportRootURL, withIntermediateDirectories: true)
        let workingDirectory = rootURL.appendingPathComponent("Working-\(UUID().uuidString)", isDirectory: true)
        let payloadDirectory = workingDirectory.appendingPathComponent("Payload", isDirectory: true)
        try fileManager.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workingDirectory) }

        let payloadAppURL = payloadDirectory.appendingPathComponent(appURL.lastPathComponent, isDirectory: true)
        try fileManager.copyItem(at: appURL, to: payloadAppURL)

        let packageName = safeFileName(displayName)
        let zipURL = workingDirectory.appendingPathComponent("\(packageName).zip")
        try fileManager.zipItem(at: payloadDirectory, to: zipURL, shouldKeepParent: true)
        try validateIPAArchive(zipURL, appURL: appURL, expectedFiles: expectedFiles)

        let ipaURL = exportRootURL.appendingPathComponent("\(packageName)-\(UUID().uuidString.prefix(8)).ipa")
        try fileManager.moveItem(at: zipURL, to: ipaURL)
        do {
            try validateIPAArchive(ipaURL, appURL: appURL, expectedFiles: expectedFiles)
            return ipaURL
        } catch {
            try? fileManager.removeItem(at: ipaURL)
            throw error
        }
    }

    /// Fingerprint every regular file that survived preparation. Unlike the
    /// strict installability validator, this deliberately supports partial
    /// bundles so the resulting IPA retains all content that was readable.
    private static func bundleFilesForPackaging(in appURL: URL) throws -> [String: BundleFileFingerprint] {
        let fileManager = FileManager.default
        let standardizedRoot = appURL.standardizedFileURL
        let rootPrefix = standardizedRoot.path.hasSuffix("/") ? standardizedRoot.path : standardizedRoot.path + "/"
        guard let enumerator = fileManager.enumerator(
            at: standardizedRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw StorageError.emptyBundle
        }

        var fingerprints: [String: BundleFileFingerprint] = [:]
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }

            let standardizedFileURL = fileURL.standardizedFileURL
            guard standardizedFileURL.path.hasPrefix(rootPrefix) else {
                throw StorageError.invalidStagingBundle
            }
            let relativePath = String(standardizedFileURL.path.dropFirst(rootPrefix.count))
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
            guard !relativePath.isEmpty,
                  !components.isEmpty,
                  !components.contains("."),
                  !components.contains(".."),
                  !relativePath.contains("\\") else {
                throw StorageError.invalidStagingBundle
            }

            let attributes = try fileManager.attributesOfItem(atPath: standardizedFileURL.path)
            guard (attributes[.type] as? FileAttributeType) == .typeRegular,
                  let size = attributes[.size] as? NSNumber else { continue }
            fingerprints[relativePath] = BundleFileFingerprint(
                size: size.int64Value,
                sha256: try sha256File(at: standardizedFileURL)
            )
        }
        guard !fingerprints.isEmpty else { throw StorageError.emptyBundle }
        return fingerprints
    }

    /// Returns root-level files whose contents must survive in the IPA, along
    /// with their exact uncompressed sizes for archive verification.
    private static func validatedBundleFiles(
        in appURL: URL,
        expectedBundleID: String?
    ) throws -> [String: BundleFileFingerprint] {
        let fileManager = FileManager.default
        let infoURL = appURL.appendingPathComponent("Info.plist")
        let infoData = try Data(contentsOf: infoURL)
        guard let info = try PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any] else {
            throw StorageError.invalidInfoPlist
        }
        if let expectedBundleID {
            guard let actualBundleID = info["CFBundleIdentifier"] as? String,
                  actualBundleID == expectedBundleID else {
                throw StorageError.bundleIdentifierMismatch
            }
        }
        guard let executableName = info["CFBundleExecutable"] as? String,
              isSafeBundleFileName(executableName) else {
            throw StorageError.invalidExecutableName
        }

        var names = ["Info.plist", executableName]
        for optionalName in ["Assets.car", "PkgInfo"] {
            let optionalURL = appURL.appendingPathComponent(optionalName, isDirectory: false)
            if fileManager.fileExists(atPath: optionalURL.path) { names.append(optionalName) }
        }

        var fingerprints: [String: BundleFileFingerprint] = [:]
        for name in names where fingerprints[name] == nil {
            let fileURL = appURL.appendingPathComponent(name, isDirectory: false)
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            guard (attributes[.type] as? FileAttributeType) == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  size.int64Value > 0 else {
                if name == executableName { throw StorageError.executableMissingOrEmpty }
                throw StorageError.requiredBundleFileMissing(name)
            }
            fingerprints[name] = BundleFileFingerprint(
                size: size.int64Value,
                sha256: try sha256File(at: fileURL)
            )
        }

        let frameworksURL = appURL.appendingPathComponent("Frameworks", isDirectory: true)
        var frameworksIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: frameworksURL.path, isDirectory: &frameworksIsDirectory),
           frameworksIsDirectory.boolValue,
           let enumerator = fileManager.enumerator(
                at: frameworksURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
           ) {
            let appRootPath = appURL.standardizedFileURL.path + "/"
            for case let fileURL as URL in enumerator {
                let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
                guard (attributes[.type] as? FileAttributeType) == .typeRegular,
                      let size = attributes[.size] as? NSNumber else { continue }
                let standardizedFilePath = fileURL.standardizedFileURL.path
                guard standardizedFilePath.hasPrefix(appRootPath) else {
                    throw StorageError.invalidFolderSnapshot("Frameworks")
                }
                let relativePath = String(standardizedFilePath.dropFirst(appRootPath.count))
                let pathComponents = relativePath.split(separator: "/", omittingEmptySubsequences: true)
                guard relativePath.hasPrefix("Frameworks/"),
                      !pathComponents.contains("."),
                      !pathComponents.contains("..") else {
                    throw StorageError.invalidFolderSnapshot("Frameworks")
                }
                fingerprints[relativePath] = BundleFileFingerprint(
                    size: size.int64Value,
                    sha256: try sha256File(at: fileURL)
                )
            }
        }
        return fingerprints
    }

    /// Reopens the generated ZIP and verifies that critical .app files are
    /// present with the same uncompressed size as their staged originals.
    private static func validateIPAArchive(
        _ archiveURL: URL,
        appURL: URL,
        expectedFiles: [String: BundleFileFingerprint]
    ) throws {
        guard let archive = try? Archive(url: archiveURL, accessMode: .read) else {
            throw StorageError.invalidIPAArchive
        }
        let archivePrefix = "Payload/\(appURL.lastPathComponent)/"
        let verificationRoot = archiveURL.deletingLastPathComponent()
            .appendingPathComponent("Verify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: verificationRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: verificationRoot) }

        for (name, fingerprint) in expectedFiles {
            let expectedPath = archivePrefix + name
            guard let entry = archive.first(where: { $0.path == expectedPath }) else {
                throw StorageError.missingIPAEntry(name)
            }
            guard Int64(entry.uncompressedSize) == fingerprint.size else {
                throw StorageError.ipaEntrySizeMismatch(name)
            }

            let extractedURL = verificationRoot.appendingPathComponent(UUID().uuidString, isDirectory: false)
            // ZIPFoundation validates the ZIP entry's CRC while extracting.
            try archive.extract(entry, to: extractedURL)
            let extractedAttributes = try FileManager.default.attributesOfItem(atPath: extractedURL.path)
            guard let extractedSize = extractedAttributes[.size] as? NSNumber,
                  extractedSize.int64Value == fingerprint.size,
                  try sha256File(at: extractedURL) == fingerprint.sha256 else {
                throw StorageError.ipaEntryChecksumMismatch(name)
            }
        }
    }

    private static func isValidBundlePath(_ path: String) -> Bool {
        let root = "/var/containers/Bundle/Application/"
        guard path.hasPrefix(root) else { return false }
        let components = path.dropFirst(root.count).split(separator: "/", omittingEmptySubsequences: false)
        return components.count == 2
            && UUID(uuidString: String(components[0])) != nil
            && String(components[1]).lowercased().hasSuffix(".app")
    }

    private static func safeComponent(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return cleaned.isEmpty ? UUID().uuidString : cleaned
    }

    private static func safeFileName(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: "[/\\\\:\\n\\r]", with: "_", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Application" : cleaned
    }

    private enum StorageError: LocalizedError {
        case invalidBundlePath
        case emptyBundle
        case preparedBundleMissing
        case invalidExecutableName
        case invalidSupplementalFileName
        case emptySupplementalFile(String)
        case incompleteSupplementalFile(String)
        case invalidStagingBundle
        case invalidInfoPlist
        case bundleIdentifierMismatch
        case executableMissingOrEmpty
        case executablePermissionsNotRestored
        case requiredBundleFileMissing(String)
        case invalidFolderSnapshot(String)
        case invalidIPAArchive
        case missingIPAEntry(String)
        case ipaEntrySizeMismatch(String)
        case missingRemoteChecksum(String)
        case remoteChecksumMismatch(String)
        case snapshotCopyChecksumMismatch(String)
        case ipaEntryChecksumMismatch(String)

        var errorDescription: String? {
            switch self {
            case .invalidBundlePath: return "The app path is not a valid Bundle/Application UUID/<name>.app path."
            case .emptyBundle: return "The app bundle was empty; it was not marked as prepared."
            case .preparedBundleMissing: return "The prepared .app bundle could not be found in Erosion storage."
            case .invalidExecutableName: return "The app's CFBundleExecutable name is missing or invalid."
            case .invalidSupplementalFileName: return "A supplemental bundle file name was invalid."
            case .emptySupplementalFile(let name): return "The supplemental file \(name) was empty or was not a regular file."
            case .incompleteSupplementalFile(let name): return "The supplemental file \(name) was not copied completely."
            case .invalidStagingBundle: return "The staged app bundle is outside Erosion's preparation directory."
            case .invalidInfoPlist: return "The separately-read Info.plist is invalid."
            case .bundleIdentifierMismatch: return "The prepared Info.plist bundle identifier does not match the selected app."
            case .executableMissingOrEmpty: return "The app executable is missing, empty, or not a regular file."
            case .executablePermissionsNotRestored: return "The app executable permissions could not be restored."
            case .requiredBundleFileMissing(let name): return "The required bundle file \(name) is missing, empty, or not a regular file."
            case .invalidFolderSnapshot(let name): return "The optional \(name) directory snapshot is invalid or unsafe."
            case .invalidIPAArchive: return "The generated IPA could not be reopened as a valid ZIP archive."
            case .missingIPAEntry(let name): return "The generated IPA is missing \(name)."
            case .ipaEntrySizeMismatch(let name): return "The generated IPA contains an incomplete \(name) file."
            case .missingRemoteChecksum(let name): return "Airlift did not return a valid SHA-256 checksum for \(name)."
            case .remoteChecksumMismatch(let name): return "The locally saved \(name) does not match Airlift's device-side SHA-256 checksum."
            case .snapshotCopyChecksumMismatch(let name): return "The staged copy of \(name) failed SHA-256 verification."
            case .ipaEntryChecksumMismatch(let name): return "The \(name) entry in the generated IPA failed SHA-256 verification."
            }
        }
    }
}
