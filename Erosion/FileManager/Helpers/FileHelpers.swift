//
//  FileHelpers.swift
//  Filos
//
//  Created by lunginspector on 7/22/26.
//

import SwiftUI
import ZIPFoundation
import UniformTypeIdentifiers
import ImageIO

extension FileManager {
    func createDirectoryIfNeeded(at url: URL) throws {
        if !self.fileExists(atPath: url.path) {
            try self.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

func getFileDict(_ url: URL) -> [String : Any]? {
    if let data = try? Data(contentsOf: url),
       let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String : Any] {
        return dict
    }
    
    return nil
}

func getFileText(_ url: URL) -> String {
    do {
        let data = try Data(contentsOf: url)
        
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        
        return String(decoding: data, as: UTF8.self)
    } catch {
        print("(fm) failed to get text! path: \(error.localizedDescription)")
        return ""
    }
}

func makeTemp(_ fileURL: URL) -> URL? {
    do {
        let neededAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if neededAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        
        let tempURL = URL.temporaryDirectory.appendingPathComponent("\(fileURL.lastPathComponent)")
        if fm.fileExists(atPath: tempURL.path) {
            try fm.removeItem(at: tempURL)
        }
        try fm.copyItem(at: fileURL, to: tempURL)
        return tempURL
    } catch {
        print("(fm) failed to make temp: \(error.localizedDescription)")
    }
    return nil
}

func generateNavPath(path: String) -> String {
    if !path.contains("/") || path.isEmpty {
        return ""
    }
    
    let file = getFileItem(at: URL(fileURLWithPath: path))
    
    if file.type == .folder || file.type == .symlink {
        return path
    }
    
    if file.type == .file {
        let navPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return navPath
    }
    return ""
}

func renameFile(_ url: URL, to newName: String) -> Bool {
    do {
        let data = try Data(contentsOf: url)
        try fm.removeItem(at: url)
        let targetURL = url.deletingLastPathComponent().appendingPathComponent(newName)
        try data.write(to: targetURL)
        return true
    } catch {
        print("(fm) failed to rename file: \(error.localizedDescription)")
    }
    return false
}


/// Copies the readable portion of a directory tree into a temporary destination.
/// Unavailable children are omitted while readable siblings remain available to ZIP.
func copyDirectoryContentsBestEffort(at sourceURL: URL, to destinationURL: URL, depth: Int = 0) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    guard depth < 64 else { return }

    let children: [URL]
    do {
        children = try manager.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
    } catch {
        return
    }

    for child in children {
        let destination = destinationURL.appendingPathComponent(child.lastPathComponent)
        do {
            let attributes = try manager.attributesOfItem(atPath: child.path)
            let itemType = attributes[.type] as? FileAttributeType

            if itemType == .typeSymbolicLink {
                let linkTarget = try manager.destinationOfSymbolicLink(atPath: child.path)
                try manager.createSymbolicLink(atPath: destination.path, withDestinationPath: linkTarget)
            } else if itemType == .typeDirectory {
                try copyDirectoryContentsBestEffort(at: child, to: destination, depth: depth + 1)
            } else {
                try manager.copyItem(at: child, to: destination)
            }
        } catch {
            // Continue with the remaining siblings.
            continue
        }
    }
}

/// Creates a ZIP copy of a read-only item inside the File Browser Workspace.
/// The source is staged inside Workspace so the original directory is never modified.
func zipItemToWorkspace(at sourceURL: URL, preferredName: String? = nil, data: Data? = nil, isDirectory: Bool = false) throws -> URL {
    let manager = FileManager.default
    let applicationSupport = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL.documentsDirectory.appendingPathComponent("Application Support", isDirectory: true)
    let workspace = applicationSupport.appendingPathComponent("Workspace", isDirectory: true)
    try manager.createDirectory(at: workspace, withIntermediateDirectories: true)

    let requestedName = preferredName ?? sourceURL.lastPathComponent
    let itemName = URL(fileURLWithPath: requestedName).lastPathComponent
    guard !itemName.isEmpty, itemName != ".", itemName != ".." else {
        throw NSError(domain: "ErosionWorkspaceZIP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid archive name."])
    }
    let destinationURL = workspace.appendingPathComponent(itemName + ".zip")
    guard !manager.fileExists(atPath: destinationURL.path) else {
        throw NSError(domain: "ErosionWorkspaceZIP", code: 2, userInfo: [NSLocalizedDescriptionKey: "An archive named \(itemName).zip already exists in Workspace."])
    }

