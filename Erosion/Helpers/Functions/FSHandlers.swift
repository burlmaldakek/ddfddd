//
//  FSHandlers.swift
//  Erosion
//
//  Created by lunginspector on 8/19/26.
//

import Foundation
import UIKit
import Darwin

let fsHandlers = FSHandlers()

class FSHandlers {
    /// Original Erosion's Worse Query path-leak enumerator, retained separately
    /// from the BadQuery-backed getDirPaths() used by other parts of the mod.
    /// Apps/System's restored File Browser calls this method exclusively.
    func getWorseQueryDirPaths(_ path: String, maxInode: Int64? = 7_500_000) -> [String] {
        var pathLimit: UInt64 = UInt64(max(1, maxInode ?? 7_500_000))

        if maxInode == nil {
            do {
                let baselineURL = fm.temporaryDirectory.appendingPathComponent(".baseline_\(UUID().uuidString)")
                try "thxforcequit".write(to: baselineURL, atomically: true, encoding: .utf8)
                var baselineInfo = stat()
                guard stat(baselineURL.path, &baselineInfo) == 0 else {
                    try? fm.removeItem(at: baselineURL)
                    print("(fs) Failed to get baseline inode!")
                    return []
                }
                pathLimit = baselineInfo.st_ino
                try fm.removeItem(at: baselineURL)
            } catch {
                print("(fs) Failed to get baseline inode: \(error)")
                return []
            }
        }

        if isIOS27DB1ThroughDB4() {
            // Use the original bad_query_list enumerator on DB1-DB4, matching
            // the legacy source. pathleak remains the DB5+/other-OS backend.
            return getDirPaths(path, maxInode: Int64(pathLimit))
        }

        print("(fs) pathleaking \(path), max \(pathLimit)")
        let leakedPaths = pathleak(path, pathLimit) ?? []
        print("(fs) got \(leakedPaths.count) paths via pathleak")
        if leakedPaths.isEmpty {
            print("(fs) got no paths! something went wrong.")
        }
        return leakedPaths
    }

    func getDirPaths(_ path: String, maxInode: Int64 = 10000000) -> [String] {
        var array = [""]
        path.withCString { path in
            guard let res = bad_query_list(UnsafeMutablePointer(mutating: path), maxInode) else {
                return
            }
            defer { free(res) }
            
            let string = String(cString: res)
            array = string.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
        return array
    }
    
    func getContainerPath(at containerURL: URL = FSURL.appContainers, forMatch match: String, hashOnly: Bool = false) -> String {
        let containers = getDirPaths(containerURL.path)
        for path in containers {
            let url = URL(fileURLWithPath: path)
            if let appName = folderLabel(url: url) {
                if appName == match {
                    if hashOnly {
                        return url.lastPathComponent
                    }
                    return url.path
                }
            }
        }
        print("(fs) failed to get container for \(match)! containers: \(containerURL.path)")
        return ""
    }
    
    /// Original Erosion Worse Query path-discovery flow, isolated from the
    /// BadQuery-backed helpers used elsewhere in the modified file browser.
    func getContainerPathWithWorseQuery(
        at containerURL: URL = FSURL.appContainers,
        forMatch match: String,
        hashOnly: Bool = false
    ) -> String {
        if isIOS27DB1ThroughDB4() {
            return getContainerPath(at: containerURL, forMatch: match, hashOnly: hashOnly)
        }

        let baselineURL = fm.temporaryDirectory.appendingPathComponent(".baseline_\(UUID().uuidString)")
        var baselineInfo = stat()

        do {
            try "thxforcequit".write(to: baselineURL, atomically: true, encoding: .utf8)
            guard stat(baselineURL.path, &baselineInfo) == 0 else {
                try? fm.removeItem(at: baselineURL)
                print("(fs) failed to get baseline inode for Worse Query path discovery")
                return ""
            }
            try fm.removeItem(at: baselineURL)
        } catch {
            try? fm.removeItem(at: baselineURL)
            print("(fs) failed to create Worse Query path baseline: \(error.localizedDescription)")
            return ""
        }

        let containers = pathleak(containerURL.path, baselineInfo.st_ino) ?? []
        for path in containers {
            let url = URL(fileURLWithPath: path)
            guard worseQueryContainerIdentifier(url) == match else { continue }
            return hashOnly ? url.lastPathComponent : url.path
        }

        print("(fs) failed to get container for \(match) via Worse Query; root: \(containerURL.path)")
        return ""
    }

    private func worseQueryContainerIdentifier(_ url: URL) -> String? {
        let access = wq.grantAccess(path: url.path)
        guard access.0, access.1 >= 0 else { return nil }
        defer { releaseSandboxAccess(access.1) }

        var buffer = [CChar](repeating: 0, count: 512)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            getxattr(
                url.path,
                "com.apple.containermanager.identifier",
                pointer.baseAddress,
                511,
                0,
                0
            )
        }
        guard length > 0 else { return nil }
        let identifier = String(cString: buffer)
        return identifier.isEmpty ? nil : identifier
    }

    func openInFilesApp(_ fileURL: URL) {
        guard var components = URLComponents(url: fileURL, resolvingAgainstBaseURL: false) else { return }
        components.scheme = "shareddocuments"
        guard let filesAppURL = components.url else { return }
        UIApplication.shared.open(filesAppURL)
    }
}
