//
//  FileBrowserView.swift
//  AccessiblePlus
//
//  Created by lunginspector on 5/12/26.
//

import SwiftUI

import QuickLook

enum FileSortMode: String, CaseIterable, Codable, Hashable {
    case system, name, date, type, size
    
    var id: String { label }
    
    var label: String {
        switch self {
        case .system: return "Default"
        case .name: return "Name"
        case .date: return "Date"
        case .type: return "Type"
        case .size: return "Size"
        }
    }
}

/// Keeps the conditional folder/file row out of FileBrowserView's large List
/// builder. Splitting this view prevents Swift's result-builder type checker
/// from having to infer both row implementations inside the parent ForEach.
private struct FileBrowserItemRow: View {
    let file: FileItem
    let shouldGrant: Bool
    let isContainer: Bool
    let readOnly: Bool
    let airliftRemoteRoot: String?
    let airliftLocalRoot: String?
    let localBasePath: String
    let displayName: String?
    let navigationBlocked: Bool
    let metadataOnly: Bool

    private var remoteFilePath: String? {
        guard let remoteRoot = airliftRemoteRoot else { return nil }
        let localRoot = airliftLocalRoot ?? localBasePath
        return AirliftBridge.remotePath(
            remoteRoot: remoteRoot,
            localRoot: localRoot,
            localURL: file.fileURL
        )
    }

    @ViewBuilder
    var body: some View {
        if file.type == .folder {
            FolderRow(
                file: file,
                shouldGrant: isContainer || shouldGrant,
                isContainer: isContainer,
                readOnly: readOnly,
                airliftRemoteRoot: airliftRemoteRoot,
                airliftLocalRoot: airliftLocalRoot,
                displayName: displayName,
                navigationBlocked: navigationBlocked,
                metadataOnly: metadataOnly
            )
        } else {
            FileRow(
                file: file,
                readOnly: readOnly,
                airliftRemotePath: remoteFilePath,
                airliftRemoteRoot: airliftRemoteRoot,
                airliftLocalRoot: airliftLocalRoot
            )
        }
    }
}

private enum FileBrowserLifecycleEvent {
    case appear
    case chosenSortChanged
    case filesAscendChanged
    case refreshFilesChanged
    case installedAppContainersChanged
    case installedAppBundlePathsChanged
    case installedAppGroupsChanged
    case pluginKitPluginBadQueryPathsChanged
    case pluginKitPluginBadQueryRunningChanged(Bool)
    case appScanRunningChanged(Bool)
}

/// Enables the navigation search drawer only for the normal File Browser.
/// Airlift directory snapshots intentionally omit it because the drawer sticks
/// to the navigation bar while scrolling the snapshot.
private struct ConditionalFileBrowserSearch: ViewModifier {
    @Binding var text: String
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .automatic))
        } else {
            content
        }
    }
}

/// Keeps state observation separate from FileBrowserView's large List/toolbar
/// builder. The parent supplies one event dispatcher instead of a long series
/// of inferred closure expressions.
private struct FileBrowserLifecycleModifier: ViewModifier {
    @ObservedObject var airlift: AirliftBridge
    let chosenSort: FileSortMode
    let filesAscend: Bool
    let refreshFiles: Bool
    let handle: (FileBrowserLifecycleEvent) -> Void

    func body(content: Content) -> some View {
        content
            .onAppear { handle(.appear) }
            .onChange(of: chosenSort) { handle(.chosenSortChanged) }
            .onChange(of: filesAscend) { handle(.filesAscendChanged) }
            .onChange(of: refreshFiles) { handle(.refreshFilesChanged) }
            .onChange(of: airlift.installedAppContainers) { _, _ in handle(.installedAppContainersChanged) }
            .onChange(of: airlift.installedAppBundlePaths) { _, _ in handle(.installedAppBundlePathsChanged) }
            .onChange(of: airlift.installedAppGroups) { _, _ in handle(.installedAppGroupsChanged) }
            .onChange(of: airlift.pluginKitPluginBadQueryPaths) { _, _ in handle(.pluginKitPluginBadQueryPathsChanged) }
            .onChange(of: airlift.pluginKitPluginBadQueryRunning) { _, running in
                handle(.pluginKitPluginBadQueryRunningChanged(running))
            }
            .onChange(of: airlift.appScanRunning) { _, running in handle(.appScanRunningChanged(running)) }
    }
}

struct FileBrowserView: View {
    @EnvironmentObject var mgr: ErosionManager
    @ObservedObject private var airlift = AirliftBridge.shared
    var path: URL = URL(fileURLWithPath: "/")
    var isContainer = false
    var shouldGrant = false
    var readOnly = false
    /// Used only by DB5+ Airlift compatibility roots: list immediate container
    /// identifiers but prevent opening the individual container directories.
    var blockContainerEntry = false
    /// Lists bundle-container identifiers but prevents navigation into the bundle roots.
    var blockFolderNavigation = false
    var fixedFiles: [URL]? = nil
    var navigationTitleOverride: String? = nil
    var airliftRemoteRoot: String? = nil
    var airliftLocalRoot: String? = nil
    
    @State private var unfilteredFiles: [FileItem] = []
    @State private var searchText = ""
    @AppStorage("maxInode") var maxInode = 7500000
    @AppStorage("chosenSort") var chosenSort: FileSortMode = .system
    @AppStorage("filesAscend") var filesAscend = true
    @AppStorage("listStyle") var listStyle = 1
    @AppStorage("hideDates") var hideDates = false
    @AppStorage("textViewerSize") var textViewerSize = 10
    @AppStorage("useMonospaced") var useMonospaced = true
    
    @State private var showFileImporter = false
    @State private var showFailure = false
    @State private var failMsg = ""
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var loadGeneration = 0

