import Foundation
import Darwin
import CoreFoundation
import UniformTypeIdentifiers

/// Read-only, in-memory providers for selected /Library directories. Directory
/// entries and file bytes are obtained through the process-wide CoreMedia
/// bytestream XPC session owned by CoreMediaUsrLibexecReader.
enum CoreMediaLibraryPathReader {
    static let roots = ["/Library/Ringtones", "/Library/RegionFeatures"]

    private static let snapshotCondition = NSCondition()
    private static var snapshotAttemptedRoots: Set<String> = []
    private static var snapshotInProgressRoots: Set<String> = []
    private static var cachedSnapshots: [String: DirectorySnapshot] = [:]
    private static var cachedSnapshotErrors: [String: Error] = [:]

    private struct DirectorySnapshot {
        var listings: [String: [FileItem]] = [:]
        var directoryMetadata: [String: FileItem] = [:]
        var sizes: [String: Int64] = [:]
        var listingErrors: [String: Error] = [:]
        var incompleteDirectories: Set<String> = []
    }

    private struct DirectoryListingResult {
        let items: [FileItem]
        let isComplete: Bool
        let directoryItem: FileItem?
    }

    static func containsVirtualPath(_ url: URL) -> Bool {
        containsVirtualPath(url.standardizedFileURL.path)
    }

    private static func rootPath(for path: String) -> String? {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return roots.first { normalized == $0 || normalized.hasPrefix($0 + "/") }
    }

    static func containsVirtualPath(_ path: String) -> Bool {
        rootPath(for: path) != nil
    }

    static func isRootPath(_ url: URL) -> Bool {
        roots.contains(url.standardizedFileURL.path)
    }

    /// Each Library root receives one in-memory snapshot. Directory listings,
    /// Info metadata and file previews reuse this reader's retained XPC session.
    private static func ensureSnapshot(for root: String) throws -> DirectorySnapshot {
        snapshotCondition.lock()
        var waitedForExistingScan = false
        while snapshotInProgressRoots.contains(root) {
            waitedForExistingScan = true
            snapshotCondition.wait()
        }
        if let snapshot = cachedSnapshots[root] {
            snapshotCondition.unlock()
            return snapshot
        }
        if let cachedError = cachedSnapshotErrors[root] {
            if waitedForExistingScan {
                snapshotCondition.unlock()
                throw cachedError
            }
            cachedSnapshotErrors.removeValue(forKey: root)
            snapshotAttemptedRoots.remove(root)
        }
        guard !snapshotAttemptedRoots.contains(root) else {
            snapshotCondition.unlock()
            throw CoreMediaReaderError.coreMediaUnavailable
        }
        snapshotAttemptedRoots.insert(root)
        snapshotInProgressRoots.insert(root)
        snapshotCondition.unlock()

        do {
            var snapshot = DirectorySnapshot()
            var visitedEntries = 0
            _ = try buildDirectorySnapshot(
                path: root,
                depth: 0,
                visitedEntries: &visitedEntries,
                snapshot: &snapshot
            )

            snapshotCondition.lock()
            cachedSnapshots[root] = snapshot
            snapshotInProgressRoots.remove(root)
            snapshotCondition.broadcast()
            snapshotCondition.unlock()
            return snapshot
        } catch {
            snapshotCondition.lock()
            cachedSnapshotErrors[root] = error
            snapshotInProgressRoots.remove(root)
            snapshotCondition.broadcast()
            snapshotCondition.unlock()
            throw error
        }
    }

