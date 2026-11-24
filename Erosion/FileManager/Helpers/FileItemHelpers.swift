//
//  FileItemHelpers.swift
//  Filos
//
//  Created by lunginspector on 8/1/26.
//

import Foundation
import Darwin
import UniformTypeIdentifiers

struct FileItem: Identifiable {
    // A filesystem entry keeps the same SwiftUI identity across directory reloads
    // and search filtering. A random UUID recreated by getFileItem() made List
    // animate every sibling as a delete/insert after a single file operation.
    var id: String { fileURL.standardizedFileURL.path }
    var name: String
    var fileURL: URL
    var destURL: URL
    var type: FileType
    var uttype: UTType
    var size: Int
    var creationDate: Date
    var modifiedDate: Date
    var creationDateStr: String
    var modifiedDateStr: String
    
    var hidden: Bool
    var posixPerms: String
    var owner: String
    var group: String
    var readable: Bool?
    var writable: Bool?
    var executable: Bool?
}

let clearFileItem = FileItem(name: "", fileURL: URL(fileURLWithPath: ""), destURL: URL(fileURLWithPath: ""), type: .file, uttype: .data, size: 0, creationDate: Date(), modifiedDate: Date(), creationDateStr: "", modifiedDateStr: "", hidden: false, posixPerms: "", owner: "", group: "", readable: nil, writable: nil, executable: nil)


/// Resolves numeric POSIX identities through the device's own account database.
/// The libc lookup functions expose shared storage, so copy their names while
/// holding a lock. `/etc/passwd` and `/etc/group` are fallback sources for iOS
/// builds where a lookup service does not return an entry.
enum POSIXIdentityResolver {
    private static let lookupLock = NSLock()
    private static var userCache: [uid_t: String] = [:]
    private static var groupCache: [gid_t: String] = [:]
    private static let fallbackUsers: [Int32: String] = [
        -2: "nobody",
         0: "root",
         1: "daemon",
        24: "_networkd",
        25: "_wireless",
        34: "_neagent",
        64: "_securityd",
        65: "_mdnsresponder",
        75: "_sshd",
        98: "_ftp",
        99: "_unknown",
       241: "_distnote",
       245: "_astris",
       501: "mobile"
    ]
    // The baseline iPhone group database (group.iPhone). Runtime getgrgid()
    // and /etc/group results still take precedence over this fallback table.
    private static let fallbackGroups: [Int32: String] = [
        -2: "nobody", -1: "nogroup", 0: "wheel", 1: "daemon",
         2: "kmem", 3: "sys", 4: "tty", 5: "operator", 6: "mail",
         7: "bin", 8: "procview", 9: "procmod", 10: "owner", 12: "everyone",
        16: "group", 20: "staff", 24: "_networkd", 25: "_wireless",
        26: "_lp", 27: "_postfix", 28: "_postdrop", 29: "certusers",
        30: "_keytabusers", 34: "_neagent", 45: "utmp", 50: "authedusers",
        51: "interactusers", 52: "netusers", 53: "consoleusers", 54: "_mcxalr",
        58: "_serialnumberd", 59: "_devdocs", 60: "_sandbox", 61: "localaccounts",
        62: "netaccounts", 64: "_securityd", 65: "_mdnsresponder", 66: "_uucp",
        67: "_ard", 68: "dialer", 69: "network", 70: "_www", 72: "_cvs",
        73: "_svn", 74: "_mysql", 75: "_sshd", 76: "_qtss", 78: "_mailman",
        79: "_appserverusr", 80: "admin", 81: "_appserveradm", 82: "_clamav",
        83: "_amavisd", 84: "_jabber", 87: "_appowner", 88: "_windowserver",
        89: "_spotlight", 90: "accessibility", 91: "_tokend", 92: "_securityagent",
        93: "_calendar", 94: "_teamsserver", 95: "_update_sharing", 96: "_installer",
        97: "_atsserver", 98: "_lpadmin", 99: "_unknown", 241: "_distnote",
        501: "mobile"
    ]

