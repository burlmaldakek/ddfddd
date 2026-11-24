//
//  FileRow.swift
//  AccessiblePlus
//
//  Created by lunginspector on 5/20/26.
//

import SwiftUI

import QuickLook

struct AppsSystemFileRow: View {
    @EnvironmentObject var mgr: ErosionManager
    @AppStorage("hideDates") var hideDates = false
    var file: FileItem
    
    @State private var conformsText = false
    @State private var conformsPlist = false
    @State private var conformsZip = false
    
    @State private var showInfo = false
    @State private var showPlistViewer = false
    @State private var showTextViewer = false
    @State private var previewURL: URL?
    @State private var previewDirectory: URL?
    @State private var isPreparingQuickLookPreview = false
    @State private var showExtendedPreview = false

    private static let quickLookMediaExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp", "svg",
        "mp4", "mov", "m4v", "mp3", "m4a", "wav", "aiff", "aif", "caf", "flac", "aac"
    ]

    private var isQuickLookMedia: Bool {
        Self.quickLookMediaExtensions.contains(file.fileURL.pathExtension.lowercased())
    }

    private var isCAR: Bool { file.fileURL.pathExtension.lowercased() == "car" }
    private var isKnownPlist: Bool {
        file.fileURL.pathExtension.lowercased() == "plist" || file.uttype.conforms(to: .propertyList)
    }
    
    var body: some View {
        Group {
            if file.type == .file {
                Button {
                    if conformsZip {
                        let res = unzipFile(file.fileURL)
                        if res != nil {
                            mgr.refreshFiles.toggle()
                        } else {
                            Haptic.shared.play(.heavy)
                        }
                    } else {
                        if isQuickLookMedia || isCAR {
                            openQuickLookPreview()
                        } else if isKnownPlist || conformsPlist {
                            showPlistViewer.toggle()
                        } else if conformsText {
                            if file.fileURL.pathExtension.isEmpty,
                               let imageExtension = detectedImageFileExtension(at: file.fileURL) {
                                openQuickLookPreview(imageExtensionOverride: imageExtension)
                            } else {
                                showTextViewer.toggle()
                            }
                        } else if file.fileURL.pathExtension.isEmpty,
                                  let imageExtension = detectedImageFileExtension(at: file.fileURL) {
                            openQuickLookPreview(imageExtensionOverride: imageExtension)
                        } else {
                            previewURL = file.fileURL
                        }
                    }
                } label: {
                    HStack(spacing: isSolariumUI() ? 12 : 10) {
                        Group {
                            if isPreparingQuickLookPreview {
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
                            if !hideDates && !file.modifiedDateStr.isEmpty && file.type == .file {
                                Text(file.modifiedDateStr)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        
                        if file.type == .file {
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        
                        Button {
                            showInfo.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, !hideDates && !file.modifiedDateStr.isEmpty && file.type == .file && !isSolariumUI() ? 1 : 0)
                }
            } else {
                NavigationLink(destination: AppsSystemFileBrowserView(path: file.destURL)) {
                    HStack(spacing: isSolariumUI() ? 12 : 10) {
                        Image(systemName: "arrow.up.right.circle")
                            .frame(width: 20, alignment: .center)
                            .foregroundStyle(file.hidden ? .secondary : .primary)
                        
                        Text(file.name)
                            .foregroundStyle(file.hidden ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        Button {
                            showInfo.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .foregroundStyle(Color(.label))
        .onAppear {
            conformsText = conformsToTextViewer(file.fileURL)
            conformsPlist = conformsToPlistViewer(file.fileURL)
            if file.uttype.conforms(to: .zip) {
                conformsZip = true
            }
        }
        .sheet(isPresented: $showInfo) {
            InfoViewer(file)
        }
        .sheet(isPresented: $showPlistViewer) {
            PlistViewer(file.fileURL)
        }
        .sheet(isPresented: $showTextViewer) {
            TextViewer(file.fileURL)
        }
        .sheet(isPresented: $showExtendedPreview) {
            NavigationStack {
                FilePreviewView(url: file.fileURL)
            }
        }
        .quickLookPreview($previewURL)
        .onChange(of: previewURL) { newValue in
            if newValue == nil { cleanupQuickLookPreview() }
        }
        .onDisappear(perform: cleanupQuickLookPreview)
        // MARK: cell actions
        .contextMenu {
            if isCAR {
                Menu {
                    Button { openQuickLookPreview() } label: {
                        Label("Quick Look", systemImage: "eye")
                    }
                    Button { showExtendedPreview = true } label: {
                        Label("Extended Viewer", systemImage: "photo.on.rectangle.angled")
                    }
                } label: {
                    Label("View In...", systemImage: "doc.text.magnifyingglass")
                }
            } else if isQuickLookMedia {
                Button { openQuickLookPreview() } label: {
                    Label("Quick Look", systemImage: "eye")
                }
            } else if isKnownPlist || conformsText || conformsPlist {
                Menu {
                    Button {
                        if file.fileURL.pathExtension.isEmpty,
                           let imageExtension = detectedImageFileExtension(at: file.fileURL) {
                            openQuickLookPreview(imageExtensionOverride: imageExtension)
                        } else {
                            previewURL = file.fileURL
                        }
                    } label: {
                        Label("Quick Look", systemImage: "eye")
                    }
                    
                    if isKnownPlist || conformsPlist {
                        Button {
                            showPlistViewer.toggle()
                        } label: {
                            Label("Plist Viewer", systemImage: "tablecells")
                        }
                    }
                    
                    if conformsText && !isKnownPlist && !conformsPlist {
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
                    if file.fileURL.pathExtension.isEmpty,
                       let imageExtension = detectedImageFileExtension(at: file.fileURL) {
                        openQuickLookPreview(imageExtensionOverride: imageExtension)
                    } else {
                        previewURL = file.fileURL
                    }
                } label: {
                    Label("Quick Look", systemImage: "eye")
                }
            }
            
            Divider()
            
            Button {
                showInfo.toggle()
            } label: {
                Label("Get Info", systemImage: "info.circle")
            }
            
            Button {
                Alertinator.shared.prompt(title: "What would you like to call this item?", placeholder: file.name, completion: { result in
                    if let name = result {
                        let targetURL = file.fileURL.deletingLastPathComponent().appendingPathComponent(name)
                        do {
                            try fm.moveItem(at: file.fileURL, to: targetURL)
                            mgr.refreshFiles.toggle()
                        } catch {
                            Alertinator.shared.alert(title: "Failed to rename item!", body: Errors.checkLogs)
                        }
                    }
                })
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            
            if file.type == .file {
                if conformsZip {
                    Button {
                        let res = unzipFile(file.fileURL)
                        if res != nil {
                            mgr.refreshFiles.toggle()
                        } else {
                            Alertinator.shared.alert(title: "Failed to uncompress file!", body: Errors.checkLogs)
                        }
                    } label: {
                        Label("Uncompress", systemImage: "archivebox")
                    }
                } else {
                    Button {
                        let res = zipFile(file.fileURL)
                        if res {
                            mgr.refreshFiles.toggle()
                        } else {
                            Alertinator.shared.alert(title: "Failed to compress file!", body: Errors.checkLogs)
                        }
                    } label: {
                        Label("Compress", systemImage: "archivebox")
                    }
                }
            }
            
            if file.type == .file {
                Button {
                    let res = duplicateFile(file.fileURL)
                    if res {
                        mgr.refreshFiles.toggle()
                    } else {
                        Alertinator.shared.alert(title: "Failed to duplicate file!", body: Errors.checkLogs)
                    }
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
            }
            
            Divider()
            
            Button {
                let res = copyFileToClipboard(file.fileURL)
                if !res {
                    Alertinator.shared.alert(title: "Failed to copy file!", body: Errors.checkLogs)
                }
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            
            Button {
                if let url = makeTemp(file.fileURL) {
                    presentShareSheet(with: url)
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            
            Divider()
            
            Button(role: .destructive) {
                do {
                    try fm.removeItem(at: file.fileURL)
                    mgr.refreshFiles.toggle()
                } catch {
                    print("(fm) failed to delete file: \(error.localizedDescription)")
                    Alertinator.shared.alert(title: "Failed to delete file!", body: Errors.checkLogs)
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @MainActor
    private func openQuickLookPreview(imageExtensionOverride: String? = nil) {
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
                let previousDirectory = previewDirectory
                previewDirectory = staged.directoryURL
                if let previousDirectory { try? FileManager.default.removeItem(at: previousDirectory) }
                previewURL = staged.fileURL
            } catch {
                Alertinator.shared.alert(title: "Unable to Open Quick Look", body: error.localizedDescription)
            }
        }
    }

    private func cleanupQuickLookPreview() {
        if let previewDirectory { try? FileManager.default.removeItem(at: previewDirectory) }
        previewDirectory = nil
    }
}
