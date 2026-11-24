import Foundation
import Darwin
import CoreFoundation
import UniformTypeIdentifiers

/// Read-only, in-memory directory provider for /usr/libexec. Directory entries
/// and file bytes are obtained on demand through the CoreMedia bytestream XPC flow;
/// no filesystem copy is written.
enum CoreMediaUsrLibexecReader {
    static let remotePath = "/usr/libexec"

    private static let sessionLock = NSRecursiveLock()
    // One process-lifetime CoreMedia/XPC session is shared by /usr/libexec and
    // the two virtual /Library roots. It is lazy.
    private static var reusableSession: CoreMediaSession?
    // A transport failure permanently invalidates this process-lifetime session.
    // Keep the object retained rather than releasing the XPC connection during
    // an interrupted callback; the UI already instructs the user to relaunch.
    private static var sharedSessionPermanentlyFailed = false
    private static let additionalSharedRoots = [
        "/Library/Ringtones",
        "/Library/RegionFeatures"
    ]
    private static let snapshotCondition = NSCondition()
    private static var snapshotAttempted = false
    private static var snapshotInProgress = false
    private static var cachedSnapshot: DirectorySnapshot?
    private static var cachedSnapshotError: Error?

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

    static func containsVirtualPath(_ path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return normalized == remotePath || normalized.hasPrefix(remotePath + "/")
    }

    static func isRootPath(_ url: URL) -> Bool {
        url.standardizedFileURL.path == remotePath
    }

    /// The first actual contact with /usr/libexec performs one complete snapshot.
    /// Both File Browser navigation and Info use this same in-memory result.
    private static func ensureSnapshot() throws -> DirectorySnapshot {
        snapshotCondition.lock()
        var waitedForExistingScan = false
        while snapshotInProgress {
            waitedForExistingScan = true
            snapshotCondition.wait()
        }
        if let cachedSnapshot {
            snapshotCondition.unlock()
            return cachedSnapshot
        }
        if let cachedSnapshotError {
            // A concurrent caller that waited for this exact attempt receives the
            // same result. A later explicit user action may start one fresh attempt.
            if waitedForExistingScan {
                snapshotCondition.unlock()
                throw cachedSnapshotError
            }
            self.cachedSnapshotError = nil
            snapshotAttempted = false
        }
        guard !snapshotAttempted else {
            snapshotCondition.unlock()
            throw CoreMediaReaderError.coreMediaUnavailable
        }
        snapshotAttempted = true
        snapshotInProgress = true
        snapshotCondition.unlock()

        // Keep the previous cleanup behavior, but perform it only on the first
        // actual contact with /usr/libexec rather than merely entering /usr.
        let stalePreviewDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ErosionVirtualPreviews", isDirectory: true)
        try? FileManager.default.removeItem(at: stalePreviewDirectory)

        do {
            var snapshot = DirectorySnapshot()
            var visitedEntries = 0
            try withSerializedSession { session in
                _ = try buildDirectorySnapshot(
                    using: session,
                    path: remotePath,
                    depth: 0,
                    visitedEntries: &visitedEntries,
                    snapshot: &snapshot
                )
            }

            snapshotCondition.lock()
            cachedSnapshot = snapshot
            snapshotInProgress = false
            snapshotCondition.broadcast()
            snapshotCondition.unlock()
            return snapshot
        } catch {
            snapshotCondition.lock()
            cachedSnapshotError = error
            snapshotInProgress = false
            snapshotCondition.broadcast()
            snapshotCondition.unlock()
            throw error
        }
    }