    static func userName(_ uid: uid_t) -> String {
        lookupLock.lock()
        defer { lookupLock.unlock() }
        if let cached = userCache[uid] { return cached }

        let numericID = Int32(bitPattern: uid)
        let resolved: String
        if let record = getpwuid(uid), let rawName = record.pointee.pw_name {
            let name = String(cString: rawName)
            resolved = name.isEmpty
                ? (readDatabaseName(path: "/etc/passwd", id: numericID, nameColumn: 0, idColumn: 2)
                    ?? fallbackUsers[numericID] ?? String(uid))
                : name
        } else {
            resolved = readDatabaseName(path: "/etc/passwd", id: numericID, nameColumn: 0, idColumn: 2)
                ?? fallbackUsers[numericID]
                ?? String(uid)
        }
        userCache[uid] = resolved
        return resolved
    }

    static func groupName(_ gid: gid_t) -> String {
        lookupLock.lock()
        defer { lookupLock.unlock() }
        if let cached = groupCache[gid] { return cached }

        let numericID = Int32(bitPattern: gid)
        let resolved: String
        if let record = getgrgid(gid), let rawName = record.pointee.gr_name {
            let name = String(cString: rawName)
            resolved = name.isEmpty
                ? (readDatabaseName(path: "/etc/group", id: numericID, nameColumn: 0, idColumn: 2)
                    ?? fallbackGroups[numericID] ?? String(gid))
                : name
        } else {
            resolved = readDatabaseName(path: "/etc/group", id: numericID, nameColumn: 0, idColumn: 2)
                ?? fallbackGroups[numericID]
                ?? String(gid)
        }
        groupCache[gid] = resolved
        return resolved
    }

    private static func readDatabaseName(path: String, id: Int32, nameColumn: Int, idColumn: Int) -> String? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in contents.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: ":", omittingEmptySubsequences: false)
            guard columns.count > max(nameColumn, idColumn),
                  Int32(columns[idColumn]) == id else { continue }
            let name = String(columns[nameColumn])
            if !name.isEmpty && !name.hasPrefix("+") { return name }
        }
        return nil
    }
}

private enum FileItemDateFormatting {
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd-yyyy h:mm a"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    static func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }
}

/// Resolves the effective rwx class without launching three separate access
/// checks for every entry in a large directory.
private enum POSIXAccessEvaluator {
    private static let effectiveUID = geteuid()
    private static let effectiveGID = getegid()
    private static let supplementaryGroups: Set<gid_t> = {
        let count = getgroups(0, nil)
        guard count > 0 else { return [] }
        var groups = [gid_t](repeating: 0, count: Int(count))
        let actualCount = groups.withUnsafeMutableBufferPointer { buffer in
            getgroups(Int32(buffer.count), buffer.baseAddress)
        }
        guard actualCount > 0 else { return [] }
        return Set(groups.prefix(Int(actualCount)))
    }()

    static func flags(mode: mode_t, owner: uid_t, group: gid_t) -> (readable: Bool, writable: Bool, executable: Bool) {
        // Root can read/write regardless of rw bits, but execution still needs
        // at least one execute bit on the file.
        if effectiveUID == 0 {
            return (true, true, (mode & mode_t(0o111)) != 0)
        }

        let shift: mode_t
        if effectiveUID == owner {
            shift = 6
        } else if effectiveGID == group || supplementaryGroups.contains(group) {
            shift = 3
        } else {
            shift = 0
        }
        let effectiveMode = (mode >> shift) & mode_t(0o7)
        return (
            (effectiveMode & mode_t(0o4)) != 0,
            (effectiveMode & mode_t(0o2)) != 0,
            (effectiveMode & mode_t(0o1)) != 0
        )
    }
}

