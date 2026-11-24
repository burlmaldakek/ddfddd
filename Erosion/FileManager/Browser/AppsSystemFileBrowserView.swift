//
//  FileBrowserView.swift
//  AccessiblePlus
//
//  Created by lunginspector on 5/12/26.
//

import SwiftUI
import QuickLook
import Combine

struct AppsSystemFileBrowserView: View {
    @EnvironmentObject var mgr: ErosionManager
    @ObservedObject private var airlift = AirliftBridge.shared
    var path: URL = URL(fileURLWithPath: "/")
    var isContainer = false
    var shouldGrant = false
    
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

    /// Keep the complete directory snapshot intact and derive search results from it.
    /// This mirrors FileBrowserView and prevents refresh/keyboard events from
    /// replacing filtered results with stale or unfiltered rows.
    private var visibleFiles: [FileItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return unfilteredFiles }
        return unfilteredFiles.filter { file in
            file.name.localizedCaseInsensitiveContains(query)
                || file.fileURL.path.localizedCaseInsensitiveContains(query)
        }
    }
    
    var body: some View {
        List {
            if isLoading {
                Section {
                    VStack(alignment: .leading) {
                        HStack {
                            ProgressView()
                                .offset(y: 0.5)
                            Text("Loading Files...")
                                .fontWeight(.medium)
                        }
                        if isContainer {
                            Text("These files could take 30 seconds or longer to load, since the method of getting container paths is very slow.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if showFailure {
                CompactAlert(title: "Failed to load files from directory!", symbol: "folder.badge.questionmark", text: failMsg)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } else {
                ForEach(visibleFiles) { file in
                    if file.type == .folder {
                        AppsSystemFolderRow(file: file, shouldGrant: shouldGrant || isContainer, isContainer: isContainer)
                    } else {
                        AppsSystemFileRow(file: file)
                    }
                }
            }
        }
        .navigationTitle(path.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .customListStyle(listStyle)
        .adaptiveListMargin()
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic))
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
                    if !isContainer {
                        Menu {
                            Button {
                                Alertinator.shared.prompt(title: "What would you like to call your new file? Make sure you attach an extension at the end.", placeholder: "new.txt", completion: { name in
                                    let name = name ?? ""
                                    if !name.isEmpty {
                                        do {
                                            let fileURL = path.appendingPathComponent(name)
                                            try Data().write(to: fileURL)
                                            mgr.refreshFiles.toggle()
                                        } catch {
                                            print("(fm) failed to create file: \(error.localizedDescription)")
                                            Alertinator.shared.alert(title: "Failed to create file!", body: Errors.checkLogs)
                                        }
                                    }
                                })
                            } label: {
                                Label("File", systemImage: "doc")
                            }
                            
                            Button {
                                Alertinator.shared.prompt(title: "What would you like to call your new property list?", placeholder: "Plist Name", completion: { name in
                                    let name = name ?? ""
                                    if !name.isEmpty {
                                        do {
                                            let fileURL = path.appendingPathComponent(name + ".plist")
                                            let data = try PropertyListSerialization.data(fromPropertyList: NSMutableDictionary(), format: .xml, options: 0)
                                            try data.write(to: fileURL)
                                            mgr.refreshFiles.toggle()
                                        } catch {
                                            print("(fm) failed to create plist: \(error.localizedDescription)")
                                            Alertinator.shared.alert(title: "Failed to create property list!", body: Errors.checkLogs)
                                        }
                                    }
                                })
                            } label: {
                                Label("Property List", systemImage: "tablecells")
                            }
                            
                            Button {
                                Alertinator.shared.prompt(title: "What would you like to call your new folder?", placeholder: "Folder Name", completion: { name in
                                    let name = name ?? ""
                                    if !name.isEmpty {
                                        do {
                                            try fm.createDirectoryIfNeeded(at: path.appendingPathComponent(name))
                                            mgr.refreshFiles.toggle()
                                        } catch {
                                            print("(fm) failed to create folder: \(error.localizedDescription)")
                                            Alertinator.shared.alert(title: "Failed to create folder!", body: Errors.checkLogs)
                                        }
                                    }
                                })
                            } label: {
                                Label("Folder", systemImage: "folder")
                            }
                            
                            Button {
                                Alertinator.shared.prompt(title: "Where would you like your new symlink to point to?", placeholder: "/path/to/dir", completion: { symPath in
                                    let symPath = symPath ?? ""
                                    if !symPath.isEmpty {
                                        do {
                                            try fm.createSymbolicLink(atPath: path.appendingPathComponent(URL(fileURLWithPath: symPath).lastPathComponent).path, withDestinationPath: symPath)
                                            mgr.refreshFiles.toggle()
                                        } catch {
                                            print("(fm) failed to create symlink: \(error.localizedDescription)")
                                            Alertinator.shared.alert(title: "Failed to create symlink!", body: "\(error.localizedDescription)")
                                        }
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
                        Divider()
                    }
                    NavigationLink {
                        AppsSystemFileBrowserView(path: URL.documentsDirectory)
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
        .onAppear {
            // Do not reload an already populated parent List when returning from
            // a nested directory. The generic/CVE File Browser keeps this state;
            // re-running the filesystem enumeration here resets the scroll offset.
            guard !hasLoaded else { return }

            // Preserve the existing optional InstallationProxy path-discovery layer
            // for Data/Application. Worse Query remains responsible for every grant
            // and all local filesystem operations in this browser.
            if isDataApplicationContainerRoot {
                airlift.scanInstalledAppContainersForDataBrowserIfNeeded()
            }
            if shouldGrant {
                let res = wq.grantAccess(path: path.path)
                if res.0 {
                    loadFilesFromPath()
                } else {
                    showFailure = true
                    failMsg = "You don't have permission to view this directory."
                }
            } else {
                loadFilesFromPath()
            }
        }
        .onChange(of: chosenSort) {
            loadFilesFromPath()
        }
        .onChange(of: filesAscend) {
            loadFilesFromPath()
        }
        .onChange(of: mgr.refreshFiles) {
            loadFilesFromPath()
        }
        .onChange(of: airlift.installedAppContainers) { _, _ in
            mergeInstallationProxyDataContainerRows()
        }
    }

    private var isDataApplicationContainerRoot: Bool {
        isContainer && Self.normalizedContainerPath(path.standardizedFileURL.path)
            == Self.normalizedContainerPath(FSURL.appContainers.standardizedFileURL.path)
    }

    private static func normalizedContainerPath(_ value: String) -> String {
        var normalized = value.hasPrefix("/private/var/")
            ? String(value.dropFirst("/private".count))
            : value
        if normalized.hasPrefix("/var/containers/Data/Application/") {
            normalized = "/var/mobile/Containers/Data/Application/"
                + normalized.dropFirst("/var/containers/Data/Application/".count)
        }
        return normalized
    }

    /// Merge InstallationProxy paths without replacing the original WQ listing.
    /// The returned metadata contributes paths only; it never opens container data.
    private func mergeInstallationProxyDataContainerRows() {
        guard isDataApplicationContainerRoot,
              airlift.airliftFeatureReady(),
              airlift.installedAppContainerScanReady else { return }

        let root = Self.normalizedContainerPath(FSURL.appContainers.standardizedFileURL.path)
        var known = Set(unfilteredFiles.map {
            Self.normalizedContainerPath($0.fileURL.standardizedFileURL.path)
        })
        var additions: [FileItem] = []

        for entry in airlift.installedAppContainers {
            let normalized = Self.normalizedContainerPath(entry.container)
            let url = URL(fileURLWithPath: normalized, isDirectory: true)
            guard url.deletingLastPathComponent().standardizedFileURL.path == root,
                  UUID(uuidString: url.lastPathComponent) != nil,
                  known.insert(normalized).inserted else { continue }

            var item = getAppsSystemFileItem(at: url, isContainer: true)
            item.type = .folder
            item.uttype = .folder
            item.destURL = url
            additions.append(item)
        }

        guard !additions.isEmpty else { return }
        let merged = sortFiles(files: unfilteredFiles + additions)
        unfilteredFiles = merged
        hasLoaded = true
        showFailure = false
    }
    
    // MARK: handle files
    private func loadFilesFromPath() {
        isLoading = true
        let requestedPath = path
        let containerMode = isContainer
        let dataApplicationRoot = isDataApplicationContainerRoot
        let inodeLimit = Int64(maxInode)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var unsortedFiles: [FileItem] = []
                if containerMode {
                    // Original Erosion container enumeration: Worse Query pathleak,
                    // with the user-configured inode ceiling.
                    let paths = fsHandlers.getWorseQueryDirPaths(requestedPath.path, maxInode: inodeLimit)
                    for candidate in paths {
                        unsortedFiles.append(getAppsSystemFileItem(
                            at: URL(fileURLWithPath: candidate),
                            isContainer: true
                        ))
                    }
                } else {
                    let pathFiles = try fm.contentsOfDirectory(
                        at: requestedPath,
                        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
                    )
                    unsortedFiles = pathFiles.map { fileURL in
                        if requestedPath == FSURL.appGroup || requestedPath == FSURL.systemData {
                            return getAppsSystemFileItem(at: fileURL, isContainer: true)
                        }
                        return getAppsSystemFileItem(at: fileURL)
                    }
                }

                DispatchQueue.main.async {
                    var finalFiles = unsortedFiles

                    // Read the latest completed InstallationProxy snapshot at commit
                    // time. If its callback raced with the WQ listing, this prevents
                    // the slower listing from replacing the metadata-only additions.
                    if dataApplicationRoot,
                       AirliftBridge.shared.airliftFeatureReady(),
                       AirliftBridge.shared.installedAppContainerScanReady {
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
                            var item = getAppsSystemFileItem(at: url, isContainer: true)
                            item.type = .folder
                            item.uttype = .folder
                            item.destURL = url
                            finalFiles.append(item)
                        }
                    }

                    let sorted = self.sortFiles(files: finalFiles)
                    self.unfilteredFiles = sorted
                    self.hasLoaded = true
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    print("(fm) failed to load files from \(requestedPath): \(error.localizedDescription)")
                    self.showFailure = true
                    self.failMsg = "You may not have permission to view this directory. Check error logs for more detailed info."
                    self.isLoading = false
                }
            }
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
            do {
                let stopAccess = fileURL.startAccessingSecurityScopedResource()
                defer {
                    if stopAccess {
                        fileURL.stopAccessingSecurityScopedResource()
                    }
                }
                let data = try Data(contentsOf: fileURL)
                
                let newURL = path.appendingPathComponent(fileURL.lastPathComponent)
                try? fm.removeItem(at: newURL)
                
                try data.write(to: newURL)
                mgr.refreshFiles.toggle()
            } catch {
                print("(fm) failed to import file: \(error.localizedDescription)")
                Alertinator.shared.alert(title: "Failed to import file!", body: "\(error.localizedDescription)")
            }
        case .failure(let error):
            print("(fm) failed to import file: \(error.localizedDescription)")
            Alertinator.shared.alert(title: "Failed to import file!", body: "\(error.localizedDescription)")
        }
    }
}

struct KeyboardDismissObserver: ViewModifier {
    var action: () -> Void
    
    func body(content: Content) -> some View {
        content
            .onReceive(Publishers.keyboardDismissed) { _ in
                action()
            }
    }
}

extension Publishers {
    static var keyboardDismissed: AnyPublisher<Void, Never> {
        NotificationCenter.default
            .publisher(for: UIResponder.keyboardDidHideNotification)
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}