    /// Builds listings and aggregate sizes in one CoreMedia session. Unreadable
    /// individual entries are skipped while the rest of the directory is retained.
    /// A directory size is cached only when its entire subtree was enumerated.
    private static func buildDirectorySnapshot(
        using session: CoreMediaSession,
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
            listing = try session.listDirectoryResult(at: path)
        } catch {
            if isConnectionFailure(error) || path == remotePath {
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
                    using: session,
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
        let snapshot = try ensureSnapshot()
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
        guard containsVirtualPath(normalized), let snapshot = try? ensureSnapshot() else {
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
        guard let snapshot = try? ensureSnapshot() else { return false }
        return snapshot.listings[path] != nil
    }

    static func canReadFile(at url: URL) -> Bool {
        guard containsVirtualPath(url) else { return false }
        let path = url.standardizedFileURL.path
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard let snapshot = try? ensureSnapshot(),
              let entries = snapshot.listings[parent] else { return false }
        return entries.contains { $0.fileURL.standardizedFileURL.path == path && $0.type == .file }
    }

    static func rootFolderItem() -> FileItem {
        rootFolderItem(at: URL(fileURLWithPath: remotePath, isDirectory: true))
    }

    /// The /usr row is metadata-only. Do not contact CoreMedia just by entering /usr.
    static func rootFolderItem(at url: URL) -> FileItem {
        makeFolderItem(at: url)
    }

    static let reopenAppMessage = "CoreMedia lost its connection to a virtual system directory. Please wait a little bit to view this path again."

    /// Show the wait hint only for failures of the CoreMedia XPC transport/session.
    static func shouldSuggestAppReopen(for error: Error, at url: URL) -> Bool {
        guard containsVirtualPath(url), let readerError = error as? CoreMediaReaderError else {
            return false
        }
        switch readerError {
        case .connectionInterrupted, .xpcUnavailable, .memoryOriginHandshakeFailed, .coreMediaUnavailable:
            return true
        case .couldNotOpenPath(let failedPath):
            return failedPath == url.standardizedFileURL.path && failedPath == remotePath
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
        let snapshot = try ensureSnapshot()
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
        return try withSerializedSession { session in
            try session.readFileData(at: normalized, maximumBytes: maximumBytes)
        }
    }

    /// Lists a directory through the single shared CoreMedia session. This is
    /// used by /usr/libexec and the virtual /Library roots.
    static func listDirectoryUsingSharedSession(
        at path: String,
        probeRegularFiles: Bool = true
    ) throws -> (items: [FileItem], isComplete: Bool, directoryItem: FileItem?) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        try validateSharedSessionPath(normalized)
        return try withSerializedSession { session in
            let result = try session.listDirectoryResult(
                at: normalized,
                probeRegularFiles: probeRegularFiles
            )
            return (result.items, result.isComplete, result.directoryItem)
        }
    }

    /// Reads a file through the exact same retained CoreMedia/XPC session used
    /// for directory enumeration and all configured virtual roots.
    static func readFileDataUsingSharedSession(atPath path: String, maximumBytes: Int = 64 * 1024 * 1024) throws -> Data {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        try validateSharedSessionPath(normalized)
        return try withSerializedSession { session in
            try session.readFileData(at: normalized, maximumBytes: maximumBytes)
        }
    }

    static func isSharedSessionConnectionFailure(_ error: Error) -> Bool {
        isConnectionFailure(error)
    }

    static func shouldSuggestAppReopenForSharedSession(for error: Error, at path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard sharedRootPath(for: normalized) != nil,
              let readerError = error as? CoreMediaReaderError else { return false }
        switch readerError {
        case .connectionInterrupted, .xpcUnavailable, .memoryOriginHandshakeFailed, .coreMediaUnavailable:
            return true
        case .couldNotOpenPath(let failedPath):
            return failedPath == normalized && failedPath == sharedRootPath(for: failedPath)
        default:
            return false
        }
    }

    private static func sharedRootPath(for path: String) -> String? {
        ([remotePath] + additionalSharedRoots).first { path == $0 || path.hasPrefix($0 + "/") }
    }

    private static func validateSharedSessionPath(_ path: String) throws {
        guard sharedRootPath(for: path) != nil,
              !path.split(separator: "/").contains("..") else {
            throw CoreMediaReaderError.pathOutsideVirtualRoot
        }
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
        guard let readerError = error as? CoreMediaReaderError else { return false }
        switch readerError {
        case .connectionInterrupted, .xpcUnavailable, .memoryOriginHandshakeFailed, .coreMediaUnavailable:
            return true
        default:
            return false
        }
    }

    private static func validateVirtualPath(_ path: String) throws {
        let isUsrPath = path == remotePath || path.hasPrefix(remotePath + "/")
        guard isUsrPath else {
            throw CoreMediaReaderError.pathOutsideVirtualRoot
        }
        let components = path.split(separator: "/")
        guard !components.contains("..") else {
            throw CoreMediaReaderError.pathOutsideVirtualRoot
        }
    }

    private static func withSerializedSession<T>(_ operation: (CoreMediaSession) throws -> T) throws -> T {
        sessionLock.lock()
        defer { sessionLock.unlock() }

        if sharedSessionPermanentlyFailed {
            throw CoreMediaReaderError.connectionInterrupted("virtual system path")
        }
        if reusableSession == nil {
            reusableSession = try CoreMediaSession()
        }
        guard let session = reusableSession else {
            throw CoreMediaReaderError.xpcUnavailable
        }

        do {
            return try operation(session)
        } catch {
            // Do not drop/release a failed XPC connection from a background
            // worker. Keep one session object for the lifetime of this app
            // process and require a relaunch after an interrupted transport.
            if isConnectionFailure(error) {
                sharedSessionPermanentlyFailed = true
            }
            throw error
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
                return "The virtual reader is limited to /usr/libexec."
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

    private final class CoreMediaSession {
        private typealias FBasic = @convention(c) (UInt32, UInt64, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
        private typealias FBegin = @convention(c) (UnsafeMutableRawPointer?) -> Int32
        private typealias FComplete = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
        private typealias FRecipient = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
        private typealias FSetURL = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>, UnsafeRawPointer?) -> Int32
        private typealias FConnectionCreate = @convention(c) (UnsafePointer<CChar>, UnsafeMutableRawPointer?, UInt64) -> UnsafeMutableRawPointer?
        private typealias FSetEventHandler = @convention(c) (UnsafeMutableRawPointer?, AnyObject) -> Void
        private typealias FResume = @convention(c) (UnsafeMutableRawPointer?) -> Void
        private typealias FCancel = @convention(c) (UnsafeMutableRawPointer?) -> Void
        private typealias FSendReply = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, AnyObject) -> Void
        private typealias FGetValue = @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> OpaquePointer?
        private typealias FGetUInt64 = @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> UInt64
        private typealias FSetUInt64 = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>, UInt64) -> Void
        private typealias FDupFD = @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> Int32
        private typealias FGetType = @convention(c) (OpaquePointer?) -> OpaquePointer?
        private typealias FTypeName = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
        private typealias FRetain = @convention(c) (OpaquePointer?) -> Void
        private typealias FRelease = @convention(c) (OpaquePointer?) -> Void

        private let coreMediaHandle: UnsafeMutableRawPointer
        private let connection: UnsafeMutableRawPointer
        private let fBasic: FBasic
        private let fBegin: FBegin
        private let fComplete: FComplete
        private let fRecipient: FRecipient
        private let fSetURL: FSetURL
        private let fSetEventHandler: FSetEventHandler
        private let fResume: FResume
        private let fCancel: FCancel
        private let fSendReply: FSendReply
        private let fGetValue: FGetValue
        private let fGetUInt64: FGetUInt64
        private let fSetUInt64: FSetUInt64
        private let fDupFD: FDupFD
        private let fGetType: FGetType
        private let fTypeName: FTypeName
        private let fRetain: FRetain
        private let fRelease: FRelease

        private var memoryRecipient: UnsafeMutableRawPointer?
        private var memoryOrigin: UnsafeMutableRawPointer?
        private let interruptionStateLock = NSLock()
        private var connectionWasInterrupted = false

        /// Synchronizes XPC reply ownership across the timeout and reply-handler
        /// paths. A reply arriving after timeout must be released, not retained
        /// in a captured local that the caller will never read again.
        private final class ReplyState {
            let lock = NSLock()
            var timedOut = false
            var completed = false
            var reply: OpaquePointer?
            var replyType = "?"
        }

        init() throws {
            guard let coreMedia = dlopen(
                "/System/Library/Frameworks/CoreMedia.framework/CoreMedia",
                RTLD_NOW | RTLD_LOCAL
            ) else {
                throw CoreMediaReaderError.coreMediaUnavailable
            }

            let rtld = UnsafeMutableRawPointer(bitPattern: -2)
            guard
                let pBasic = dlsym(coreMedia, "FigXPCCreateBasicMessage"),
                let pBegin = dlsym(coreMedia, "FigMemoryOriginBeginEstablishingMemoryRecipientByFillingInXPCMessage1"),
                let pComplete = dlsym(coreMedia, "FigMemoryOriginCompleteEstablishingMemoryRecipientUsingXPCMessage2"),
                let pRecipient = dlsym(coreMedia, "FigMemoryRecipientCreateWithXPCMessage1AndUpdateXPCMessage2"),
                let pSetURL = dlsym(coreMedia, "FigXPCMessageSetCFURL"),
                let pConnectionCreate = dlsym(rtld, "xpc_connection_create_mach_service"),
                let pSetEventHandler = dlsym(rtld, "xpc_connection_set_event_handler"),
                let pResume = dlsym(rtld, "xpc_connection_resume"),
                let pCancel = dlsym(rtld, "xpc_connection_cancel"),
                let pSendReply = dlsym(rtld, "xpc_connection_send_message_with_reply"),
                let pGetValue = dlsym(rtld, "xpc_dictionary_get_value"),
                let pGetUInt64 = dlsym(rtld, "xpc_dictionary_get_uint64"),
                let pSetUInt64 = dlsym(rtld, "xpc_dictionary_set_uint64"),
                let pDupFD = dlsym(rtld, "xpc_dictionary_dup_fd"),
                let pGetType = dlsym(rtld, "xpc_get_type"),
                let pTypeName = dlsym(rtld, "xpc_type_get_name"),
                let pRetain = dlsym(rtld, "xpc_retain"),
                let pRelease = dlsym(rtld, "xpc_release")
            else {
                dlclose(coreMedia)
                throw CoreMediaReaderError.coreMediaUnavailable
            }

            guard let newConnection = "com.apple.coremedia.mediaplaybackd.bytestream.xpc".withCString({
                unsafeBitCast(pConnectionCreate, to: FConnectionCreate.self)($0, nil, 0)
            }) else {
                dlclose(coreMedia)
                throw CoreMediaReaderError.xpcUnavailable
            }

            self.coreMediaHandle = coreMedia
            self.connection = newConnection
            self.fBasic = unsafeBitCast(pBasic, to: FBasic.self)
            self.fBegin = unsafeBitCast(pBegin, to: FBegin.self)
            self.fComplete = unsafeBitCast(pComplete, to: FComplete.self)
            self.fRecipient = unsafeBitCast(pRecipient, to: FRecipient.self)
            self.fSetURL = unsafeBitCast(pSetURL, to: FSetURL.self)
            self.fSetEventHandler = unsafeBitCast(pSetEventHandler, to: FSetEventHandler.self)
            self.fResume = unsafeBitCast(pResume, to: FResume.self)
            self.fCancel = unsafeBitCast(pCancel, to: FCancel.self)
            self.fSendReply = unsafeBitCast(pSendReply, to: FSendReply.self)
            self.fGetValue = unsafeBitCast(pGetValue, to: FGetValue.self)
            self.fGetUInt64 = unsafeBitCast(pGetUInt64, to: FGetUInt64.self)
            self.fSetUInt64 = unsafeBitCast(pSetUInt64, to: FSetUInt64.self)
            self.fDupFD = unsafeBitCast(pDupFD, to: FDupFD.self)
            self.fGetType = unsafeBitCast(pGetType, to: FGetType.self)
            self.fTypeName = unsafeBitCast(pTypeName, to: FTypeName.self)
            self.fRetain = unsafeBitCast(pRetain, to: FRetain.self)
            self.fRelease = unsafeBitCast(pRelease, to: FRelease.self)

            let eventHandler: @convention(block) (UnsafeMutableRawPointer?) -> Void = { [weak self] event in
                guard let self, let event else { return }
                // XPC delivers connection interruption/invalidation as an error event.
                // Track it so a cached long-lived session is never reused afterwards.
                if self.typeName(OpaquePointer(event)) == "error" {
                    self.interruptionStateLock.lock()
                    self.connectionWasInterrupted = true
                    self.interruptionStateLock.unlock()
                }
            }
            self.fSetEventHandler(self.connection, eventHandler as AnyObject)
            self.fResume(self.connection)

            do {
                try establishMemoryOrigin()
            } catch {
                releaseFigReference(memoryOrigin)
                releaseFigReference(memoryRecipient)
                memoryOrigin = nil
                memoryRecipient = nil
                self.fCancel(self.connection)
                self.fRelease(OpaquePointer(self.connection))
                dlclose(coreMedia)
                throw error
            }
        }

        deinit {
            releaseFigReference(memoryOrigin)
            releaseFigReference(memoryRecipient)
            fCancel(connection)
            fRelease(OpaquePointer(connection))
            dlclose(coreMediaHandle)
        }

        private func releaseFigReference(_ pointer: UnsafeMutableRawPointer?) {
            guard let pointer else { return }
            Unmanaged<CFTypeRef>.fromOpaque(pointer).release()
        }

        private var isTransportInterrupted: Bool {
            interruptionStateLock.lock()
            defer { interruptionStateLock.unlock() }
            return connectionWasInterrupted
        }

        private func typeName(_ object: OpaquePointer?) -> String {
            guard let object, let type = fGetType(object), let name = fTypeName(type) else { return "?" }
            return String(cString: name)
        }

        private func send(_ message: UnsafeMutableRawPointer?) -> (OpaquePointer?, String) {
            guard let message else { return (nil, "nil") }
            guard !isTransportInterrupted else { return (nil, "connection-error") }
            let semaphore = DispatchSemaphore(value: 0)
            let state = ReplyState()
            let replyHandler: @convention(block) (UnsafeMutableRawPointer?) -> Void = { object in
                var receivedType = "?"
                var retainedReply: OpaquePointer?
                if let object {
                    receivedType = self.typeName(OpaquePointer(object))
                    if receivedType == "dictionary" || receivedType == "error" {
                        self.fRetain(OpaquePointer(object))
                        retainedReply = OpaquePointer(object)
                    }
                }

                state.lock.lock()
                if state.timedOut {
                    state.lock.unlock()
                    if let retainedReply { self.fRelease(retainedReply) }
                } else {
                    state.reply = retainedReply
                    state.replyType = receivedType
                    state.completed = true
                    state.lock.unlock()
                }
                semaphore.signal()
            }

            fSendReply(connection, message, nil, replyHandler as AnyObject)
            let waitResult = semaphore.wait(timeout: .now() + 8)

            state.lock.lock()
            if waitResult == .success || state.completed {
                let result = (state.reply, state.replyType)
                state.reply = nil // Transfer the retained XPC object to the caller.
                state.lock.unlock()
                return result
            }

            state.timedOut = true
            state.lock.unlock()
            // This session cannot be used for another message after a timeout.
            // Cancel it now so a delayed reply cannot keep the connection alive.
            fCancel(connection)
            return (nil, "timeout-8s")
        }

        private func establishMemoryOrigin() throws {
            var rp2Ready = false
            var handshakeReady = false

            var rp1Message: UnsafeMutableRawPointer?
            if fBasic(0x2e727031, 0, &rp1Message) == 0, let message1 = rp1Message {
                let (reply1, replyType1) = send(message1)
                fRelease(OpaquePointer(message1))
                if let reply1, replyType1 == "dictionary" {
                    var rp2Message: UnsafeMutableRawPointer?
                    if fBasic(0x2e727032, 0, &rp2Message) == 0, let message2 = rp2Message {
                        let recipientStatus = "mconf".withCString {
                            fRecipient(reply1, message2, $0, &memoryRecipient)
                        }
                        if recipientStatus == 0, memoryRecipient != nil {
                            let (reply2, replyType2) = send(message2)
                            rp2Ready = replyType2 == "dictionary" && reply2 != nil
                            if let reply2 { fRelease(reply2) }
                        }
                        fRelease(OpaquePointer(message2))
                    }
                    fRelease(reply1)
                }
            }

            if rp2Ready {
                var originMessage: UnsafeMutableRawPointer?
                if fBasic(0x2e6f7267, 0, &originMessage) == 0, let message = originMessage {
                    if fBegin(message) == 0 {
                        let (originReply, originReplyType) = send(message)
                        if let originReply {
                            if originReplyType == "dictionary" {
                                let status = fComplete(originReply, &memoryOrigin)
                                handshakeReady = status == 0 && memoryOrigin != nil
                            }
                            fRelease(originReply)
                        }
                    }
                    fRelease(OpaquePointer(message))
                }
            }

            guard handshakeReady else {
                throw CoreMediaReaderError.memoryOriginHandshakeFailed
            }
        }

        private func openDescriptor(
            for path: String,
            isDirectory: Bool = false
        ) throws -> Int32 {
            // FigXPCMessageSetCFURL receives URL metadata, including the directory
            // bit. Mark directory roots and traversed folders explicitly; passing
            // them as ordinary file URLs can make CoreMedia's open result unstable
            // for some /Library trees (notably Ringtones).
            let fileURL = URL(fileURLWithPath: path, isDirectory: isDirectory) as CFURL
            var message: UnsafeMutableRawPointer?
            guard fBasic(0x4375726c, 0, &message) == 0, let message else {
                throw CoreMediaReaderError.couldNotOpenPath(path)
            }
            _ = fSetURL(message, "CreationURL", Unmanaged.passUnretained(fileURL).toOpaque())
            fSetUInt64(message, "FileOpenOptions", 0)
            let (reply, replyType) = send(message)
            fRelease(OpaquePointer(message))

            guard replyType == "dictionary", let reply else {
                if let reply { fRelease(reply) }
                if replyType == "timeout-8s" || replyType == "connection-error"
                    || isTransportInterrupted || (reply == nil && replyType == "?") {
                    throw CoreMediaReaderError.connectionInterrupted(path)
                }
                throw CoreMediaReaderError.couldNotOpenPath(path)
            }
            guard let details = "ByteStreamDetails".withCString({ fGetValue(reply, $0) }) else {
                fRelease(reply)
                throw CoreMediaReaderError.couldNotOpenPath(path)
            }

            let objectID = "ObjectID".withCString { fGetUInt64(details, $0) }
            let fileDescriptor = "FileDescriptor".withCString { fDupFD(details, $0) }

            var closeMessage: UnsafeMutableRawPointer?
            if fBasic(0x646f6f6d, objectID, &closeMessage) == 0, let closeMessage {
                let (closeReply, closeReplyType) = send(closeMessage)
                if let closeReply { fRelease(closeReply) }
                fRelease(OpaquePointer(closeMessage))
                if closeReplyType == "timeout-8s" || closeReplyType == "connection-error" || isTransportInterrupted {
                    if fileDescriptor >= 0 { close(fileDescriptor) }
                    fRelease(reply)
                    throw CoreMediaReaderError.connectionInterrupted(path)
                }
            }
            fRelease(reply)

            guard fileDescriptor >= 0 else {
                throw CoreMediaReaderError.couldNotOpenPath(path)
            }
            return fileDescriptor
        }

        func listDirectoryResult(
            at path: String,
            probeRegularFiles: Bool = true
        ) throws -> DirectoryListingResult {
            let directoryFD = try openDescriptor(for: path, isDirectory: true)
            var directoryStat = stat()
            let directoryItem: FileItem? = fstat(directoryFD, &directoryStat) == 0
                ? makeFileItem(
                    name: URL(fileURLWithPath: path).lastPathComponent,
                    url: URL(fileURLWithPath: path, isDirectory: true),
                    metadata: directoryStat,
                    isDirectory: true
                )
                : nil
            guard let directory = fdopendir(directoryFD) else {
                close(directoryFD)
                throw CoreMediaReaderError.notDirectory(path)
            }
            defer { closedir(directory) }
            let enumerationFD = dirfd(directory)
            var items: [FileItem] = []
            var isComplete = true

            while true {
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 { throw CoreMediaReaderError.readFailed(path) }
                    break
                }
                let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                        String(cString: $0)
                    }
                }
                if name == "." || name == ".." { continue }

                // fstatat() can return incomplete or synthetic metadata for a
                // CoreMedia directory FD. Use it only to reject known symlinks and
                // special files; obtain the authoritative timestamps and POSIX mode
                // from the descriptor opened for the child itself. The virtual
                // /usr/libexec Info view presents its system ownership as root:wheel.
                var directoryEntryStat = stat()
                let statResult = name.withCString {
                    fstatat(enumerationFD, $0, &directoryEntryStat, AT_SYMLINK_NOFOLLOW)
                }

                let childURL = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(name)
                let childPath = childURL.standardizedFileURL.path
                let expectedDirectory: Bool

                if statResult == 0 {
                    let entryMode = directoryEntryStat.st_mode & mode_t(Darwin.S_IFMT)
                    guard entryMode == mode_t(Darwin.S_IFDIR) || entryMode == mode_t(Darwin.S_IFREG) else {
                        continue
                    }
                    expectedDirectory = entryMode == mode_t(Darwin.S_IFDIR)
                } else {
                    // Preserve the PoC fallback when fstatat() on a CoreMedia
                    // directory FD cannot stat a child name.
                    let entryType = entry.pointee.d_type
                    if entryType == UInt8(DT_DIR) || entryType == 4 {
                        expectedDirectory = true
                    } else if entryType == UInt8(DT_REG) {
                        expectedDirectory = false
                    } else if entryType == UInt8(DT_UNKNOWN) {
                        // Keep the rest of the directory usable. The listing is
                        // marked incomplete so Info will not report a partial size.
                        isComplete = false
                        continue
                    } else {
                        // Known symlink and special entries are not followed.
                        continue
                    }
                }

                let childFD: Int32
                do {
                    childFD = try openDescriptor(for: childPath, isDirectory: expectedDirectory)
                } catch {
                    if CoreMediaUsrLibexecReader.isConnectionFailure(error) {
                        throw error
                    }
                    isComplete = false
                    continue
                }
                var childItem: FileItem?
                do {
                    // Close this descriptor before moving to the next entry. A defer
                    // directly in the enumeration loop would retain one FD per item
                    // until the whole directory had been scanned (EMFILE on large dirs).
                    defer { close(childFD) }

                    var itemStat = stat()
                    guard fstat(childFD, &itemStat) == 0 else {
                        isComplete = false
                        continue
                    }
                    let childType = itemStat.st_mode & mode_t(Darwin.S_IFMT)
                    let childIsDirectory = childType == mode_t(Darwin.S_IFDIR)
                    let childIsRegularFile = childType == mode_t(Darwin.S_IFREG)
                    guard (expectedDirectory && childIsDirectory) || (!expectedDirectory && childIsRegularFile) else {
                        isComplete = false
                        continue
                    }

                    // Some virtual roots are intentionally write-only. Their listing
                    // must not probe file contents, even by reading a single byte.
                    if probeRegularFiles && childIsRegularFile && itemStat.st_size > 0 {
                        var probe: UInt8 = 0
                        var probeResult: Int
                        repeat {
                            probeResult = pread(childFD, &probe, 1, 0)
                        } while probeResult < 0 && errno == EINTR
                        if probeResult != 1 {
                            isComplete = false
                        }
                    }

                    childItem = makeFileItem(
                        name: name,
                        url: childURL,
                        metadata: itemStat,
                        isDirectory: childIsDirectory
                    )
                }
                if let childItem {
                    items.append(childItem)
                }
            }
            return DirectoryListingResult(items: items, isComplete: isComplete, directoryItem: directoryItem)
        }