func getFileItem(at url: URL, isContainer: Bool = false) -> FileItem {
    var item = FileItem(
        name: url.lastPathComponent,
        fileURL: url,
        destURL: url,
        type: .file,
        uttype: .data,
        size: 0,
        creationDate: Date(),
        modifiedDate: Date(),
        creationDateStr: "",
        modifiedDateStr: "",
        hidden: url.lastPathComponent.hasPrefix("."),
        posixPerms: "",
        owner: "",
        group: "",
        readable: nil,
        writable: nil,
        executable: nil
    )

    if isContainer, let folderName = folderLabel(url: url) {
        item.name = folderName
    }

    // lstat supplies the entry's type, mode, owner, group and timestamps in a
    // single filesystem call. Avoid URL resourceValues plus three independent
    // FileManager access probes for every row in a large directory.
    var metadata = stat()
    let hasPOSIXMetadata = url.path.withCString { path in
        lstat(path, &metadata) == 0
    }

    if hasPOSIXMetadata {
        let fileKind = metadata.st_mode & mode_t(Darwin.S_IFMT)
        if fileKind == mode_t(Darwin.S_IFLNK) {
            item.type = .symlink
            if let rawTarget = try? fm.destinationOfSymbolicLink(atPath: url.path) {
                item.destURL = URL(
                    fileURLWithPath: rawTarget,
                    relativeTo: url.deletingLastPathComponent()
                ).standardizedFileURL
            }
        } else if fileKind == mode_t(Darwin.S_IFDIR) {
            item.type = .folder
        } else {
            item.type = .file
        }

        item.uttype = item.type == .folder
            ? .folder
            : (UTType(filenameExtension: url.pathExtension) ?? .data)
        item.size = Int(clamping: metadata.st_size)
        item.hidden = item.hidden || (metadata.st_flags & UInt32(bitPattern: UF_HIDDEN)) != 0

        let rawMode = metadata.st_mode & mode_t(0o7777)
        item.posixPerms = String(format: "%04o", UInt32(rawMode))
        item.owner = POSIXIdentityResolver.userName(metadata.st_uid)
        item.group = POSIXIdentityResolver.groupName(metadata.st_gid)

        let created = Date(
            timeIntervalSince1970: TimeInterval(metadata.st_birthtimespec.tv_sec)
                + TimeInterval(metadata.st_birthtimespec.tv_nsec) / 1_000_000_000
        )
        let modified = Date(
            timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec)
                + TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        item.creationDate = created
        item.modifiedDate = modified
        item.creationDateStr = FileItemDateFormatting.string(from: created)
        item.modifiedDateStr = FileItemDateFormatting.string(from: modified)

        // A symlink's own mode is normally 0777 and does not describe whether
        // its target can actually be accessed. Resolve the target mode once for
        // the three informational flags; keep the displayed POSIX mode from lstat.
        var accessMetadata = metadata
        var canEvaluateTargetAccess = true
        if item.type == .symlink {
            var targetMetadata = stat()
            let targetStatSucceeded = url.path.withCString { path in
                stat(path, &targetMetadata) == 0
            }
            if targetStatSucceeded {
                accessMetadata = targetMetadata
            } else {
                canEvaluateTargetAccess = false
            }
        }
        if canEvaluateTargetAccess {
            let access = POSIXAccessEvaluator.flags(
                mode: accessMetadata.st_mode,
                owner: accessMetadata.st_uid,
                group: accessMetadata.st_gid
            )
            item.readable = access.readable
            item.writable = access.writable
            item.executable = access.executable
        }
    } else if let attrs = try? fm.attributesOfItem(atPath: url.path) {
        // Fallback for file-provider / virtual paths that do not expose lstat.
        if let type = attrs[.type] as? FileAttributeType {
            item.type = type == .typeDirectory ? .folder : type == .typeSymbolicLink ? .symlink : .file
        }
        item.uttype = item.type == .folder
            ? .folder
            : (UTType(filenameExtension: url.pathExtension) ?? .data)
        if let size = attrs[.size] as? NSNumber {
            item.size = max(0, size.intValue)
        }
        if let created = attrs[.creationDate] as? Date {
            item.creationDate = created
            item.creationDateStr = FileItemDateFormatting.string(from: created)
        }
        if let modified = attrs[.modificationDate] as? Date {
            item.modifiedDate = modified
            item.modifiedDateStr = FileItemDateFormatting.string(from: modified)
        }
        if let perms = attrs[.posixPermissions] as? NSNumber {
            let mode = UInt32(truncatingIfNeeded: perms.intValue) & 0o7777
            item.posixPerms = String(format: "%04o", mode)
            // This is a fallback for virtual/provider URLs where lstat failed;
            // ask FileManager for the effective access result only in this rare path.
            item.readable = fm.isReadableFile(atPath: url.path)
            item.writable = fm.isWritableFile(atPath: url.path)
            item.executable = fm.isExecutableFile(atPath: url.path)
        }
        if let ownerName = attrs[.ownerAccountName] as? String, !ownerName.isEmpty {
            item.owner = ownerName
        } else if let ownerID = attrs[.ownerAccountID] as? NSNumber {
            item.owner = POSIXIdentityResolver.userName(uid_t(truncatingIfNeeded: ownerID.uint64Value))
        }
        if let groupName = attrs[.groupOwnerAccountName] as? String, !groupName.isEmpty {
            item.group = groupName
        } else if let groupID = attrs[.groupOwnerAccountID] as? NSNumber {
            item.group = POSIXIdentityResolver.groupName(gid_t(truncatingIfNeeded: groupID.uint64Value))
        }
        item.hidden = item.hidden || (attrs[.extensionHidden] as? Bool ?? false)
        if item.type == .symlink,
           let rawTarget = try? fm.destinationOfSymbolicLink(atPath: url.path) {
            item.destURL = URL(fileURLWithPath: rawTarget, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
        }
    }

    // The wireless service owns this tree. Keep the identity useful even on
    // paths where the sandbox does not expose lstat/attributes to File Browser.
    let normalizedPath = url.standardizedFileURL.path
    if normalizedPath == "/var/wireless" || normalizedPath.hasPrefix("/var/wireless/")
        || normalizedPath == "/private/var/wireless" || normalizedPath.hasPrefix("/private/var/wireless/") {
        item.owner = "_wireless"
        item.group = "_wireless"
    }

    return item
}


/// Original Erosion File Browser metadata extraction, isolated for the restored
/// Apps/System browser. Keep the mod's lstat-based getFileItem() unchanged for
/// every other screen.
func getAppsSystemFileItem(at url: URL, isContainer: Bool = false) -> FileItem {
    var item = FileItem(
        name: url.lastPathComponent,
        fileURL: url,
        destURL: url,
        type: .file,
        uttype: .data,
        size: 0,
        creationDate: Date(),
        modifiedDate: Date(),
        creationDateStr: "",
        modifiedDateStr: "",
        hidden: false,
        posixPerms: "",
        owner: "",
        group: "",
        readable: false,
        writable: false,
        executable: false
    )

    if isContainer, let folderName = getBIDFromXattr(url) {
        item.name = folderName
    }

    let formatter = DateFormatter()
    formatter.dateFormat = "MM-dd-yyyy h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")

    let keys: Set<URLResourceKey> = [
        .isSymbolicLinkKey,
        .isDirectoryKey,
        .contentTypeKey,
        .fileSizeKey,
        .creationDateKey,
        .contentModificationDateKey,
        .isHiddenKey
    ]
    // Use lstat for the directory entry itself. URLResourceValues may expose
    // the metadata of a symlink's target on some filesystem/provider paths,
    // which incorrectly turns a link into a normal folder/file row.
    var linkMetadata = stat()
    let hasLinkMetadata = url.path.withCString { path in
        lstat(path, &linkMetadata) == 0
    }
    let isSymbolicLink = hasLinkMetadata
        && (linkMetadata.st_mode & mode_t(Darwin.S_IFMT)) == mode_t(Darwin.S_IFLNK)

    if isSymbolicLink {
        item.type = .symlink
        if let target = try? fm.destinationOfSymbolicLink(atPath: url.path) {
            // Relative targets are resolved against the link's parent.
            item.destURL = URL(
                fileURLWithPath: target,
                relativeTo: url.deletingLastPathComponent()
            ).standardizedFileURL
        }
    }

    if let values = try? url.resourceValues(forKeys: keys) {
        if !isSymbolicLink, let directory = values.isDirectory {
            item.type = directory ? .folder : .file
        }
        item.uttype = values.contentType ?? .data
        item.size = values.fileSize ?? 0
        if let date = values.creationDate {
            item.creationDate = date
            item.creationDateStr = formatter.string(from: date)
        }
        if let date = values.contentModificationDate {
            item.modifiedDate = date
            item.modifiedDateStr = formatter.string(from: date)
        }
        item.hidden = values.isHidden ?? false
    }

    if let attributes = try? fm.attributesOfItem(atPath: url.path) {
        if let permissions = attributes[.posixPermissions] as? NSNumber {
            item.posixPerms = String(format: "%04o", permissions.intValue)
        }
        if let owner = attributes[.ownerAccountName] as? String {
            item.owner = owner
        }
        if let group = attributes[.groupOwnerAccountName] as? String {
            item.group = group
        }
    }

    item.readable = fm.isReadableFile(atPath: url.path)
    item.writable = fm.isWritableFile(atPath: url.path)
    item.executable = fm.isExecutableFile(atPath: url.path)
    return item
}

