//
//  FileInfoSheet.swift
//  AccessiblePlus
//
//  Created by lunginspector on 5/20/26.
//

import SwiftUI

import UniformTypeIdentifiers

struct InfoViewer: View {
    @Environment(\.dismiss) var dismiss
    var file: FileItem
    var pathOverride: String? = nil
    /// Apps/System rows can be metadata-backed container entries. Their Info
    /// sheet still needs to run the same aggregate directory-size calculation
    /// used by the regular File Browser, after acquiring the WQ read grant.
    var isContainer: Bool = false
    @State private var folderSize: Int64?
    @State private var virtualMetadata: FileItem?

    private var displayFile: FileItem { virtualMetadata ?? file }
    
    init(_ file: FileItem, pathOverride: String? = nil, isContainer: Bool = false) {
        self.file = file
        self.pathOverride = pathOverride
        self.isContainer = isContainer
    }
    
    private var hidesSystemLibraryFolderSize: Bool {
        let path = displayFile.fileURL.standardizedFileURL.path
        return path == "/System/Library" || path.hasPrefix("/System/Library/")
    }

    private var showsDirectorySize: Bool {
        if displayFile.type == .symlink {
            // Resolve the destination inside the detached size task, after any
            // required WQ grant. A symlink may point to another symlink, so the
            // root open follows the explicitly selected Destination Path.
            return true
        }
        return (displayFile.type == .folder || isContainer)
            && !hidesSystemLibraryFolderSize
            && !hidesBundleContainerFolderSize
            && !hidesCoreServicesAppBundleFolderSize
    }

    private var hidesCoreServicesAppBundleFolderSize: Bool {
        let path = displayFile.fileURL.standardizedFileURL.path
        let root = "/System/Library/CoreServices/"
        guard path.hasPrefix(root) else { return false }
        let components = path.dropFirst(root.count).split(separator: "/", omittingEmptySubsequences: false)
        return components.count == 1 && String(components[0]).lowercased().hasSuffix(".app")
    }

    private var hidesBundleContainerFolderSize: Bool {
        let path = displayFile.fileURL.standardizedFileURL.path
        let root = FSPaths.appBundles + "/"
        guard path.hasPrefix(root) else { return false }
        let components = path.dropFirst(root.count).split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              UUID(uuidString: String(components[0])) != nil else { return false }
        return String(components[1]).lowercased().hasSuffix(".app")
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    StringInfoCell(displayFile.name, label: "Name")
                    StringInfoCell(pathOverride ?? displayFile.fileURL.path, label: "Path")
                    if displayFile.type == .symlink {
                        StringInfoCell(displayFile.destURL.path, label: "Destination Path")
                    }
                    if displayFile.type == .file && !isContainer {
                        // Keep the existing file-size row unchanged.
                        StringInfoCell("\(ByteCountFormatter.string(fromByteCount: Int64(displayFile.size), countStyle: .file))", label: "Size")
                    } else if showsDirectorySize, let folderSize {
                        StringInfoCell(ByteCountFormatter.string(fromByteCount: folderSize, countStyle: .file), label: "Size")
                    }
                }
                
                Section {
                    StringInfoCell(displayFile.uttype.identifier, label: "UTType")
                    StringInfoCell(displayFile.creationDateStr, label: "Creation Date")
                    StringInfoCell(displayFile.modifiedDateStr, label: "Last Modified")
                    BoolInfoCell(displayFile.type == .symlink, label: "Symlink")
                } header: {
                    HeaderLabel("File", symbol: "doc")
                }
                
