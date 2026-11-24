//
//  FileRow.swift
//  AccessiblePlus
//
//  Created by lunginspector on 5/20/26.
//

import SwiftUI

import QuickLook
import ZIPFoundation

struct FileRow: View {
    private static let extendedPreviewExtensions: Set<String> = [
        "dylib", "bin", "so", "o", "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff",
        "gif", "webp", "mp4", "mov", "m4v", "mp3", "m4a", "wav", "aiff", "aif", "caf",
        "flac", "aac", "pdf", "svg", "car", "deb"
    ]
    private static let binaryPreviewExtensions: Set<String> = ["dylib", "bin", "so", "o", "deb"]
    private static let textFileExtensions: Set<String> = [
        "txt", "text", "log", "md", "markdown", "json", "xml", "strings", "stringsdict",
        "yaml", "yml", "conf", "cfg", "ini", "csv", "tsv", "sh", "bash", "zsh", "py",
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "js", "jsx", "ts", "tsx",
        "html", "htm", "css", "sql", "entitlements", "mobileprovision"
    ]

    @EnvironmentObject var mgr: ErosionManager
    @AppStorage("hideDates") var hideDates = false
    var file: FileItem
    var readOnly: Bool = false
    var airliftRemotePath: String? = nil
    var airliftRemoteRoot: String? = nil
    var airliftLocalRoot: String? = nil
    
    @State private var conformsText = false
    @State private var conformsPlist = false
    
    @State private var showInfo = false
    @State private var showPlistViewer = false
    @State private var showTextViewer = false
    @State private var showExtendedPreview = false
    @State private var previewURL: URL?
    @State private var virtualPreviewURL: URL?
    @State private var virtualPreviewDirectory: URL?
    @State private var isPreparingVirtualPreview = false
    @State private var isPreparingQuickLookPreview = false
    @State private var isPerformingVirtualFileAction = false
    
    private var useExtraViewers: Bool { true }

    private var supportsExtendedPreview: Bool {
        Self.extendedPreviewExtensions.contains(fileExtension)
    }

    private var isExtraViewerFile: Bool {
        Self.extraViewerExtensions.contains(fileExtension)
    }

    private static let extraViewerExtensions: Set<String> = [
        "dylib", "bin", "so", "o", "deb", "car", "png", "jpg", "jpeg",
        "heic", "heif", "tif", "tiff", "gif", "webp", "svg"
    ]

    private var isBinaryPreview: Bool {
        Self.binaryPreviewExtensions.contains(fileExtension)
    }

    /// Media files and CAR catalogs open in system Quick Look by default.
    /// CAR keeps its Erosion viewer as an explicit long-press option.
    private var isQuickLookMedia: Bool {
        Self.quickLookMediaExtensions.contains(fileExtension)
    }