    /// Airlift folder reads are local snapshot directories created by Erosion.
    /// They must not be subjected to the system-path readability gate used
    /// by the normal file browser; their local copy is editable in Erosion.
    private var isAirliftSnapshot: Bool {
        airliftLocalRoot != nil
    }

    /// Airlift snapshots are local, writable copies. Viewer edits use the
    /// existing Airlift write-back bridge to update the original remote file.
    private var effectiveReadOnly: Bool {
        isAirliftSnapshot ? false : readOnly
    }

    private var hasAirliftWriteContext: Bool {
        airliftRemoteRoot != nil && airliftLocalRoot != nil
    }

    /// Always derive displayed rows from the complete directory snapshot. Keeping
    /// the filtered list out of @State prevents a cleared query from leaving a
    /// stale single-result list after navigating back from a match.
    private var visibleFiles: [FileItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return unfilteredFiles }
        return unfilteredFiles.filter { file in
            let label = isRestrictedContainerRoot ? restrictedContainerDisplayName(for: file) : file.name
            return label.localizedCaseInsensitiveContains(query)
                || file.fileURL.path.localizedCaseInsensitiveContains(query)
        }
    }

    private func remoteMutationAllowed() -> Bool {
        AirliftBridge.shared.fileBrowserWriteReady()
    }

    private func remotePath(for localURL: URL) -> String? {
        guard let remoteRoot = airliftRemoteRoot, let localRoot = airliftLocalRoot else { return nil }
        return AirliftBridge.remotePath(remoteRoot: remoteRoot, localRoot: localRoot, localURL: localURL)
    }

    private static func normalizedBundleContainerPath(_ value: String) -> String {
        let path = URL(fileURLWithPath: value).standardizedFileURL.path
        if path.hasPrefix("/private/var/containers/Bundle/Application/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    private static func normalizedContainerPath(_ value: String) -> String {
        var path = value.hasPrefix("/private/var/")
            ? String(value.dropFirst("/private".count))
            : value
        // InstallationProxy may return the /var/containers aliases for roots
        // shown under /var/mobile/Containers in File Browser. Normalize these
        // metadata paths to one visible row per UUID.
        let aliases: [(String, String)] = [
            ("/var/containers/Data/Application/", "/var/mobile/Containers/Data/Application/"),
            ("/var/containers/Data/PluginKitPlugin/", "/var/mobile/Containers/Data/PluginKitPlugin/"),
            ("/var/containers/Data/InternalDaemon/", "/var/mobile/Containers/Data/InternalDaemon/"),
            ("/var/containers/Shared/AppGroup/", "/var/mobile/Containers/Shared/AppGroup/")
        ]
        for (alias, visibleRoot) in aliases where path.hasPrefix(alias) {
            path = visibleRoot + path.dropFirst(alias.count)
            break
        }
        return path
    }

    private var restrictedContainerRootKind: String? {
        guard airliftUIAccessRequired(), blockContainerEntry, isContainer else { return nil }
        switch Self.normalizedContainerPath(path.standardizedFileURL.path) {
        case Self.normalizedContainerPath(FSURL.appContainers.path): return "data"
        case Self.normalizedContainerPath(FSURL.appGroup.path): return "appGroups"
        case Self.normalizedContainerPath(FSURL.appPlugins.path): return "plugins"
        case Self.normalizedContainerPath(FSURL.internalDaemons.path): return "daemons"
        case Self.normalizedContainerPath(FSURL.sysGroup.path): return "systemGroups"
        default: return nil
        }
    }

    private var isRestrictedContainerRoot: Bool { restrictedContainerRootKind != nil }

    /// Apps → Bundles is backed only by InstallationProxy metadata.
    /// The corresponding UUID paths are labels, never readable File URLs.
    private var isBundleApplicationRoot: Bool {
        isContainer && path.standardizedFileURL.path == FSPaths.appBundles
    }

    private var isDataApplicationContainerRoot: Bool {
        isContainer
            && Self.normalizedContainerPath(path.standardizedFileURL.path)
                == Self.normalizedContainerPath(FSURL.appContainers.standardizedFileURL.path)
    }

    /// Snapshot only the metadata sources permitted for this root on the main actor
    /// before starting filesystem work. The worker never reads SwiftUI environment state.
    private func restrictedContainerMetadataPaths(for rootKind: String?) -> [String] {
        switch rootKind {
        case "data":
            return airlift.installedAppContainers.map(\.container)
        case "appGroups":
            return airlift.installedAppGroups.map(\.container)
        case "plugins":
            // PluginKitPlugin is enumerated exclusively by BadQuery.
            return airlift.pluginKitPluginBadQueryPaths
        case "daemons":
            // InternalDaemon is enumerated by the existing local/Airlift readers,
            // never by InstallationProxy metadata.
            return []
        default:
            return []
        }
    }

    /// Data/Application and App Groups can use their InstallationProxy metadata.
    /// InternalDaemon, PluginKitPlugin, and SystemGroup are enumerated independently.
    private static func restrictedContainerPaths(
        rootKind: String,
        rootURL: URL,
        metadataPaths: [String],
        maxInodeLimit: Int64
    ) throws -> [String] {
        var paths = Set(metadataPaths.map { Self.normalizedContainerPath($0) })
        var didBadQueryEnumeration = false

        func appendBadQueryChildren() {
            let enumeratedPaths = fsHandlers.getDirPaths(rootURL.path, maxInode: maxInodeLimit)
            didBadQueryEnumeration = true
            for candidate in enumeratedPaths {
                let normalized = Self.normalizedContainerPath(candidate)
                let url = URL(fileURLWithPath: normalized)
                guard url.deletingLastPathComponent().standardizedFileURL.path == rootURL.standardizedFileURL.path else { continue }
                if rootKind != "systemGroups", UUID(uuidString: url.lastPathComponent) == nil { continue }
                paths.insert(normalized)
            }
        }

        do {
            let directChildren = try fm.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
            for child in directChildren {
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirectory { paths.insert(Self.normalizedContainerPath(child.standardizedFileURL.path)) }
            }
        } catch {
            if paths.isEmpty {
                // If ordinary enumeration is denied and metadata has not supplied
                // paths yet, retain path-only UUID enumeration. These rows
                // remain labels only and cannot open the individual container.
                appendBadQueryChildren()
                if paths.isEmpty { throw error }
            }
        }

        // If neither metadata nor normal directory enumeration supplied rows,
        // use BadQuery and the user's File Browser inode limit.
        if paths.isEmpty && !didBadQueryEnumeration {
            appendBadQueryChildren()
        }
        return paths.sorted()
    }

    private static func makeRestrictedContainerItem(path value: String) -> FileItem {
        let url = URL(fileURLWithPath: value, isDirectory: true)
        var item = getFileItem(at: url)
        item.name = url.lastPathComponent
        item.destURL = url
        item.type = .folder
        // These rows are metadata-only container identifiers in Airlift mode.
        // They are not readable local directories; actual Airlift snapshots are
        // created through a different FileBrowserView path and keep their real flags.
        item.readable = false
        item.writable = false
        item.executable = false
        return item
    }

    private func restrictedContainerDisplayName(for file: FileItem) -> String {
        guard let kind = restrictedContainerRootKind else { return file.name }
        let path = Self.normalizedContainerPath(file.fileURL.standardizedFileURL.path)
        switch kind {
        case "data":
            return airlift.installedAppContainers.first(where: {
                Self.normalizedContainerPath($0.container) == path
            })?.bundleID ?? URL(fileURLWithPath: path).lastPathComponent
        case "appGroups":
            if let group = airlift.installedAppGroups.first(where: { candidate in
                Self.normalizedContainerPath(candidate.container) == path
            }) {
                // Keep this work in concrete sub-expressions: nesting filter + Set +
                // Array + sorted inside the large FileBrowserView expression makes
                // Swift's type checker time out in Release builds.
                let nonEmptySourceApps: [String] = group.sourceApps.filter { sourceApp in
                    !sourceApp.isEmpty
                }
                let uniqueSourceApps: Set<String> = Set(nonEmptySourceApps)
                let bundleIDs: [String] = uniqueSourceApps.sorted()
                if !bundleIDs.isEmpty {
                    return bundleIDs.joined(separator: ", ")
                }
            }
            return URL(fileURLWithPath: path).lastPathComponent
        default:
            return URL(fileURLWithPath: path).lastPathComponent
        }
    }

    private func makeBrowserItemRow(for file: FileItem) -> FileBrowserItemRow {
        let rowDisplayName: String?
        if isBundleApplicationRoot {
            rowDisplayName = file.name
        } else if isRestrictedContainerRoot {
            rowDisplayName = restrictedContainerDisplayName(for: file)
        } else {
            rowDisplayName = nil
        }

        // Container UUID rows remain navigable. The destination requests its
        // own Worse Query grant, matching the original Erosion browser flow.
        let rowNavigationBlocked = blockFolderNavigation || isBundleApplicationRoot
        // Bundles are metadata-only app labels: keep Info available, but never
        // create navigation or file actions. The full installation path remains
        // attached to the FileItem for the Info sheet only.
        let rowIsMetadataOnly = isBundleApplicationRoot
        return FileBrowserItemRow(
            file: file,
            shouldGrant: shouldGrant,
            isContainer: isContainer,
            readOnly: effectiveReadOnly,
            airliftRemoteRoot: airliftRemoteRoot,
            airliftLocalRoot: airliftLocalRoot,
            localBasePath: path.path,
            displayName: rowDisplayName,
            navigationBlocked: rowNavigationBlocked,
            metadataOnly: rowIsMetadataOnly
        )
    }

    /// Use the same Worse Query access path as the original Erosion browser.
    private func acquireContainerAccess(at targetURL: URL) -> (Bool, String) {
        let result = wq.grantAccess(path: targetURL.path)
        return (result.0, result.0 ? "Worse Query: succeeded" : "\(result.1): \(result.2)")
    }

    private func reloadRestrictedContainerRoot() {
        guard isRestrictedContainerRoot else { return }
        hasLoaded = false
        loadFilesFromPath()
    }

    /// Handles the shared app-scan transition (Bundle metadata only) in one place.
    /// Keeping this branch outside the long SwiftUI modifier chain avoids a
    /// Release-build type-checker timeout and prevents duplicate observers.
    private func handleAppScanStateChange(running: Bool) {
        guard !running else { return }

        if restrictedContainerRootKind == "data" {
            reloadRestrictedContainerRoot()
            return
        }
        if isDataApplicationContainerRoot {
            mergeInstallationProxyDataContainerRows()
            return
        }
        if isBundleApplicationRoot {
            loadFilesFromPath()
            return
        }
    }

    /// Merge InstallationProxy-discovered Data/Application paths into the existing
    /// Worse Query listing. These rows are still normal container rows: opening one
    /// asks FolderRow to grant access with WQ, and no InstallationProxy file I/O occurs.
    private func mergeInstallationProxyDataContainerRows() {
        guard isDataApplicationContainerRoot,
              airlift.airliftFeatureReady(),
              airlift.installedAppContainerScanReady else { return }

        let rootPath = Self.normalizedContainerPath(FSURL.appContainers.standardizedFileURL.path)
        var knownPaths = Set(unfilteredFiles.map {
            Self.normalizedContainerPath($0.fileURL.standardizedFileURL.path)
        })
        var additions: [FileItem] = []

        for entry in airlift.installedAppContainers {
            let normalized = Self.normalizedContainerPath(entry.container)
            let url = URL(fileURLWithPath: normalized, isDirectory: true)
            guard url.deletingLastPathComponent().standardizedFileURL.path == rootPath,
                  UUID(uuidString: url.lastPathComponent) != nil,
                  knownPaths.insert(normalized).inserted else { continue }

            var item = getFileItem(at: url, isContainer: true)
            // InstallationProxy supplies a path, not a local file handle. Keep it
            // navigable as a folder even when sandbox lstat cannot inspect the UUID.
            item.type = .folder
            item.uttype = .folder
            item.destURL = url
            additions.append(item)
        }

        guard !additions.isEmpty else { return }
        unfilteredFiles = sortFiles(files: unfilteredFiles + additions)
        mgr.storedFiles = unfilteredFiles
        mgr.storedURL = path
        hasLoaded = true
        showFailure = false
    }
    
    private func handleBrowserLifecycleEvent(_ event: FileBrowserLifecycleEvent) {
        switch event {
        case .appear:
            handleBrowserAppear()
        case .chosenSortChanged, .filesAscendChanged:
            loadFilesFromPath()
        case .refreshFilesChanged:
            if restrictedContainerRootKind == "plugins" {
                airlift.scanAdditionalContainerRootWithBadQuery(
                    path.standardizedFileURL.path,
                    maxInode: Int64(maxInode)
                )
                if airlift.pluginKitPluginBadQueryRunning {
                    isLoading = true
                    hasLoaded = false
                    showFailure = false
                } else {
                    loadFilesFromPath()
                }
            } else {
                loadFilesFromPath()
            }
        case .installedAppContainersChanged:
            if restrictedContainerRootKind == "data" {
                reloadRestrictedContainerRoot()
            } else if isDataApplicationContainerRoot {
                mergeInstallationProxyDataContainerRows()
            }
        case .installedAppBundlePathsChanged:
            if isBundleApplicationRoot { loadFilesFromPath() }
        case .installedAppGroupsChanged:
            if restrictedContainerRootKind == "appGroups" { reloadRestrictedContainerRoot() }
        case .pluginKitPluginBadQueryPathsChanged:
            if restrictedContainerRootKind == "plugins", !airlift.pluginKitPluginBadQueryRunning {
                reloadRestrictedContainerRoot()
            }
        case .pluginKitPluginBadQueryRunningChanged(let running):
            handlePluginKitPluginBadQueryStateChange(running: running)
        case .appScanRunningChanged(let running):
            handleAppScanStateChange(running: running)
        }
    }


    private func handlePluginKitPluginBadQueryStateChange(running: Bool) {
        guard !running, restrictedContainerRootKind == "plugins" else { return }
        let requestedInodeLimit = Int64(maxInode)
        if airlift.pluginKitPluginBadQueryInodeLimit != requestedInodeLimit {
            airlift.scanAdditionalContainerRootWithBadQuery(
                path.standardizedFileURL.path,
                maxInode: requestedInodeLimit
            )
            return
        }
        reloadRestrictedContainerRoot()
    }

    /// Keep the loading row in its own view so the compiler does not have to
    /// infer it as part of FileBrowserView's already large List expression.
    private var loadingFilesSection: some View {
        Section {
            VStack(alignment: .leading) {
                HStack {
                    ProgressView()
                        .offset(y: 0.5)
                    Text(isBundleApplicationRoot ? "Loading app metadata..." : "Loading Files...")
                        .fontWeight(.medium)
                }
                if isContainer && !isBundleApplicationRoot {
                    containerLoadingNote
                } else if CoreMediaVirtualSystemPathReader.isRootPath(path) {
                    usrLibexecLoadingNote
                }
            }
        }
    }

    private var containerLoadingNote: some View {
        Text("These files could take 30 seconds or longer to load, since the method of getting container paths is very slow.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var usrLibexecLoadingNote: some View {
        Text("These files could take 2-3 seconds to load.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    /// Refresh the existing listing when re-entering the Apps/System container
    /// roots. This does not launch Airlift or diagnostic scans; it only invalidates
    /// the cached view result so handleBrowserAppear uses the normal reader again.
    private var refreshContainerListingOnEntry: Bool {
        guard isContainer else { return false }
        let current = Self.normalizedContainerPath(path.standardizedFileURL.path)
        let refreshRoots = [
            Self.normalizedContainerPath(FSURL.appPlugins.standardizedFileURL.path),
            Self.normalizedContainerPath(FSURL.internalDaemons.standardizedFileURL.path),
            Self.normalizedContainerPath(FSURL.sysGroup.standardizedFileURL.path)
        ]
        return refreshRoots.contains(current)
    }

    /// Performs the initial directory load outside the large SwiftUI modifier
    /// expression. Keeping this logic in a concrete method avoids Release-build
    /// type-checker timeouts inside the chained List modifiers.
    private func handleBrowserAppear() {
        if refreshContainerListingOnEntry && !isLoading {
            hasLoaded = false
        }

        if isDataApplicationContainerRoot {
            airlift.scanInstalledAppContainersForDataBrowserIfNeeded()
        }

        if isBundleApplicationRoot {
            airlift.scanInstalledAppBundlePathsIfNeeded()
        } else if isRestrictedContainerRoot {
            // InstallationProxy is reserved for Data/Application and App Groups.
            // InternalDaemon, PluginKitPlugin, and SystemGroup use their own readers.
            if restrictedContainerRootKind == "appGroups" {
                airlift.maybeAutoScanInstalledAppContainers()
            }
            if restrictedContainerRootKind == "plugins" {
                if (airlift.pluginKitPluginBadQueryLog.isEmpty
                    || airlift.pluginKitPluginBadQueryInodeLimit != Int64(maxInode))
                    && !airlift.pluginKitPluginBadQueryRunning {
                    airlift.scanAdditionalContainerRootWithBadQuery(
                        path.standardizedFileURL.path,
                        maxInode: Int64(maxInode)
                    )
                }
                if airlift.pluginKitPluginBadQueryRunning {
                    isLoading = true
                    hasLoaded = false
                    showFailure = false
                    return
                }
            }
        }

        guard !hasLoaded else { return }

        if !mgr.storedFiles.isEmpty,
           mgr.storedURL == path,
           !isRestrictedContainerRoot,
           !isBundleApplicationRoot {
            unfilteredFiles = sortFiles(files: mgr.storedFiles)
            hasLoaded = true
            isLoading = false
            showFailure = false
            return
        }

        if fixedFiles != nil {
            // Fixed-file views intentionally do not require the parent directory
            // itself to be listable. Each supplied URL is handled as a file.
            loadFilesFromPath()
            return
        }

        if CoreMediaVirtualSystemPathReader.containsVirtualPath(path) {
            // CoreMedia-backed system directories are never enumerated through
            // local FileManager APIs; the selected reader owns the XPC session.
            loadFilesFromPath()
            return
        }

        if isContainer {
            // Match original Erosion: enumerate container roots with
            // bad_query_list; grant each returned container with Worse Query
            // when the user opens that directory.
            loadFilesFromPath()
            return
        }

        if shouldGrant {
            // Request access to this concrete directory using the original
            // Worse Query mechanism. Do not fall back to the mod's WQ adapter.
            let result = acquireContainerAccess(at: path)
            if result.0 {
                loadFilesFromPath()
            } else {
                showFailure = true
                failMsg = "You don't have permission to view this directory. \(result.1)"
            }
            return
        }

        if effectiveReadOnly {
            if SystemReadOnlyAccess.canReadDirectory(path) {
                loadFilesFromPath()
            } else {
                showFailure = true
                failMsg = "This system path is not readable by the current process."
            }
            return
        }

        loadFilesFromPath()
    }

    var body: some View {
        browserContent.modifier(
            FileBrowserLifecycleModifier(
                airlift: airlift,
                chosenSort: chosenSort,
                filesAscend: filesAscend,
                refreshFiles: mgr.refreshFiles,
                handle: handleBrowserLifecycleEvent
            )
        )
    }

    private var browserContent: some View {
        List {
            // Keep the previous snapshot visible during refreshes. Replacing the
            // whole List with a spinner caused rows to disappear/reappear after
            // mutations and when SwiftUI rebuilt the filtered search results.
            if unfilteredFiles.isEmpty && isLoading {
                loadingFilesSection
            } else if unfilteredFiles.isEmpty && showFailure {
                CompactAlert(title: "Failed to load files from directory!", symbol: "folder.badge.questionmark", text: failMsg)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } else {
                ForEach(visibleFiles) { file in
                    makeBrowserItemRow(for: file)
                }
            }
        }
        .navigationTitle(navigationTitleOverride ?? path.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .customListStyle(listStyle)
        .adaptiveListMargin()
        .modifier(ConditionalFileBrowserSearch(text: $searchText, enabled: !hasAirliftWriteContext))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                    ForEach(FileSortMode.allCases, id: \.self) { option in
                        Button {
                            chosenSort = option
                        } label: {
                            if chosenSort == option {
                                Label(option.label, systemImage: "checkmark")
                                    .tag(option)
                            } else {
                                Text(option.label)
                                    .tag(option)
                            }
                        }
                    }
                    Divider()
                    Button {
                        filesAscend.toggle()
                    } label: {
                        if filesAscend {
                            Label("Ascending", systemImage: "chevron.up")
                        } else {
                            Label("Descending", systemImage: "chevron.down")
                        }
                    }
                    .disabled(chosenSort == .system)
                } label: {
                    Label("Sort", systemImage: "line.3.horizontal.decrease")
                }
                    .labelStyle(.iconOnly)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !isContainer && !effectiveReadOnly {
                        Menu {
                            Button {
                                Alertinator.shared.prompt(title: "What would you like to call your new file? Make sure you attach an extension at the end.", placeholder: "new.txt", completion: { name in
                                    let name = name ?? ""
                                    guard !name.isEmpty else { return }
                                    if hasAirliftWriteContext && !remoteMutationAllowed() {
                                        Alertinator.shared.alert(title: "Airlift write unavailable", body: "Enable LocalDevVPN and make sure the pairing file is imported.")
                                        return
                                    }
                                    let fileURL = path.appendingPathComponent(name)
                                    do {
                                        try Data().write(to: fileURL)
                                    } catch {
                                        Alertinator.shared.alert(title: "Failed to create file!", body: error.localizedDescription)
                                        return
                                    }
                                    guard let remotePath = remotePath(for: fileURL) else {
                                        mgr.refreshFiles.toggle()
                                        return
                                    }
                                    Task {
                                        let ok = await AirliftBridge.shared.writeBack(localURL: fileURL, remotePath: remotePath)
                                        await MainActor.run {
                                            if ok {
                                                mgr.refreshFiles.toggle()
                                            } else {
                                                try? fm.removeItem(at: fileURL)
                                                Alertinator.shared.alert(title: "Failed to create file!", body: "The remote Airlift write failed. Check the Airlift log.")
                                            }
                                        }
                                    }
                                })
                            } label: {
                                Label("File", systemImage: "doc")
                            }

                            Button {
                                Alertinator.shared.prompt(title: "What would you like to call your new property list?", placeholder: "Plist Name", completion: { name in
                                    let name = name ?? ""
                                    guard !name.isEmpty else { return }
                                    if hasAirliftWriteContext && !remoteMutationAllowed() {
                                        Alertinator.shared.alert(title: "Airlift write unavailable", body: "Enable LocalDevVPN and make sure the pairing file is imported.")
                                        return
                                    }
                                    let fileURL = path.appendingPathComponent(name + ".plist")
                                    do {
                                        let data = try PropertyListSerialization.data(fromPropertyList: NSMutableDictionary(), format: .xml, options: 0)
                                        try data.write(to: fileURL)
                                    } catch {
                                        Alertinator.shared.alert(title: "Failed to create property list!", body: error.localizedDescription)
                                        return
                                    }
                                    guard let remotePath = remotePath(for: fileURL) else {
                                        mgr.refreshFiles.toggle()
                                        return
                                    }
                                    Task {
                                        let ok = await AirliftBridge.shared.writeBack(localURL: fileURL, remotePath: remotePath)
                                        await MainActor.run {
                                            if ok {
                                                mgr.refreshFiles.toggle()
                                            } else {
                                                try? fm.removeItem(at: fileURL)
                                                Alertinator.shared.alert(title: "Failed to create property list!", body: "The remote Airlift write failed. Check the Airlift log.")
                                            }
                                        }
                                    }
                                })
                            } label: {
                                Label("Property List", systemImage: "tablecells")
                            }

                            Button {
                                Alertinator.shared.prompt(title: "What would you like to call your new folder?", placeholder: "Folder Name", completion: { name in
                                    let name = name ?? ""
                                    guard !name.isEmpty else { return }
                                    if hasAirliftWriteContext && !remoteMutationAllowed() {
                                        Alertinator.shared.alert(title: "Airlift write unavailable", body: "Enable LocalDevVPN and make sure the pairing file is imported.")
                                        return
                                    }
                                    let folderURL = path.appendingPathComponent(name, isDirectory: true)
                                    do {
                                        try fm.createDirectory(at: folderURL, withIntermediateDirectories: false)
                                    } catch {
                                        Alertinator.shared.alert(title: "Failed to create folder!", body: error.localizedDescription)
                                        return
                                    }
                                    guard let remotePath = remotePath(for: folderURL) else {
                                        mgr.refreshFiles.toggle()
                                        return
                                    }
                                    Task {
                                        let ok = await AirliftBridge.shared.createRemoteDirectory(localURL: folderURL, remotePath: remotePath)
                                        await MainActor.run {
                                            if ok {
                                                mgr.refreshFiles.toggle()
                                            } else {
                                                try? fm.removeItem(at: folderURL)
                                                Alertinator.shared.alert(title: "Failed to create folder!", body: "The remote Airlift directory creation failed. Check the Airlift log.")
                                            }
                                        }
                                    }
                                })
                            } label: {
                                Label("Folder", systemImage: "folder")
                            }

                            Button {
                                Alertinator.shared.prompt(title: "Where would you like your new symlink to point to?", placeholder: "/path/to/dir", completion: { symPath in
                                    let symPath = symPath ?? ""
                                    guard !symPath.isEmpty else { return }
                                    if hasAirliftWriteContext {
                                        Alertinator.shared.alert(title: "Symlink write unavailable", body: "The current Airlift write API does not preserve a new symbolic link, so no local or remote change was made.")
                                        return
                                    }
                                    do {
                                        try fm.createSymbolicLink(atPath: path.appendingPathComponent(URL(fileURLWithPath: symPath).lastPathComponent).path, withDestinationPath: symPath)
                                        mgr.refreshFiles.toggle()
                                    } catch {
                                        Alertinator.shared.alert(title: "Failed to create symlink!", body: error.localizedDescription)
                                    }
                                })
                            } label: {
                                Label("Symlink", systemImage: "arrow.up.right.circle")
                            }
                        } label: {
                            Label("New...", systemImage: "plus")
                        }

                        Button {
                            showFileImporter.toggle()
                        } label: {
                            Label("Import File", systemImage: "arrow.down.doc")
                        }
                    }
                Divider()
                NavigationLink {
                    FileBrowserView(path: URL.documentsDirectory)
                } label: {
                    Label("Open App Docs", systemImage: "folder")
                }
                NavigationLink {
                    List {
                        Section {
                            HStack {
                                Text("Max Inode")
                                TextField("7500000", value: $maxInode, format: .number)
                                    .multilineTextAlignment(.trailing)
                            }
                        } header: {
                            HeaderLabel("Container Fetching", symbol: "externaldrive")
                        } footer: {
                            Text("This controls how quickly files can load. Lower values = faster fetching but less files.")
                        }

                        Section {
                            Picker("List Style", selection: $listStyle) {
                                Text("Default").tag(1)
                                Text("Plain").tag(2)
                                Text("Grouped").tag(3)
                            }
                            Toggle("Hide Dates", isOn: $hideDates)
                        } header: {
                            HeaderLabel("View Options", symbol: "eye")
                        }

                        Section {
                            Stepper(value: $textViewerSize) {
                                HStack {
                                    Text("Text Size")
                                    Spacer()
                                    Text(textViewerSize.description)
                                }
                            }
                            Toggle("Monospaced Font", isOn: $useMonospaced)
                        } header: {
                            HeaderLabel("Text Viewer", symbol: "doc.plaintext")
                        }
                    }
                    .navigationTitle("File Browser Settings")
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                } label: {
                    Label("Actions", systemImage: "ellipsis")
                }
                .labelStyle(.iconOnly)
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            handleImport(result)
        }
        .refreshable {
            mgr.refreshFiles.toggle()
        }
    }
    
    private static func makeBundleMetadataItem(path: String, displayName: String) -> FileItem {
        var item = getFileItem(at: URL(fileURLWithPath: path, isDirectory: true))
        item.name = displayName
        item.type = .folder
        item.uttype = .folder
        return item
    }

    // MARK: handle files
    private func loadFilesFromPath() {
        if isBundleApplicationRoot {
            guard !airlift.appScanRunning else {
                isLoading = true
                hasLoaded = false
                showFailure = false
                return
            }

            let rows = airlift.installedAppBundlePaths.map { entry in
                Self.makeBundleMetadataItem(path: entry.path, displayName: entry.displayName)
            }
            unfilteredFiles = sortFiles(files: rows)
            isLoading = false
            hasLoaded = true
            showFailure = rows.isEmpty && !airlift.appScanLog.isEmpty
            if rows.isEmpty {
                let scanIssue = airlift.appScanLog.first(where: {
                    $0.localizedCaseInsensitiveContains("no pairing")
                        || $0.localizedCaseInsensitiveContains("failed")
                        || $0.localizedCaseInsensitiveContains("waiting")
                })
                failMsg = scanIssue ?? "Please ensure you turned localdev on and have valid pairing file."
                showFailure = true
            } else {
                failMsg = ""
                showFailure = false
            }
            return
        }


        // Pull-to-refresh can fire repeatedly before CoreMedia finishes a root
        // listing. Let the in-flight request finish instead of creating another
        // XPC memory-origin handshake for the same virtual directory.
        if CoreMediaVirtualSystemPathReader.containsVirtualPath(path), isLoading {
            return
        }

        // Metadata can be published in several updates when InstallationProxy
        // completes. Only the newest directory request may commit its result.
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        showFailure = false
        failMsg = ""
        let requestedPath = path
        let fixedPathItems = fixedFiles
        let containerMode = isContainer
        let maxInodeLimit = Int64(maxInode)
        let restrictedRootKind = restrictedContainerRootKind
        let restrictedMetadataPaths = restrictedContainerMetadataPaths(for: restrictedRootKind)
        let dataApplicationRoot = isDataApplicationContainerRoot
        let installationProxyDataPaths = dataApplicationRoot
            && airlift.airliftFeatureReady()
            && airlift.installedAppContainerScanReady
            ? airlift.installedAppContainers.map(\.container)
            : []
        let airliftRemoteRootPath = airliftRemoteRoot

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var unsortedFiles: [FileItem] = []
                if let rootKind = restrictedRootKind {
                    let paths = try Self.restrictedContainerPaths(
                        rootKind: rootKind,
                        rootURL: requestedPath,
                        metadataPaths: restrictedMetadataPaths,
                        maxInodeLimit: maxInodeLimit
                    )
                    unsortedFiles = paths.map { Self.makeRestrictedContainerItem(path: $0) }
                } else if let fixedPathItems {
                    let makeItems = {
                        fixedPathItems.map { url in
                            CoreMediaVirtualSystemPathReader.isRootPath(url)
                                ? CoreMediaVirtualSystemPathReader.rootFolderItem(at: url)
                                : getFileItem(at: url)
                        }
                    }
                    // Keep InstallationProxy bundle path rows metadata-only.
                    unsortedFiles = makeItems()
                } else if CoreMediaVirtualSystemPathReader.containsVirtualPath(requestedPath) {
                    unsortedFiles = try CoreMediaVirtualSystemPathReader.listDirectory(at: requestedPath)
                } else if containerMode {
                    // Worse Query remains the primary Data/Application enumerator.
                    // When pairing and LocalDevVPN are active, InstallationProxy adds
                    // any missing UUID paths; it never opens or reads those paths.
                    let paths = fsHandlers.getDirPaths(requestedPath.path, maxInode: maxInodeLimit)
                    unsortedFiles = paths.map { getFileItem(at: URL(fileURLWithPath: $0), isContainer: true) }

                    if dataApplicationRoot && !installationProxyDataPaths.isEmpty {
                        var knownPaths = Set(paths.map { Self.normalizedContainerPath($0) })
                        let root = Self.normalizedContainerPath(requestedPath.standardizedFileURL.path)
                        for candidate in installationProxyDataPaths {
                            let normalized = Self.normalizedContainerPath(candidate)
                            let url = URL(fileURLWithPath: normalized, isDirectory: true)
                            guard url.deletingLastPathComponent().standardizedFileURL.path == root,
                                  UUID(uuidString: url.lastPathComponent) != nil,
                                  knownPaths.insert(normalized).inserted else { continue }
                            var item = getFileItem(at: url, isContainer: true)
                            item.type = .folder
                            item.uttype = .folder
                            item.destURL = url
                            unsortedFiles.append(item)
                        }
                    }
                } else {
                    // getFileItem now takes one lstat snapshot per entry. Asking
                    // Foundation for resourceValues here as well would duplicate
                    // metadata syscalls for every item in large system folders.
                    let pathFiles = try fm.contentsOfDirectory(
                        at: requestedPath,
                        includingPropertiesForKeys: nil
                    )
                    let makeItems = {
                        pathFiles.map { fileURL in
                            if requestedPath == FSURL.appGroup || requestedPath == FSURL.systemData {
                                return getFileItem(at: fileURL, isContainer: true)
                            }
                            return getFileItem(at: fileURL)
                        }
                    }
                    // App bundle roots intentionally remain metadata-only labels.
                    unsortedFiles = makeItems()
                }

                if let remoteRoot = airliftRemoteRootPath {
                    if Self.usesWirelessPOSIXIdentity(remotePath: remoteRoot) {
                        // /var/wireless is owned by the wireless service. Airlift
                        // snapshots are local copies, so local lstat identities
                        // cannot be used for the remote filesystem owner/group.
                        for index in unsortedFiles.indices {
                            unsortedFiles[index].owner = "_wireless"
                            unsortedFiles[index].group = "_wireless"
                        }
                    } else if !Self.usesMobilePOSIXIdentity(remotePath: remoteRoot) {
                        for index in unsortedFiles.indices {
                            unsortedFiles[index].owner = "root"
                            unsortedFiles[index].group = "wheel"
                        }
                    }
                }

                DispatchQueue.main.async {
                    guard self.loadGeneration == generation else { return }
                    var finalFiles = unsortedFiles
                    if dataApplicationRoot
                        && AirliftBridge.shared.airliftFeatureReady()
                        && AirliftBridge.shared.installedAppContainerScanReady {
                        let root = Self.normalizedContainerPath(requestedPath.standardizedFileURL.path)
                        var knownPaths = Set(finalFiles.map {
                            Self.normalizedContainerPath($0.fileURL.standardizedFileURL.path)
                        })
                        for entry in AirliftBridge.shared.installedAppContainers {
                            let normalized = Self.normalizedContainerPath(entry.container)
                            let url = URL(fileURLWithPath: normalized, isDirectory: true)
                            guard url.deletingLastPathComponent().standardizedFileURL.path == root,
                                  UUID(uuidString: url.lastPathComponent) != nil,
                                  knownPaths.insert(normalized).inserted else { continue }
                            var item = getFileItem(at: url, isContainer: true)
                            item.type = .folder
                            item.uttype = .folder
                            item.destURL = url
                            finalFiles.append(item)
                        }
                    }

                    self.unfilteredFiles = self.sortFiles(files: finalFiles)
                    if containerMode && requestedPath.standardizedFileURL.path != FSPaths.appBundles {
                        self.mgr.storedFiles = finalFiles
                        self.mgr.storedURL = requestedPath
                    }
                    self.hasLoaded = true
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.loadGeneration == generation else { return }
                    self.showFailure = true
                    if CoreMediaVirtualSystemPathReader.shouldSuggestAppReopen(for: error, at: requestedPath) {
                        let reopenMessage = CoreMediaVirtualSystemPathReader.reopenAppMessage
                        print("(fm) \(reopenMessage)")
                        self.failMsg = reopenMessage
                    } else {
                        print("(fm) failed to load files from \(requestedPath): \(error.localizedDescription)")
                        self.failMsg = "You may not have permission to view this directory. Check error logs for more detailed info."
                    }
                    self.isLoading = false
                }
            }
        }
    }
    

    private static func usesWirelessPOSIXIdentity(remotePath: String) -> Bool {
        let path = URL(fileURLWithPath: remotePath).standardizedFileURL.path
        return path == "/var/wireless" || path.hasPrefix("/var/wireless/")
            || path == "/private/var/wireless" || path.hasPrefix("/private/var/wireless/")
    }

    private static func usesMobilePOSIXIdentity(remotePath: String) -> Bool {
        let path = URL(fileURLWithPath: remotePath).standardizedFileURL.path
        let allowedRoots = [
            "/var/mobile",
            "/var/tmp",
            "/var/Managed Preferences/mobile"
        ]
        return allowedRoots.contains { root in
            path == root || path.hasPrefix(root + "/")
        }
    }

    private func sortFiles(files: [FileItem]) -> [FileItem] {
        var sortedFiles: [FileItem]
        
        switch chosenSort {
        case .system:
            sortedFiles = files
        case .name:
            sortedFiles = files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .date:
            sortedFiles = files.sorted { $0.modifiedDate > $1.modifiedDate }
        case .type:
            sortedFiles = files.sorted { $0.type.sortOrder < $1.type.sortOrder }
        case .size:
            sortedFiles = files.sorted { $0.size < $1.size }
        }

        sortedFiles = filesAscend ? sortedFiles : sortedFiles.reversed()
        sortedFiles = sortedFiles.sorted { a, b in
            a.hidden && !b.hidden
        }
        return sortedFiles
    }
    
    // MARK: handle import
    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let fileURL):
            let stopAccess = fileURL.startAccessingSecurityScopedResource()
            defer {
                if stopAccess { fileURL.stopAccessingSecurityScopedResource() }
            }

            if hasAirliftWriteContext && !remoteMutationAllowed() {
                Alertinator.shared.alert(title: "Airlift write unavailable", body: "Enable LocalDevVPN and make sure the pairing file is imported.")
                return
            }

            let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let newURL = path.appendingPathComponent(fileURL.lastPathComponent, isDirectory: isDirectory)
            do {
                if fm.fileExists(atPath: newURL.path) {
                    throw NSError(domain: "Erosion.FileBrowser", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "A file with this name already exists."])
                }
                try fm.copyItem(at: fileURL, to: newURL)
            } catch {
                print("(fm) failed to import file: \(error.localizedDescription)")
                Alertinator.shared.alert(title: "Failed to import file!", body: error.localizedDescription)
                return
            }

            guard let remotePath = remotePath(for: newURL) else {
                mgr.refreshFiles.toggle()
                return
            }

            Task {
                let ok: Bool
                if isDirectory {
                    ok = await AirliftBridge.shared.createRemoteDirectory(localURL: newURL, remotePath: remotePath)
                } else {
                    ok = await AirliftBridge.shared.writeBack(localURL: newURL, remotePath: remotePath)
                }
                await MainActor.run {
                    if ok {
                        mgr.refreshFiles.toggle()
                    } else {
                        try? fm.removeItem(at: newURL)
                        Alertinator.shared.alert(title: "Failed to import file!", body: "The remote Airlift write failed. Check the Airlift log.")
                    }
                }
            }

        case .failure(let error):
            print("(fm) failed to import file: \(error.localizedDescription)")
            Alertinator.shared.alert(title: "Failed to import file!", body: error.localizedDescription)
        }
    }

}

// MARK: user interface
extension View {
    @ViewBuilder
    func customListStyle(_ selection: Int) -> some View {
        switch selection {
        case 2: self.listStyle(.inset)
        case 3: self.listStyle(.grouped)
        default: self.listStyle(.insetGrouped)
        }
    }
    
    @ViewBuilder
    func adaptiveListMargin() -> some View {
        if #available(iOS 26.0, *) {
            self.contentMargins(.top, 1)
        }
    }
}