enum FileType: String {
    case file, folder, symlink
    
    var sortOrder: Int {
        switch self {
        case .file: return 0
        case .symlink: return 1
        case .folder: return 2
        }
    }
}

private func getContainerFiles(at url: URL) -> [FileItem] {
    var files: [FileItem] = []
    let paths = fsHandlers.getDirPaths(url.path)
    for path in paths {
        files.append(getFileItem(at: URL(fileURLWithPath: path)))
    }
    return files
}


/// Calculates the aggregate size of a readable directory tree. The calculation
/// runs only when Folder Info is opened, not while populating directory rows.
/// Symlinks and special filesystem entries are not followed or counted.
enum FolderContentSizeReader {
    private static let maximumDepth = 64
    private static let maximumEntries = 200_000
    private static let maximumContainerEntries = 1_000_000

    /// True for concrete directories inside the Apps/System container roots.
    /// These can contain substantially more entries than an ordinary folder.
    static func isManagedContainerPath(_ url: URL) -> Bool {
        func normalized(_ rawPath: String) -> String {
            var value = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            if value.hasPrefix("/private/var/") {
                value.removeFirst("/private".count)
            }
            return value
        }

        let path = normalized(url.path)
        let roots = [
            FSPaths.appContainers,
            "/var/containers/Data/Application",
            FSURL.appPlugins.standardizedFileURL.path,
            "/var/containers/Data/PluginKitPlugin",
            FSURL.internalDaemons.standardizedFileURL.path,
            "/var/containers/Data/InternalDaemon",
            FSURL.appGroup.standardizedFileURL.path,
            "/var/containers/Shared/AppGroup",
            FSURL.sysGroup.standardizedFileURL.path,
            FSURL.systemData.standardizedFileURL.path
        ].map(normalized)

        // Include an exact container root as well as its descendants.
        return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    static func isDirectory(at url: URL) -> Bool {
        var metadata = stat()
        return url.path.withCString { path in
            // fstatat with flags == 0 follows a symbolic link, so Info can
            // determine whether a link's destination is a directory.
            fstatat(AT_FDCWD, path, &metadata, 0) == 0
                && (metadata.st_mode & mode_t(Darwin.S_IFMT)) == mode_t(Darwin.S_IFDIR)
        }
    }

    static func calculate(
        at url: URL,
        maxEntries: Int? = nil,
        followRootSymlink: Bool = false
    ) throws -> Int64 {
        // For a symlink Info request, url is already the explicit Destination
        // Path. Follow a symlink at this root only; directory entries encountered
        // during the walk continue to use AT_SYMLINK_NOFOLLOW / O_NOFOLLOW.
        let noFollowFlag: Int32 = followRootSymlink ? 0 : O_NOFOLLOW
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | noFollowFlag | O_NONBLOCK)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }

        var rootStat = stat()
        guard fstat(fd, &rootStat) == 0 else { throw posixError() }
        let rootKind = rootStat.st_mode & mode_t(Darwin.S_IFMT)
        if rootKind == mode_t(Darwin.S_IFREG) {
            guard rootStat.st_size >= 0 else { throw posixError() }
            return Int64(rootStat.st_size)
        }
        guard rootKind == mode_t(Darwin.S_IFDIR) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        let entryLimit = maxEntries ?? (isManagedContainerPath(url) ? maximumContainerEntries : maximumEntries)
        var visitedEntries = 0
        return try directorySize(
            fileDescriptor: fd,
            depth: 0,
            visitedEntries: &visitedEntries,
            maximumEntries: entryLimit
        )
    }

    private static func directorySize(
        fileDescriptor: Int32,
        depth: Int,
        visitedEntries: inout Int,
        maximumEntries: Int
    ) throws -> Int64 {
        guard depth <= maximumDepth else { throw CocoaError(.fileReadTooLarge) }
        let duplicateFD = dup(fileDescriptor)
        guard duplicateFD >= 0 else { throw posixError() }
        guard let directory = fdopendir(duplicateFD) else {
            close(duplicateFD)
            throw posixError()
        }
        defer { closedir(directory) }

        let directoryFD = dirfd(directory)
        var total: Int64 = 0

        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw posixError() }
                break
            }

            let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }

            visitedEntries += 1
            guard visitedEntries <= maximumEntries else { throw CocoaError(.fileReadTooLarge) }

            var childStat = stat()
            let statResult = name.withCString {
                fstatat(directoryFD, $0, &childStat, AT_SYMLINK_NOFOLLOW)
            }
            guard statResult == 0 else { throw posixError() }

            let kind = childStat.st_mode & mode_t(Darwin.S_IFMT)
            if kind == mode_t(Darwin.S_IFLNK) {
                continue
            } else if kind == mode_t(Darwin.S_IFDIR) {
                let childFD = name.withCString {
                    openat(directoryFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                }
                guard childFD >= 0 else { throw posixError() }
                defer { close(childFD) }

                var openedStat = stat()
                guard fstat(childFD, &openedStat) == 0,
                      (openedStat.st_mode & mode_t(Darwin.S_IFMT)) == mode_t(Darwin.S_IFDIR) else {
                    throw posixError()
                }
                let childSize = try directorySize(
                    fileDescriptor: childFD,
                    depth: depth + 1,
                    visitedEntries: &visitedEntries,
                    maximumEntries: maximumEntries
                )
                let (sum, overflow) = total.addingReportingOverflow(childSize)
                guard !overflow else { throw CocoaError(.fileReadTooLarge) }
                total = sum
            } else if kind == mode_t(Darwin.S_IFREG) {
                // fstatat already returned the file's logical size. Opening every
                // child file is unnecessary and made an otherwise readable
                // container total fail when a single file denied read access.
                guard childStat.st_size >= 0 else { throw posixError() }
                let (sum, overflow) = total.addingReportingOverflow(Int64(childStat.st_size))
                guard !overflow else { throw CocoaError(.fileReadTooLarge) }
                total = sum
            }
            // Other special entries (sockets, devices, FIFOs) contribute no file data.
        }

        return total
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