                Section {
                    StringInfoCell(displayFile.posixPerms, label: "POSIX Permissions")
                    StringInfoCell(displayFile.owner, label: "Owner")
                    StringInfoCell(displayFile.group, label: "Group")
                    BoolInfoCell(displayFile.readable, label: "Readable")
                    BoolInfoCell(displayFile.writable, label: "Writable")
                    BoolInfoCell(displayFile.executable, label: "Executable")
                } header: {
                    HeaderLabel("Permissions", symbol: "shield")
                }
            }
            .navigationTitle("\(displayFile.type.rawValue.capitalized) Info")
            .navigationBarTitleDisplayMode(.inline)
            .listStyle(.insetGrouped)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        ToolbarLabel("Close", symbol: "xmark")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .task(id: file.fileURL.path + "|" + file.destURL.path) {
            if CoreMediaVirtualSystemPathReader.containsVirtualPath(file.fileURL) {
                let virtualPath = file.fileURL.path
                let infoData = await Task.detached(priority: .utility) {
                    CoreMediaVirtualSystemPathReader.infoData(atPath: virtualPath)
                }.value
                if let refreshedMetadata = infoData.item {
                    virtualMetadata = refreshedMetadata
                }
                if showsDirectorySize {
                    folderSize = infoData.directorySize
                }
                return
            }

            guard showsDirectorySize else { return }
            let isSymlink = displayFile.type == .symlink
            let sizeURL = isSymlink ? displayFile.destURL.standardizedFileURL : displayFile.fileURL.standardizedFileURL
            do {
                let calculatedSize = try await Task.detached(priority: .utility) {
                    if isSymlink {
                        // The size belongs to Destination Path, never to the link
                        // entry. If the target is in a managed container, grant
                        // that exact path first; do not grant the symlink itself.
                        if FolderContentSizeReader.isManagedContainerPath(sizeURL) {
                            let access = wq.grantAccess(path: sizeURL.path)
                            guard access.0, access.1 >= 0 else {
                                throw NSError(
                                    domain: "Erosion.SymlinkSizeAccess",
                                    code: Int(access.1),
                                    userInfo: [NSLocalizedDescriptionKey: access.2]
                                )
                            }
                            defer { releaseSandboxAccess(access.1) }
                            return try FolderContentSizeReader.calculate(
                                at: sizeURL,
                                followRootSymlink: true
                            )
                        }

                        // Public/user-readable destinations should not need an
                        // exploit grant. Try the target directly, then request a
                        // target-only grant if the direct walk is denied.
                        do {
                            return try FolderContentSizeReader.calculate(
                                at: sizeURL,
                                followRootSymlink: true
                            )
                        } catch let directError {
                            let access = wq.grantAccess(path: sizeURL.path)
                            guard access.0, access.1 >= 0 else {
                                throw directError
                            }
                            defer { releaseSandboxAccess(access.1) }
                            return try FolderContentSizeReader.calculate(
                                at: sizeURL,
                                followRootSymlink: true
                            )
                        }
                    }

                    // Existing directory/container flow: obtain the required
                    // extension for the selected folder, then sum its contents.
                    var grantedExtensions: [Int64] = []
                    defer {
                        for extensionID in grantedExtensions {
                            releaseSandboxAccess(extensionID)
                        }
                    }
                    if FolderContentSizeReader.isManagedContainerPath(sizeURL) {
                        let access = wq.grantAccess(path: sizeURL.path)
                        guard access.0, access.1 >= 0 else {
                            throw NSError(
                                domain: "Erosion.ContainerSizeAccess",
                                code: Int(access.1),
                                userInfo: [NSLocalizedDescriptionKey: access.2]
                            )
                        }
                        grantedExtensions.append(access.1)
                    }
                    return try FolderContentSizeReader.calculate(at: sizeURL)
                }.value
                folderSize = calculatedSize
            } catch {
                // A partial total would be misleading. Hide Size entirely when
                // any child needed for the calculation cannot be read.
                folderSize = nil
            }
        }
    }
    
    private struct StringInfoCell: View {
        var string: String
        var label: String
        
        init(_ string: String, label: String) {
            self.string = string
            self.label = label
        }
        
        var body: some View {
            HStack {
                Text(label)
                Spacer()
                Text(string.isEmpty ? "—" : string)
                    .foregroundStyle(.secondary)
            }
        .contextMenu {
                Button {
                    UIPasteboard.general.string = string
                } label: {
                    Label("Copy Value", systemImage: "doc.on.doc")
                }
            }
        }
    }
    
    private struct BoolInfoCell: View {
        var bool: Bool?
        var label: String
        
        init(_ bool: Bool?, label: String) {
            self.bool = bool
            self.label = label
        }
        
        var body: some View {
            HStack {
                Text(label)
                Spacer()
                Image(systemName: bool.map { $0 ? "checkmark" : "xmark" } ?? "minus")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