    /// Builds listings and aggregate sizes in one CoreMedia session. Unreadable
    /// individual entries are skipped while the rest of the directory is retained.
    /// A directory size is cached only when its entire subtree was enumerated.
    private static func buildDirectorySnapshot(
        path: String,
        depth: Int,
        visitedEntries: inout Int,
        snapshot: inout DirectorySnapshot
    ) throws -> (size: Int64, complete: Bool) {
        guard depth <= 64 else {
            snapshot.listingErrors[path] = CocoaError(.fileReadTooLarge)
            snapshot.incompleteDirectories.insert(path)
            return (0, false)
        }

        let listing: DirectoryListingResult
        do {
            let sharedListing = try CoreMediaUsrLibexecReader.listDirectoryUsingSharedSession(at: path)
            listing = DirectoryListingResult(
                items: sharedListing.items,
                isComplete: sharedListing.isComplete,
                directoryItem: sharedListing.directoryItem
            )
        } catch {
            if isConnectionFailure(error) || rootPath(for: path) == path {
                throw error
            }
            snapshot.listingErrors[path] = error
            snapshot.incompleteDirectories.insert(path)
            return (0, false)
        }

        snapshot.listings[path] = listing.items
        if let directoryItem = listing.directoryItem {
            snapshot.directoryMetadata[path] = directoryItem
        }
        var total: Int64 = 0
        var complete = listing.isComplete

        for item in listing.items {
            visitedEntries += 1
            guard visitedEntries <= 200_000 else {
                throw CoreMediaReaderError.readFailed(path)
            }
            switch item.type {
            case .folder:
                let childPath = URL(fileURLWithPath: path, isDirectory: true)
                    .appendingPathComponent(item.name, isDirectory: true)
                    .standardizedFileURL.path
                let child = try buildDirectorySnapshot(
                    path: childPath,
                    depth: depth + 1,
                    visitedEntries: &visitedEntries,
                    snapshot: &snapshot
                )
                if child.complete {
                    let (sum, overflow) = total.addingReportingOverflow(child.size)
                    guard !overflow else { throw CoreMediaReaderError.readFailed(childPath) }
                    total = sum
                } else {
                    complete = false
                }
            case .file:
                guard item.size >= 0 else {
                    complete = false
                    continue
                }
                let (sum, overflow) = total.addingReportingOverflow(Int64(item.size))
                guard !overflow else { throw CoreMediaReaderError.readFailed(item.fileURL.path) }
                total = sum
            case .symlink:
                // CoreMedia listings intentionally do not follow links.
                continue
            }
        }

        if complete {
            snapshot.sizes[path] = total
        } else {
            snapshot.incompleteDirectories.insert(path)
        }
        return (total, complete)
    }

    static func listDirectory(at url: URL) throws -> [FileItem] {
        try listDirectory(at: url.standardizedFileURL.path)
    }

    static func listDirectory(at path: String) throws -> [FileItem] {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        try validateVirtualPath(normalized)
        guard let root = rootPath(for: normalized) else { throw CoreMediaReaderError.pathOutsideVirtualRoot }
        let snapshot = try ensureSnapshot(for: root)
        if let listingError = snapshot.listingErrors[normalized] {
            throw listingError
        }
        guard let entries = snapshot.listings[normalized] else {
            throw CoreMediaReaderError.couldNotOpenPath(normalized)
        }
        return entries
    }

    /// Returns POSIX metadata and the cached aggregate directory size from one
    /// snapshot lookup. Info uses this combined result so a failed initial scan
    /// is not immediately retried by a second, separate size request.
    static func infoData(atPath path: String) -> (item: FileItem?, directorySize: Int64?) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let root = rootPath(for: normalized), let snapshot = try? ensureSnapshot(for: root) else {
            return (nil, nil)
        }