    private static let quickLookMediaExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp", "svg",
        "mp4", "mov", "m4v", "mp3", "m4a", "wav", "aiff", "aif", "caf", "flac", "aac"
    ]

    private var isCAR: Bool { fileExtension == "car" }

    private var defaultsToQuickLook: Bool {
        isQuickLookMedia || isCAR || ["deb", "dylib", "bin"].contains(fileExtension)
    }

    private var fileExtension: String {
        file.fileURL.pathExtension.lowercased()
    }

    private var isKnownPlist: Bool {
        fileExtension == "plist" || file.uttype.conforms(to: .propertyList)
    }

    private var isKnownText: Bool {
        Self.textFileExtensions.contains(fileExtension) || file.uttype.conforms(to: .text)
    }

    private var isZipFile: Bool {
        fileExtension == "zip" || file.uttype.conforms(to: .zip)
    }

    private var canViewPlist: Bool { conformsPlist || isKnownPlist }
    // SVGs are image documents, even though Uniform Type Identifiers may also
    // classify their XML payload as text. Route them to the image viewer.
    // Binary packages and dynamic libraries stay in the hex viewer; do not
    // offer a second plain-text viewer for these two extensions.
    private var canViewText: Bool {
        !["dylib", "deb"].contains(fileExtension)
            && !isKnownPlist
            && fileExtension != "svg"
            && (conformsText || isKnownText)
    }

    /// Content sniffing is intentionally deferred until a user opens an unknown
    /// extension. Doing it from onAppear caused every file in a large directory
    /// to be read twice just to populate its row.
    private func openStandardFile() {
        if isZipFile && !readOnly {
            uncompressFileAndSync()
        } else if isQuickLookMedia || isCAR {
            openQuickLookMediaPreview()
        } else if defaultsToQuickLook {
            previewURL = file.fileURL
        } else if isBinaryPreview || supportsExtendedPreview {
            if isExtraViewerFile && !useExtraViewers {
                previewURL = file.fileURL
            } else {
                showExtendedPreview = true
            }
        } else if isKnownPlist {
            // Keep .plist files in the plist viewer instead of allowing the
            // generic text/Quick Look fallback to win on unusual encodings.
            conformsPlist = true
            conformsText = false
            showPlistViewer = true
        } else if isKnownText {
            // An extensionless SVG may have a text UTI, but it is still an image.
            if fileExtension.isEmpty,
               let imageExtension = detectedImageFileExtension(at: file.fileURL) {
                conformsPlist = false
                conformsText = false
                openQuickLookMediaPreview(imageExtensionOverride: imageExtension)
                return
            }
            // Known text files must be classified as text, not as scalar Property Lists.
            let isText = conformsToTextViewer(file.fileURL)
            conformsPlist = false
            conformsText = isText
            if isText {
                showTextViewer = true
            } else {
                previewURL = file.fileURL
            }
        } else {
            // For extensionless/unknown files, detect property-list dictionaries,
            // then UTF-8 text, then a genuine ImageIO image before falling back.
            let isPlist = conformsToPlistViewer(file.fileURL)
            let imageExtension = fileExtension.isEmpty
                ? detectedImageFileExtension(at: file.fileURL)
                : nil
            let isText = !isPlist && imageExtension == nil && conformsToTextViewer(file.fileURL)
            conformsPlist = isPlist
            conformsText = isText
            if isPlist {
                showPlistViewer = true
            } else if let imageExtension {
                openQuickLookMediaPreview(imageExtensionOverride: imageExtension)
            } else if isText {
                showTextViewer = true
            } else {
                previewURL = file.fileURL
            }
        }
    }

    private var isAirliftRemote: Bool {
        airliftRemotePath != nil && airliftRemoteRoot != nil && airliftLocalRoot != nil
    }

    private var isCoreMediaVirtualFile: Bool {
        CoreMediaVirtualSystemPathReader.containsVirtualPath(file.fileURL)
    }

    /// Materializes a read-only CoreMedia file into the app's temporary directory,
    /// then routes it through Erosion's existing generic viewers.
    @MainActor
    private func openVirtualFileWithStandardViewer(forceExtendedViewer: Bool = false) {
        guard !isPreparingVirtualPreview else { return }
        isPreparingVirtualPreview = true

        let remotePath = file.fileURL.path
        Task { @MainActor in
            defer { isPreparingVirtualPreview = false }
            var newDirectory: URL?
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try CoreMediaVirtualSystemPathReader.readFileData(atPath: remotePath)
                }.value

                let previewRoot = CoreMediaLibraryPathReader.containsVirtualPath(remotePath)
                    ? "ErosionLibraryVirtualPreviews"
                    : "ErosionVirtualPreviews"
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent(previewRoot, isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                newDirectory = directory
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

                var localURL = directory.appendingPathComponent(URL(fileURLWithPath: remotePath).lastPathComponent)
                try data.write(to: localURL, options: .atomic)
                let inferredImageExtension = localURL.pathExtension.isEmpty
                    ? detectedImageFileExtension(at: localURL)
                    : nil
                if let inferredImageExtension {
                    let imageURL = directory.appendingPathComponent(localURL.lastPathComponent + "." + inferredImageExtension)
                    try FileManager.default.moveItem(at: localURL, to: imageURL)
                    localURL = imageURL
                }

                let previousDirectory = virtualPreviewDirectory
                virtualPreviewDirectory = directory
                virtualPreviewURL = localURL
                if let previousDirectory {
                    try? FileManager.default.removeItem(at: previousDirectory)
                }

                conformsPlist = conformsToPlistViewer(localURL)
                conformsText = conformsToTextViewer(localURL)

                if isKnownPlist {
                    conformsPlist = true
                    conformsText = false
                    showPlistViewer = true
                } else if inferredImageExtension != nil {
                    previewURL = localURL
                } else if defaultsToQuickLook && !forceExtendedViewer {
                    previewURL = localURL
                } else if isBinaryPreview || supportsExtendedPreview {
                    if (isExtraViewerFile && !useExtraViewers) && !forceExtendedViewer {
                        previewURL = localURL
                    } else {
                        showExtendedPreview = true
                    }
                } else if conformsPlist {
                    showPlistViewer = true
                } else if conformsText {
                    showTextViewer = true
                } else {
                    previewURL = localURL
                }
            } catch {
                if let newDirectory {
                    try? FileManager.default.removeItem(at: newDirectory)
                }
                if CoreMediaVirtualSystemPathReader.shouldSuggestAppReopen(for: error, at: URL(fileURLWithPath: remotePath)) {
                    Alertinator.shared.alert(title: "Restart Erosion", body: CoreMediaVirtualSystemPathReader.reopenAppMessage)
                } else {
                    Alertinator.shared.alert(title: "Unable to Open File", body: error.localizedDescription)
                }
            }
        }
    }

    private var viewerFileURL: URL {
        virtualPreviewURL ?? file.fileURL
    }

    private func remoteSiblingPath(_ name: String) -> String? {
        guard let airliftRemotePath else { return nil }
        return URL(fileURLWithPath: airliftRemotePath)
            .deletingLastPathComponent()
            .appendingPathComponent(name)
            .path
    }

    private func remoteMutationAllowed() -> Bool {
        AirliftBridge.shared.fileBrowserWriteReady()
    }

    var body: some View {
        Group {
            if file.type == .file {
                Button {
                    if isCoreMediaVirtualFile {
                        openVirtualFileWithStandardViewer()
                    } else {
                        openStandardFile()
                    }
                } label: {
                    HStack(spacing: isSolariumUI() ? 12 : 10) {
                        Group {
                            if isPreparingVirtualPreview || isPreparingQuickLookPreview {
                                ProgressView()
                            } else {
                                Image(systemName: "doc")
                            }
                        }
                        .frame(width: 20, alignment: .center)
                        .foregroundStyle(file.hidden ? .secondary : .primary)

                        VStack(alignment: .leading) {
                            Text(file.name)
                                .foregroundStyle(file.hidden ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if !hideDates && !file.modifiedDateStr.isEmpty {
                                Text(file.modifiedDateStr)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Button {
                            showInfo.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, !hideDates && !file.modifiedDateStr.isEmpty && !isSolariumUI() ? 1 : 0)
                }
            } else {
                HStack(spacing: 0) {
                    NavigationLink(destination: FileBrowserView(
                        path: file.destURL,
                        readOnly: readOnly,
                        airliftRemoteRoot: airliftRemoteRoot,
                        airliftLocalRoot: airliftLocalRoot
                    )) {
                        HStack(spacing: isSolariumUI() ? 12 : 10) {
                            Image(systemName: "arrow.up.right.circle")
                                .frame(width: 20, alignment: .center)
                                .foregroundStyle(file.hidden ? .secondary : .primary)
                            Text(file.name)
                                .foregroundStyle(file.hidden ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)

                    Button { showInfo.toggle() } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, isSolariumUI() ? 12 : 10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(Color(.label))
        .sheet(isPresented: $showInfo) {
            InfoViewer(file, pathOverride: airliftRemotePath)
        }
        .sheet(isPresented: $showPlistViewer, onDismiss: cleanupVirtualPreview) {
            PlistViewer(viewerFileURL, remotePath: airliftRemotePath, readOnly: isCoreMediaVirtualFile)
        }
        .sheet(isPresented: $showTextViewer, onDismiss: cleanupVirtualPreview) {
            TextViewer(viewerFileURL, remotePath: airliftRemotePath, readOnly: isCoreMediaVirtualFile)
        }
        .sheet(isPresented: $showExtendedPreview, onDismiss: cleanupVirtualPreview) {
            NavigationStack {
                FilePreviewView(url: viewerFileURL, remotePath: airliftRemotePath, remoteWritable: !readOnly && isAirliftRemote)
            }
        }
        .onDisappear(perform: cleanupVirtualPreview)
        .onChange(of: previewURL) { newValue in
            if newValue == nil { cleanupVirtualPreview() }
        }
        .quickLookPreview($previewURL)
        .contextMenu {
            if isCoreMediaVirtualFile {
                Button {
                    openVirtualFileWithStandardViewer()
                } label: {
                    Label(isQuickLookMedia || isCAR ? "Quick Look" : "Preview", systemImage: "doc.text.magnifyingglass")
                }
                if defaultsToQuickLook && !isQuickLookMedia {
                    Button {
                        openVirtualFileWithStandardViewer(forceExtendedViewer: true)
                    } label: {
                        Label("Extended Viewer", systemImage: "photo.on.rectangle.angled")
                    }
                }
            } else if isQuickLookMedia {
                Button {
                    openQuickLookMediaPreview()
                } label: {
                    Label("Quick Look", systemImage: "eye")
                }
            } else if canViewText || canViewPlist || supportsExtendedPreview {
                Menu {
                    Button {
                        if isCAR || (fileExtension.isEmpty && detectedImageFileExtension(at: file.fileURL) != nil) {
                            openQuickLookMediaPreview(imageExtensionOverride: detectedImageFileExtension(at: file.fileURL))
                        } else {
                            previewURL = file.fileURL
                        }
                    } label: {
                        Label("Quick Look", systemImage: "eye")
                    }

                    if supportsExtendedPreview && (!isExtraViewerFile || useExtraViewers) {
                        Button {
                            showExtendedPreview = true
                        } label: {
                            Label("Extended Viewer", systemImage: "photo.on.rectangle.angled")
                        }
                    }
                    if canViewPlist {
                        Button {
                            showPlistViewer.toggle()
                        } label: {
                            Label("Plist Viewer", systemImage: "tablecells")
                        }
                    }

                    if canViewText {
                        Button {
                            showTextViewer.toggle()
                        } label: {
                            Label("Text Viewer", systemImage: "doc.plaintext")
                        }
                    }
                } label: {
                    Label("View In...", systemImage: "doc.text.magnifyingglass")
                }
            } else {
                Button {
                    if supportsExtendedPreview {
                        showExtendedPreview = true
                    } else {
                        openStandardFile()
                    }
                } label: {
                    Label("Preview", systemImage: "doc.text.magnifyingglass")
                }
            }

            Divider()

            Button {
                showInfo.toggle()
            } label: {
                Label("Get Info", systemImage: "info.circle")
            }

            if file.type == .file && !readOnly {
                Button {
                    Alertinator.shared.prompt(title: "What would you like to call this file?", placeholder: file.name, completion: { result in
                        if let name = result {
                            let oldURL = file.fileURL
                            let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(name)
                            if fm.fileExists(atPath: newURL.path) {
                                Alertinator.shared.alert(title: "Failed to rename file!", body: "A file with that name already exists.")
                                return
                            }

                            if isAirliftRemote {
                                guard remoteMutationAllowed(), let oldRemote = airliftRemotePath, let newRemote = remoteSiblingPath(name) else {
                                    Alertinator.shared.alert(title: "Airlift write unavailable", body: "Enable LocalDevVPN and make sure the pairing file is imported.")
                                    return
                                }
                                do {
                                    try fm.copyItem(at: oldURL, to: newURL)
                                } catch {
                                    Alertinator.shared.alert(title: "Failed to rename file!", body: error.localizedDescription)
                                    return
                                }

                                Task {
                                    let wrote = await AirliftBridge.shared.writeBack(localURL: newURL, remotePath: newRemote)
                                    var deletedOld = false
                                    if wrote {
                                        deletedOld = await AirliftBridge.shared.removeRemotePath(oldRemote)
                                        if !deletedOld {
                                            _ = await AirliftBridge.shared.removeRemotePath(newRemote)
                                        }
                                    }
                                    await MainActor.run {
                                        if wrote && deletedOld {
                                            try? fm.removeItem(at: oldURL)
                                            mgr.refreshFiles.toggle()
                                        } else {
                                            try? fm.removeItem(at: newURL)
                                            Alertinator.shared.alert(title: "Failed to rename file!", body: "The remote Airlift rename failed. Check the Airlift log.")
                                        }
                                    }
                                }
                            } else {
                                let res = renameFile(oldURL, to: name)
                                if res {
                                    mgr.refreshFiles.toggle()
                                } else {
                                    Alertinator.shared.alert(title: "Failed to rename file!", body: Errors.checkLogs)
                                }
                            }
                        }
                    })
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }

            if file.type == .file && !readOnly {
                if isZipFile {
                    Button {
                        uncompressFileAndSync()
                    } label: {
                        Label("Uncompress", systemImage: "archivebox")
                    }
                } else {
                    Button {
                        compressFileAndSync()
                    } label: {
                        Label("Compress", systemImage: "archivebox")
                    }
                }
            }

            if file.type == .file && !readOnly {
                Button {
                    duplicateFileAndSync()
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
            }

            Divider()

            Button {
                if isCoreMediaVirtualFile {
                    loadVirtualFileForAction { data in
                        guard copyDataToClipboard(data, fileName: file.name) else {
                            Alertinator.shared.alert(title: "Failed to copy file!", body: Errors.checkLogs)
                            return
                        }
                    }
                } else if !copyFileToClipboard(file.fileURL) {
                    Alertinator.shared.alert(title: "Failed to copy file!", body: Errors.checkLogs)
                }
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            Button {
                if isCoreMediaVirtualFile {
                    loadVirtualFileForAction { data in
                        presentShareSheet(with: data, fileName: file.name)
                    }
                } else if let url = makeTemp(file.fileURL) {
                    presentShareSheet(with: url)
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }

            Divider()

            if !readOnly {
                Button(role: .destructive) {
                    deleteFileAndSync()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @MainActor
    private func loadVirtualFileForAction(_ action: @escaping (Data) -> Void) {
        guard !isPerformingVirtualFileAction else { return }
        isPerformingVirtualFileAction = true
        let path = file.fileURL.path
        Task { @MainActor in
            defer { isPerformingVirtualFileAction = false }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try CoreMediaVirtualSystemPathReader.readFileData(atPath: path)
                }.value
                action(data)
            } catch {
                if CoreMediaVirtualSystemPathReader.shouldSuggestAppReopen(for: error, at: URL(fileURLWithPath: path)) {
                    Alertinator.shared.alert(title: "Restart Erosion", body: CoreMediaVirtualSystemPathReader.reopenAppMessage)
                } else {
                    Alertinator.shared.alert(title: "File Action Failed", body: error.localizedDescription)
                }
            }
        }
    }

    @MainActor
    private func openQuickLookMediaPreview(imageExtensionOverride: String? = nil) {
        guard !isPreparingQuickLookPreview else { return }
        isPreparingQuickLookPreview = true
        let sourceURL = file.fileURL
        let groupIdentifier = wq.getAppGroup()

        Task { @MainActor in
            defer { isPreparingQuickLookPreview = false }
            do {
                let staged = try await Task.detached(priority: .userInitiated) {
                    try QuickLookPreviewFileStager.makeCopy(
                        from: sourceURL,
                        groupIdentifier: groupIdentifier,
                        fileExtensionOverride: imageExtensionOverride
                    )
                }.value

                let previousDirectory = virtualPreviewDirectory
                virtualPreviewDirectory = staged.directoryURL
                virtualPreviewURL = staged.fileURL
                if let previousDirectory {
                    try? FileManager.default.removeItem(at: previousDirectory)
                }
                previewURL = staged.fileURL
            } catch {
                Alertinator.shared.alert(
                    title: "Unable to Open Quick Look",
                    body: error.localizedDescription
                )
            }
        }
    }

    private func cleanupVirtualPreview() {
        if let directory = virtualPreviewDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
        virtualPreviewDirectory = nil
        virtualPreviewURL = nil
    }

    private func compressFileAndSync() {
        if isAirliftRemote && !remoteMutationAllowed() {
            Alertinator.shared.alert(title: "Airlift write unavailable", body: "Enable LocalDevVPN and make sure the pairing file is imported.")
            return
        }
        let sourceURL = file.fileURL
        let zipURL = sourceURL.deletingLastPathComponent()
            .appendingPathComponent(sourceURL.lastPathComponent + ".zip")
        guard !fm.fileExists(atPath: zipURL.path) else {
            Alertinator.shared.alert(title: "Failed to compress file!", body: "An archive with that name already exists.")
            return
        }
        guard zipFile(sourceURL) else {
            Alertinator.shared.alert(title: "Failed to compress file!", body: Errors.checkLogs)
            return
        }

        guard isAirliftRemote, let remotePath = remoteSiblingPath(zipURL.lastPathComponent) else {
            mgr.refreshFiles.toggle()
            return
        }
        Task {
            let ok = await AirliftBridge.shared.writeBack(localURL: zipURL, remotePath: remotePath)
            await MainActor.run {
                if ok {
                    mgr.refreshFiles.toggle()
                } else {
                    try? fm.removeItem(at: zipURL)
                    Alertinator.shared.alert(title: "Failed to compress file!", body: "The archive was created locally, but the remote Airlift write failed. Check the Airlift log.")
                }
            }
        }
    }

    private func uncompressFileAndSync() {
        if isAirliftRemote && !remoteMutationAllowed() {
            Alertinator.shared.alert(title: "Airlift write unavailable", body: "Enable LocalDevVPN and make sure the pairing file is imported.")
            return
        }
        let archiveURL = file.fileURL
        guard let extractedItems = unzipFile(archiveURL) else {
            Haptic.shared.play(.heavy)
            Alertinator.shared.alert(title: "Failed to uncompress file!", body: Errors.checkLogs)
            return
        }

        guard isAirliftRemote,
              let remoteRoot = airliftRemotePath,
              let remoteParent = URL(fileURLWithPath: remoteRoot).deletingLastPathComponent().path as String? else {
            mgr.refreshFiles.toggle()
            return
        }

        Task {
            var allOK = true
            for localChild in extractedItems {
                let childRemote = URL(fileURLWithPath: remoteParent)
                    .appendingPathComponent(localChild.lastPathComponent)
                    .path
                let isDirectory = (try? localChild.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let ok: Bool
                if isDirectory {
                    ok = await AirliftBridge.shared.createRemoteDirectory(localURL: localChild, remotePath: childRemote)
                } else {
                    ok = await AirliftBridge.shared.writeBack(localURL: localChild, remotePath: childRemote)
                }
                if !ok { allOK = false }
            }
            await MainActor.run {
                if allOK {
                    mgr.refreshFiles.toggle()
                } else {
                    Alertinator.shared.alert(title: "Failed to write extracted files!", body: "The archive was extracted locally, but one or more remote Airlift writes failed. Check the Airlift log.")
                }
            }
        }
    }

    private func duplicateFileAndSync() {
        if isAirliftRemote && !remoteMutationAllowed() {
            Alertinator.shared.alert(title: "Airlift write unavailable", body: "Enable LocalDevVPN and make sure the pairing file is imported.")
            return
        }
        let sourceURL = file.fileURL
        let targetURL = duplicateDestination(for: sourceURL)
        guard !fm.fileExists(atPath: targetURL.path) else {
            Alertinator.shared.alert(title: "Failed to duplicate file!", body: "A copy with that name already exists.")
            return
        }
        do {
            try fm.copyItem(at: sourceURL, to: targetURL)
        } catch {
            Alertinator.shared.alert(title: "Failed to duplicate file!", body: error.localizedDescription)
            return
        }

        guard isAirliftRemote, let remoteTarget = remoteSiblingPath(targetURL.lastPathComponent) else {
            mgr.refreshFiles.toggle()
            return
        }
        Task {
            let ok = await AirliftBridge.shared.writeBack(localURL: targetURL, remotePath: remoteTarget)
            await MainActor.run {
                if ok {
                    mgr.refreshFiles.toggle()
                } else {
                    try? fm.removeItem(at: targetURL)
                    Alertinator.shared.alert(title: "Failed to duplicate file!", body: "The remote Airlift write failed. Check the Airlift log.")
                }
            }
        }
    }

    private func deleteFileAndSync() {
        guard isAirliftRemote, let remotePath = airliftRemotePath else {
            do {
                try fm.removeItem(at: file.fileURL)
                mgr.refreshFiles.toggle()
            } catch {
                print("(fm) failed to delete file: \(error.localizedDescription)")
                Alertinator.shared.alert(title: "Failed to delete file!", body: Errors.checkLogs)
            }
            return
        }

        guard remoteMutationAllowed() else {
            Alertinator.shared.alert(title: "Airlift write unavailable", body: "Enable LocalDevVPN and make sure the pairing file is imported.")
            return
        }
        Task {
            let ok = await AirliftBridge.shared.removeRemotePath(remotePath)
            await MainActor.run {
                if ok {
                    do {
                        try fm.removeItem(at: file.fileURL)
                        mgr.refreshFiles.toggle()
                    } catch {
                        Alertinator.shared.alert(title: "Remote delete succeeded", body: "The snapshot could not be removed locally: \(error.localizedDescription)")
                    }
                } else {
                    Alertinator.shared.alert(title: "Failed to delete file!", body: "The remote Airlift delete failed. The local snapshot was kept unchanged. Check the Airlift log.")
                }
            }
        }
    }

    private func duplicateDestination(for url: URL) -> URL {
        if url.pathExtension.isEmpty {
            return url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent)_copy")
        }
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_copy.\(url.pathExtension)")
    }

}