        func readFileData(at path: String, maximumBytes: Int) throws -> Data {
            let fd = try openDescriptor(for: path)
            defer { close(fd) }

            var fileStat = stat()
            guard fstat(fd, &fileStat) == 0 else {
                throw CoreMediaReaderError.readFailed(path)
            }
            guard (fileStat.st_mode & mode_t(Darwin.S_IFMT)) == mode_t(Darwin.S_IFREG) else {
                throw CoreMediaReaderError.notRegularFile(path)
            }

            let size = Int64(fileStat.st_size)
            guard size >= 0, size <= Int64(maximumBytes) else {
                throw CoreMediaReaderError.fileTooLarge(size, maximumBytes)
            }

            var result = Data()
            result.reserveCapacity(Int(size))
            var offset: off_t = 0
            let chunkSize = 64 * 1024
            while offset < off_t(size) {
                let remaining = Int(off_t(size) - offset)
                var buffer = [UInt8](repeating: 0, count: min(chunkSize, remaining))
                let count = pread(fd, &buffer, buffer.count, offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw CoreMediaReaderError.readFailed(path)
                }
                if count == 0 { break }
                result.append(contentsOf: buffer.prefix(count))
                offset += off_t(count)
            }
            guard result.count == Int(size) else {
                throw CoreMediaReaderError.readFailed(path)
            }
            return result
        }