        let item: FileItem?
        if let directoryItem = snapshot.directoryMetadata[normalized] {
            item = directoryItem
        } else {
            let parent = URL(fileURLWithPath: normalized).deletingLastPathComponent().standardizedFileURL.path
            item = snapshot.listings[parent]?.first {
                $0.fileURL.standardizedFileURL.path == normalized
            }
        }
        return (item, snapshot.sizes[normalized])
    }

    static func canReadDirectory(at url: URL) -> Bool {
        guard containsVirtualPath(url) else { return false }
        return (try? listDirectory(at: url)) != nil
    }

    static func isDirectory(at url: URL) -> Bool {
        guard containsVirtualPath(url) else { return false }
        let path = url.standardizedFileURL.path
        guard let root = rootPath(for: path), let snapshot = try? ensureSnapshot(for: root) else { return false }
        return snapshot.listings[path] != nil
    }

    static func canReadFile(at url: URL) -> Bool {
        guard containsVirtualPath(url) else { return false }
        let path = url.standardizedFileURL.path
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard let root = rootPath(for: path),
              let snapshot = try? ensureSnapshot(for: root),
              let entries = snapshot.listings[parent] else { return false }
        return entries.contains { $0.fileURL.standardizedFileURL.path == path && $0.type == .file }
    }

    static func rootFolderItem() -> FileItem {
        rootFolderItem(at: URL(fileURLWithPath: roots[0], isDirectory: true))
    }

    /// A virtual root row is metadata-only; callers decide when to start its snapshot.
    static func rootFolderItem(at url: URL) -> FileItem {
        makeFolderItem(at: url)
    }

    static let reopenAppMessage = "CoreMedia lost its connection to a virtual system directory. Please wait a little bit to view this path again."

    /// Show the wait hint only for failures of the CoreMedia XPC transport/session.
    static func shouldSuggestAppReopen(for error: Error, at url: URL) -> Bool {
        guard containsVirtualPath(url) else { return false }
        if CoreMediaUsrLibexecReader.shouldSuggestAppReopenForSharedSession(
            for: error,
            at: url.standardizedFileURL.path
        ) {
            return true
        }
        if CoreMediaUsrLibexecReader.isSharedSessionConnectionFailure(error) { return true }
        guard let readerError = error as? CoreMediaReaderError else { return false }
        switch readerError {
        case .connectionInterrupted, .xpcUnavailable, .memoryOriginHandshakeFailed, .coreMediaUnavailable:
            return true
        case .couldNotOpenPath(let failedPath):
            return failedPath == url.standardizedFileURL.path
                && failedPath == rootPath(for: failedPath)
        default:
            return false
        }
    }

    /// Directory size and directory contents are published from the same snapshot.
    static func directoryContentSize(atPath path: String) throws -> Int64 {
        try cachedInfoDirectoryContentSize(atPath: path)
    }

    static func cachedInfoDirectoryContentSize(atPath path: String) throws -> Int64 {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        try validateVirtualPath(normalized)
        guard let root = rootPath(for: normalized) else { throw CoreMediaReaderError.pathOutsideVirtualRoot }
        let snapshot = try ensureSnapshot(for: root)
        if let size = snapshot.sizes[normalized] {
            return size
        }
        if let listingError = snapshot.listingErrors[normalized] {
            throw listingError
        }
        if snapshot.incompleteDirectories.contains(normalized) {
            throw CoreMediaReaderError.readFailed(normalized)
        }
        throw CoreMediaReaderError.notDirectory(normalized)
    }

    /// Reads file bytes on demand. It deliberately does not re-scan directory metadata.
    static func readFileData(atPath path: String, maximumBytes: Int = 64 * 1024 * 1024) throws -> Data {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        try validateVirtualPath(normalized)
        return try CoreMediaUsrLibexecReader.readFileDataUsingSharedSession(
            atPath: normalized,
            maximumBytes: maximumBytes
        )
    }

    /// Materializes a virtual CoreMedia directory into a caller-owned temporary location.
    /// Symlinks are recreated as links and are never traversed during the export.
    static func copyDirectoryToLocal(
        atPath path: String,
        to destinationURL: URL,
        bestEffortUnreadableEntries: Bool = false
    ) throws {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        try validateVirtualPath(normalized)
        try copyDirectoryToLocal(
            atPath: normalized,
            to: destinationURL,
            depth: 0,
            bestEffortUnreadableEntries: bestEffortUnreadableEntries
        )
    }

    private static func copyDirectoryToLocal(
        atPath path: String,
        to destinationURL: URL,
        depth: Int,
        bestEffortUnreadableEntries: Bool
    ) throws {
        guard depth <= 64 else {
            if bestEffortUnreadableEntries { return }
            throw CocoaError(.fileReadTooLarge)
        }

        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        let sourceURL = URL(fileURLWithPath: path, isDirectory: true)
        let entries: [FileItem]
        do {
            entries = try listDirectory(at: sourceURL)
        } catch {
            if bestEffortUnreadableEntries { return }
            throw error
        }

        for entry in entries {
            let name = entry.name
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
                if bestEffortUnreadableEntries { continue }
                throw CoreMediaReaderError.pathOutsideVirtualRoot
            }

            let remoteChild = sourceURL.appendingPathComponent(name)
            let localChild = destinationURL.appendingPathComponent(name, isDirectory: entry.type == .folder)
            do {
                switch entry.type {
                case .folder:
                    try copyDirectoryToLocal(
                        atPath: remoteChild.path,
                        to: localChild,
                        depth: depth + 1,
                        bestEffortUnreadableEntries: bestEffortUnreadableEntries
                    )
                case .file:
                    let data = try readFileData(atPath: remoteChild.path)
                    try data.write(to: localChild, options: .atomic)
                case .symlink:
                    try FileManager.default.createSymbolicLink(
                        atPath: localChild.path,
                        withDestinationPath: entry.destURL.path
                    )
                }
            } catch {
                if !bestEffortUnreadableEntries { throw error }
            }
        }
    }

    private static func isConnectionFailure(_ error: Error) -> Bool {
        if CoreMediaUsrLibexecReader.isSharedSessionConnectionFailure(error) { return true }
        guard let readerError = error as? CoreMediaReaderError else { return false }
        switch readerError {
        case .connectionInterrupted, .xpcUnavailable, .memoryOriginHandshakeFailed, .coreMediaUnavailable:
            return true
        default:
            return false
        }
    }

    private static func validateVirtualPath(_ path: String) throws {
        guard rootPath(for: path) != nil else {
            throw CoreMediaReaderError.pathOutsideVirtualRoot
        }
        let components = path.split(separator: "/")
        guard !components.contains("..") else {
            throw CoreMediaReaderError.pathOutsideVirtualRoot
        }
    }

    private static func makeFolderItem(at url: URL) -> FileItem {
        let epochDate = Date(timeIntervalSince1970: 0)
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd-yyyy h:mm a"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let epochDateString = formatter.string(from: epochDate)

        return FileItem(
            name: url.lastPathComponent,
            fileURL: url,
            destURL: url,
            type: .folder,
            uttype: .folder,
            size: 0,
            creationDate: epochDate,
            modifiedDate: epochDate,
            creationDateStr: epochDateString,
            modifiedDateStr: epochDateString,
            hidden: false,
            posixPerms: "",
            owner: "",
            group: "",
            readable: nil,
            writable: nil,
            executable: nil
        )
    }

    private enum CoreMediaReaderError: LocalizedError {
        case pathOutsideVirtualRoot
        case coreMediaUnavailable
        case xpcUnavailable
        case memoryOriginHandshakeFailed
        case connectionInterrupted(String)
        case couldNotOpenPath(String)
        case notDirectory(String)
        case notRegularFile(String)
        case fileTooLarge(Int64, Int)
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case .pathOutsideVirtualRoot:
                return "The virtual reader is limited to its configured read-only Library roots."
            case .coreMediaUnavailable:
                return "CoreMedia could not be loaded or a required symbol is unavailable."
            case .xpcUnavailable:
                return "The CoreMedia bytestream XPC service is unavailable."
            case .memoryOriginHandshakeFailed:
                return "The CoreMedia memory-origin handshake could not be established."
            case .connectionInterrupted(let path):
                return "The CoreMedia XPC connection was interrupted while opening \(path)."
            case .couldNotOpenPath(let path):
                return "CoreMedia could not open \(path)."
            case .notDirectory(let path):
                return "\(path) is not a directory."
            case .notRegularFile(let path):
                return "\(path) is not a regular file."
            case .fileTooLarge(let size, let limit):
                return "File is \(size) bytes; the in-memory preview limit is \(limit) bytes."
            case .readFailed(let path):
                return "Could not read \(path)."
            }
        }
    }

}