    let staging = workspace.appendingPathComponent(".zip-staging-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: staging) }

    let stagedItem = staging.appendingPathComponent(itemName, isDirectory: isDirectory)
    if let data {
        try data.write(to: stagedItem, options: .atomic)
    } else if isDirectory {
        if CoreMediaVirtualSystemPathReader.containsVirtualPath(sourceURL) {
            try CoreMediaVirtualSystemPathReader.copyDirectoryToLocal(
                atPath: sourceURL.standardizedFileURL.path,
                to: stagedItem,
                bestEffortUnreadableEntries: true
            )
        } else {
            try copyDirectoryContentsBestEffort(at: sourceURL, to: stagedItem)
        }
    } else {
        try manager.copyItem(at: sourceURL, to: stagedItem)
    }

    let stagedArchive = staging.appendingPathComponent(itemName + ".zip")
    try manager.zipItem(at: stagedItem, to: stagedArchive, shouldKeepParent: true)
    try manager.moveItem(at: stagedArchive, to: destinationURL)
    return destinationURL
}

func zipFile(_ url: URL, isDirectory directoryHint: Bool? = nil) -> Bool {
    let manager = FileManager.default
    let zipDest = url
        .deletingLastPathComponent()
        .appendingPathComponent(url.lastPathComponent + ".zip")

    do {
        var detectedDirectory: ObjCBool = false
        let shouldStageDirectory = directoryHint
            ?? (manager.fileExists(atPath: url.path, isDirectory: &detectedDirectory) && detectedDirectory.boolValue)
        if shouldStageDirectory {
            let stagingRoot = manager.temporaryDirectory
                .appendingPathComponent("ErosionZIP-\(UUID().uuidString)", isDirectory: true)
            defer { try? manager.removeItem(at: stagingRoot) }

            let stagedDirectory = stagingRoot.appendingPathComponent(url.lastPathComponent, isDirectory: true)
            try copyDirectoryContentsBestEffort(at: url, to: stagedDirectory)
            try manager.zipItem(at: stagedDirectory, to: zipDest, shouldKeepParent: true)
        } else {
            try manager.zipItem(at: url, to: zipDest, shouldKeepParent: true)
        }
        return true
    } catch {
        print("(fm) failed to zip file: \(error.localizedDescription)")
    }
    return false
}

/// Extracts an archive beside the original ZIP. When an item from the archive
/// already exists, the extracted item receives a numeric suffix instead of
/// failing or overwriting the existing item (for example: Folder (1), Folder (2)).
/// Extraction happens in a unique staging directory first so collisions are
/// resolved independently for every top-level item in the archive.
func unzipFile(_ url: URL) -> [URL]? {
    let manager = FileManager.default
    let destinationDirectory = url.deletingLastPathComponent()
    let stagingDirectory = manager.temporaryDirectory
        .appendingPathComponent("Erosion-Unzip-\(UUID().uuidString)", isDirectory: true)
    var installedItems: [URL] = []

    func destinationURL(for source: URL, isDirectory: Bool, suffix: Int) -> URL {
        let originalName = source.lastPathComponent
        let candidateName: String
        if suffix == 0 {
            candidateName = originalName
        } else if isDirectory {
            candidateName = "\(originalName) (\(suffix))"
        } else {
            let nsName = originalName as NSString
            let fileExtension = nsName.pathExtension
            let baseName = nsName.deletingPathExtension
            if fileExtension.isEmpty || baseName.isEmpty {
                candidateName = "\(originalName) (\(suffix))"
            } else {
                candidateName = "\(baseName) (\(suffix)).\(fileExtension)"
            }
        }
        return destinationDirectory.appendingPathComponent(candidateName, isDirectory: isDirectory)
    }

    do {
        try manager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try manager.unzipItem(at: url, to: stagingDirectory)

        let extractedItems = try manager.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !extractedItems.isEmpty else {
            throw NSError(
                domain: "Erosion.Unzip",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The archive is empty."]
            )
        }

        for source in extractedItems {
            let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            var suffix = 0
            var moved = false

            while !moved {
                let target = destinationURL(for: source, isDirectory: isDirectory, suffix: suffix)
                if manager.fileExists(atPath: target.path) {
                    suffix += 1
                    continue
                }

                do {
                    try manager.moveItem(at: source, to: target)
                    installedItems.append(target)
                    moved = true
                } catch {
                    // A concurrent extraction may have claimed the candidate
                    // after the existence check. Retry only for that collision.
                    if manager.fileExists(atPath: target.path) {
                        suffix += 1
                    } else {
                        throw error
                    }
                }
            }
        }

        try? manager.removeItem(at: stagingDirectory)
        return installedItems
    } catch {
        // Avoid leaving a half-extracted result if one top-level item fails.
        for item in installedItems.reversed() {
            try? manager.removeItem(at: item)
        }
        try? manager.removeItem(at: stagingDirectory)
        print("(fm) failed to uncompress file: \(error.localizedDescription)")
        return nil
    }
}

func duplicateFile(_ url: URL) -> Bool {
    do {
        let targetURL = {
            if url.pathExtension == "" {
                return url
                    .deletingLastPathComponent()
                    .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_copy")
            }
            return url
                .deletingLastPathComponent()
                .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_copy.\(url.pathExtension)")
        }()
        let data = try Data(contentsOf: url)
        try data.write(to: targetURL)
        return true
    } catch {
        print("(fm) failed to duplicate file: \(error.localizedDescription)")
    }
    return false
}

func copyFileToClipboard(_ url: URL) -> Bool {
    do {
        guard let tempURL = makeTemp(url) else {
            throw "failed to make temp!"
        }
        let data = try Data(contentsOf: tempURL)
        let utType = UTType(filenameExtension: tempURL.pathExtension) ?? .data
        
        UIPasteboard.general.setData(data, forPasteboardType: utType.identifier)
        return true
    } catch {
        print("(fm) failed to copy file: \(error.localizedDescription)")
    }
    return false
}

/// Copies a virtual file snapshot directly to the pasteboard without creating a local file.
func copyDataToClipboard(_ data: Data, fileName: String) -> Bool {
    let fileExtension = URL(fileURLWithPath: fileName).pathExtension
    let utType = UTType(filenameExtension: fileExtension) ?? .data
    UIPasteboard.general.setData(data, forPasteboardType: utType.identifier)
    return true
}

func conformsToPlistViewer(_ url: URL) -> Bool {
    guard let data = try? Data(contentsOf: url), !data.isEmpty,
          (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) != nil else {
        return false
    }
    return true
}

func conformsToTextViewer(_ url: URL) -> Bool {
    do {
        let _ = try String(contentsOf: url, encoding: .utf8)
        return true
    } catch {
        return false
    }
}

/// Returns a real image format inferred from the file contents. This is used
/// only for extensionless files; it does not classify arbitrary binary data as images.
func detectedImageFileExtension(at url: URL) -> String? {
    if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
       let identifier = CGImageSourceGetType(source) as String?,
       let type = UTType(identifier),
       type.conforms(to: .image),
       let ext = type.preferredFilenameExtension,
       !ext.isEmpty {
        return ext.lowercased()
    }

    // SVG is XML text, so ImageIO may not identify it as a raster image.
    // Recognize its root element from a small header read for extensionless files.
    if let data = try? Data(contentsOf: url, options: .mappedIfSafe),
       let header = String(data: data.prefix(8192), encoding: .utf8),
       header.range(of: "<svg", options: [.caseInsensitive]) != nil {
        return "svg"
    }
    return nil
}


/// Creates a local, self-contained copy for Quick Look. Quick Look sometimes
/// receives only filesystem metadata for sandbox-restricted paths and falls
/// back to a generic "(PNG) image" document. Copying the actual bytes first
/// gives Quick Look an ordinary local file while keeping WQ access short-lived.
enum QuickLookPreviewFileStager {
    nonisolated static func makeCopy(
        from sourceURL: URL,
        groupIdentifier: String,
        fileExtensionOverride: String? = nil
    ) throws -> (fileURL: URL, directoryURL: URL) {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("ErosionQuickLookPreviews", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        let destinationName: String
        if sourceURL.pathExtension.isEmpty,
           let fileExtensionOverride,
           !fileExtensionOverride.isEmpty {
            destinationName = sourceURL.lastPathComponent + "." + fileExtensionOverride
        } else {
            destinationName = sourceURL.lastPathComponent
        }
        let destination = directory.appendingPathComponent(destinationName)
        do {
            do {
                try copyFileContents(from: sourceURL, to: destination)
            } catch {
                let directReadError = error
                try? manager.removeItem(at: destination)
                let access = WorseQuery.grantAccess(
                    path: sourceURL.path,
                    groupIdentifier: groupIdentifier
                )
                guard access.0, access.1 >= 0 else {
                    throw NSError(
                        domain: "Erosion.QuickLookPreview",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Unable to read file directly (\(directReadError.localizedDescription)); Worse Query failed: \(access.2)"]
                    )
                }
                defer { releaseSandboxAccess(access.1) }
                try copyFileContents(from: sourceURL, to: destination)
            }
            return (destination, directory)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    nonisolated private static func copyFileContents(from sourceURL: URL, to destinationURL: URL) throws {
        let manager = FileManager.default
        guard manager.createFile(atPath: destinationURL.path, contents: nil) else {
            throw NSError(
                domain: "Erosion.QuickLookPreview",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unable to create the temporary Quick Look file."]
            )
        }

        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }

        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
    }
}