        private func makeFileItem(name: String, url: URL, metadata: stat, isDirectory: Bool) -> FileItem {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd-yyyy h:mm a"
            formatter.locale = Locale(identifier: "en_US_POSIX")

            // CoreMedia's bytestream stat timestamps are not reliable for this
            // virtual listing. Match the epoch placeholder used for other system
            // paths when the filesystem does not expose trustworthy dates.
            let creationDate = Date(timeIntervalSince1970: 0)
            let modifiedDate = creationDate
            let mode = metadata.st_mode & 0o7777
            let extensionType = UTType(filenameExtension: url.pathExtension) ?? .data

            return FileItem(
                name: name,
                fileURL: url,
                destURL: url,
                type: isDirectory ? .folder : .file,
                uttype: isDirectory ? .folder : extensionType,
                size: max(0, Int(metadata.st_size)),
                creationDate: creationDate,
                modifiedDate: modifiedDate,
                creationDateStr: formatter.string(from: creationDate),
                modifiedDateStr: formatter.string(from: modifiedDate),
                hidden: name.hasPrefix("."),
                posixPerms: String(format: "%04o", UInt32(mode)),
                owner: POSIXIdentityResolver.userName(metadata.st_uid),
                group: POSIXIdentityResolver.groupName(metadata.st_gid),
                readable: (mode & 0o444) != 0,
                // Keep POSIX mode above as returned by CoreMedia, but the separate
                // Writable field describes effective Erosion access. /usr/libexec
                // is in the app's explicit read-only system-path allowlist.
                writable: !SystemReadOnlyAccess.isReadOnly(url) && (mode & 0o222) != 0,
                executable: (mode & 0o111) != 0
            )
        }
    }

}

