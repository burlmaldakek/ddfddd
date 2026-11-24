import Foundation
import Darwin

/// Read-only filesystem capability used by Erosion's virtual system directories.
/// It deliberately does not request or grant sandbox extensions and never performs writes.
enum SystemReadOnlyAccess {
    static let roots: Set<String> = [
        "/System/Library",
        "/System/Developer",
        "/System/Cryptexes",
        "/System/Volumes",
        "/private/var/staged_system_apps",
        "/usr/lib",
        "/usr/share",
        "/usr/libexec",
        "/Library/Ringtones",
        "/Library/RegionFeatures",
        "/usr/local",
        "/bin",
        "/sbin",
        "/sbin/launchd",
        "/var/mobile/Library",
        "/var/mobile/Media",
        "/private/system_data",
        "/private/xarts",
        "/var/db",
        "/var/empty",
        "/var/log",
        "/var/vm",
        "/var/keybags",
        // Cryptex entries can resolve through the Preboot Cryptex store.
        "/private/preboot/Cryptexes",
        "/System/Volumes/Preboot/Cryptexes",
        "/cores",
        "/tmp",
        "/var/tmp/com.apple.heard",
        "/Applications/FindMy.app",
        "/System/DriverKit",
        "/dev",
        "/etc"
    ]

    static func isSystemPath(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    static func canReadDirectory(_ url: URL) -> Bool {
        if CoreMediaVirtualSystemPathReader.containsVirtualPath(url) {
            return CoreMediaVirtualSystemPathReader.canReadDirectory(at: url)
        }
        guard isSystemPath(url) else { return false }
        guard access(url.path, R_OK | X_OK) == 0 else { return false }
        // An empty directory is still a valid, readable directory.
        // Keep it visible and let FileBrowserView render an empty list.
        guard (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil else { return false }
        return true
    }

    static func isDirectory(_ url: URL) -> Bool {
        if CoreMediaVirtualSystemPathReader.containsVirtualPath(url) {
            return CoreMediaVirtualSystemPathReader.isDirectory(at: url)
        }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    static func canReadPath(_ url: URL) -> Bool {
        if CoreMediaVirtualSystemPathReader.containsVirtualPath(url) {
            return CoreMediaVirtualSystemPathReader.isDirectory(at: url) || CoreMediaVirtualSystemPathReader.canReadFile(at: url)
        }
        if isDirectory(url) {
            return canReadDirectory(url)
        }
        return access(url.path, R_OK) == 0 && FileManager.default.fileExists(atPath: url.path)
    }

    static func canReadFile(_ url: URL) -> Bool {
        if CoreMediaVirtualSystemPathReader.containsVirtualPath(url) {
            return CoreMediaVirtualSystemPathReader.canReadFile(at: url)
        }
        let path = url.standardizedFileURL.path
        guard access(path, R_OK) == 0 else { return false }
        guard FileManager.default.fileExists(atPath: path) else { return false }
        return !isDirectory(url)
    }

    /// The system volume is treated as read-only by Erosion even if a future
    /// environment reports a writable POSIX bit. This is an application-level
    /// safety boundary for this viewer.
    static func isReadOnly(_ url: URL) -> Bool {
        return CoreMediaVirtualSystemPathReader.containsVirtualPath(url) || isSystemPath(url)
    }
}
