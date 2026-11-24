//
//  WriteHelpers.swift
//  Erosion
//
//  In-place MobileGestalt writing is intentionally kept separate from
//  temporary-file replacement. Replacing the file creates a new inode and
//  can cause iOS to regenerate MobileGestalt after reboot.
//

import Foundation
import Darwin

func writeFileTemp(_ data: Data, to url: URL) -> (Bool, String) {
    do {
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")

        try data.write(to: tempURL, options: [.withoutOverwriting])
        defer { try? fm.removeItem(at: tempURL) }

        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try fm.moveItem(at: tempURL, to: url)
        }

        return (true, "succeeded")
    } catch {
        print("(fm) failed to write file: \(error.localizedDescription)")
        return (false, error.localizedDescription)
    }
}

// Same persistence mechanism used by Mond:
// open the existing file and rewrite its contents through the existing fd.
// This preserves the inode instead of replacing the file.
func writeFileAtomically(_ data: Data, to url: URL) -> (Bool, String) {
    guard let original = try? Data(contentsOf: url) else {
        return (false, "failed to get original file data!")
    }

    let fd = url.path.withCString {
        open($0, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    }

    guard fd >= 0 else {
        return (false, "failed to open file: \(String(cString: strerror(errno)))")
    }

    defer { close(fd) }

    do {
        guard ftruncate(fd, 0) == 0 else {
            throw WriteError.truncate(errno)
        }

        try writeAll(fd, data)

        guard fsync(fd) == 0 else {
            throw WriteError.sync(errno)
        }

        guard lseek(fd, 0, SEEK_SET) >= 0 else {
            throw WriteError.verification
        }

        let verify = try readAll(fd)
        guard verify == data else {
            throw WriteError.verification
        }
    } catch {
        // Restore the original contents without replacing the inode.
        if ftruncate(fd, 0) == 0,
           lseek(fd, 0, SEEK_SET) >= 0 {
            _ = try? writeAll(fd, original)
            _ = fsync(fd)
        }
        return (false, error.localizedDescription)
    }

    return (true, "succeeded")
}

private enum WriteError: Error {
    case truncate(Int32)
    case write(Int32)
    case sync(Int32)
    case verification

    var localizedDescription: String {
        switch self {
        case .truncate(let e): return "truncate failed: \(String(cString: strerror(e)))"
        case .write(let e): return "write failed: \(String(cString: strerror(e)))"
        case .sync(let e): return "fsync failed: \(String(cString: strerror(e)))"
        case .verification: return "verification failed"
        }
    }
}

private func readAll(_ fd: Int32) throws -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)

    while true {
        let count = buffer.withUnsafeMutableBytes { rawBuffer in
            read(fd, rawBuffer.baseAddress, rawBuffer.count)
        }

        if count > 0 {
            result.append(buffer, count: count)
        } else if count == 0 {
            return result
        } else if errno == EINTR {
            continue
        } else {
            throw WriteError.verification
        }
    }
}

private func writeAll(_ fd: Int32, _ data: Data) throws {
    guard !data.isEmpty else { return }

    try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else {
            throw WriteError.write(EFAULT)
        }

        var offset = 0
        while offset < data.count {
            let result = write(fd, base.advanced(by: offset), data.count - offset)

            if result > 0 {
                offset += result
            } else if result < 0 && errno == EINTR {
                continue
            } else {
                throw WriteError.write(errno)
            }
        }
    }
}