/// Routes CoreMedia virtual paths through one process-wide XPC session.
/// /usr/libexec remains the owner of that session; the Library roots delegate to it.
enum CoreMediaVirtualSystemPathReader {
    static let reopenAppMessage = CoreMediaUsrLibexecReader.reopenAppMessage

    static func containsVirtualPath(_ url: URL) -> Bool {
        containsVirtualPath(url.standardizedFileURL.path)
    }

    static func containsVirtualPath(_ path: String) -> Bool {
        CoreMediaUsrLibexecReader.containsVirtualPath(path)
            || CoreMediaLibraryPathReader.containsVirtualPath(path)
    }

    static func isRootPath(_ url: URL) -> Bool {
        CoreMediaUsrLibexecReader.isRootPath(url)
            || CoreMediaLibraryPathReader.isRootPath(url)
    }

    static func rootFolderItem(at url: URL) -> FileItem {
        if CoreMediaUsrLibexecReader.isRootPath(url) {
            return CoreMediaUsrLibexecReader.rootFolderItem(at: url)
        }
        return CoreMediaLibraryPathReader.rootFolderItem(at: url)
    }

    static func listDirectory(at url: URL) throws -> [FileItem] {
        try listDirectory(at: url.standardizedFileURL.path)
    }

    static func listDirectory(at path: String) throws -> [FileItem] {
        if CoreMediaUsrLibexecReader.containsVirtualPath(path) {
            return try CoreMediaUsrLibexecReader.listDirectory(at: path)
        }
        return try CoreMediaLibraryPathReader.listDirectory(at: path)
    }

    static func infoData(atPath path: String) -> (item: FileItem?, directorySize: Int64?) {
        if CoreMediaUsrLibexecReader.containsVirtualPath(path) {
            return CoreMediaUsrLibexecReader.infoData(atPath: path)
        }
        return CoreMediaLibraryPathReader.infoData(atPath: path)
    }

    static func canReadDirectory(at url: URL) -> Bool {
        if CoreMediaUsrLibexecReader.containsVirtualPath(url) {
            return CoreMediaUsrLibexecReader.canReadDirectory(at: url)
        }
        return CoreMediaLibraryPathReader.canReadDirectory(at: url)
    }

    static func isDirectory(at url: URL) -> Bool {
        if CoreMediaUsrLibexecReader.containsVirtualPath(url) {
            return CoreMediaUsrLibexecReader.isDirectory(at: url)
        }
        return CoreMediaLibraryPathReader.isDirectory(at: url)
    }

    static func canReadFile(at url: URL) -> Bool {
        if CoreMediaUsrLibexecReader.containsVirtualPath(url) {
            return CoreMediaUsrLibexecReader.canReadFile(at: url)
        }
        return CoreMediaLibraryPathReader.canReadFile(at: url)
    }

    static func readFileData(atPath path: String, maximumBytes: Int = 64 * 1024 * 1024) throws -> Data {
        if CoreMediaUsrLibexecReader.containsVirtualPath(path) {
            return try CoreMediaUsrLibexecReader.readFileData(atPath: path, maximumBytes: maximumBytes)
        }
        return try CoreMediaLibraryPathReader.readFileData(atPath: path, maximumBytes: maximumBytes)
    }

    static func copyDirectoryToLocal(
        atPath path: String,
        to destinationURL: URL,
        bestEffortUnreadableEntries: Bool = false
    ) throws {
        if CoreMediaUsrLibexecReader.containsVirtualPath(path) {
            try CoreMediaUsrLibexecReader.copyDirectoryToLocal(
                atPath: path,
                to: destinationURL,
                bestEffortUnreadableEntries: bestEffortUnreadableEntries
            )
        } else {
            try CoreMediaLibraryPathReader.copyDirectoryToLocal(
                atPath: path,
                to: destinationURL,
                bestEffortUnreadableEntries: bestEffortUnreadableEntries
            )
        }
    }

    static func shouldSuggestAppReopen(for error: Error, at url: URL) -> Bool {
        if CoreMediaUsrLibexecReader.containsVirtualPath(url) {
            return CoreMediaUsrLibexecReader.shouldSuggestAppReopen(for: error, at: url)
        }
        return CoreMediaLibraryPathReader.shouldSuggestAppReopen(for: error, at: url)
    }
}
