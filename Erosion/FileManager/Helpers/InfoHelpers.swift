//
//  FilosHelpers.swift
//  Filos
//
//  Created by lunginspector on 7/22/26.
//

import SwiftUI

enum FolderType {
    case normal, bundle, container
}

func getFolderType(url: URL) -> FolderType {
    let parent = url.deletingLastPathComponent().path
    
    let path = url.standardizedFileURL.path
    let bundleRoot = FSPaths.appBundles + "/"
    let relativeBundlePath = path.hasPrefix(bundleRoot) ? String(path.dropFirst(bundleRoot.count)) : ""
    let bundleComponents = relativeBundlePath.split(separator: "/", omittingEmptySubsequences: false)
    if bundleComponents.count == 2,
       UUID(uuidString: String(bundleComponents[0])) != nil,
       String(bundleComponents[1]).lowercased().hasSuffix(".app") {
        return .bundle
    } else if parent == FSPaths.appBundles {
        return .bundle
    } else if parent == FSPaths.appContainers {
        return .container
    }
    return .normal
}

// Match original Erosion: obtain the container label from its MCM xattr
// after requesting access through Worse Query.
func getBIDFromXattr(_ url: URL) -> String? {
    let access = wq.grantAccess(path: url.path)
    guard access.0, access.1 >= 0 else { return nil }
    defer { releaseSandboxAccess(access.1) }

    var buffer = [UInt8](repeating: 0, count: 512)
    let length = buffer.withUnsafeMutableBytes {
        getxattr(url.path, "com.apple.containermanager.identifier", $0.baseAddress, 511, 0, XATTR_NOFOLLOW)
    }
    if length < 0 {
        print("failed to read xattr: \(String(cString: strerror(errno))) (errno \(errno))")
        return nil
    }

    let identifier = String(cString: buffer)
    return identifier.isEmpty ? nil : identifier
}

func folderLabel(url: URL) -> String? {
    getBIDFromXattr(url)
}

func metadataID(from data: Data) -> String? {
    let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
    return plist?["MCMMetadataIdentifier"] as? String
}

func readMetaKey(at url: URL, key: String) -> String? {
    let access = WorseQuery.grantAccess(path: url.path, groupIdentifier: group)
    guard access.0, access.1 >= 0 else {
        return nil
    }
    // Keep the extension active until after Data(contentsOf:) completes.
    defer { releaseSandboxAccess(access.1) }

    guard let data = try? Data(contentsOf: url),
          let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
        return nil
    }

    return plist[key] as? String
}


/// Diagnostic result for resolving the MCM identifier stored in a container's metadata plist.
/// It mirrors folderLabel's direct-read pass followed by its BadQuery-assisted fallback,
/// but records why each candidate did or did not yield an identifier.
struct FolderLabelDiagnostic {
    let identifier: String?
    let detail: String
}

func diagnoseFolderLabel(url containerURL: URL) -> FolderLabelDiagnostic {
    let candidates = [
        containerURL.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist"),
        containerURL.appendingPathComponent("com.apple.mobile_container_manager.metadata.plist")
    ]
    var attempts: [String] = []

    func parseIdentifier(_ data: Data) -> (identifier: String?, detail: String) {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            return (nil, "plist parse failed: \(error.localizedDescription)")
        }
        guard let dictionary = object as? [String: Any] else {
            return (nil, "plist root is not a dictionary")
        }
        guard let identifier = dictionary["MCMMetadataIdentifier"] as? String,
              !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (nil, "MCMMetadataIdentifier missing, empty, or not a string")
        }
        return (identifier, "MCMMetadataIdentifier found")
    }

    // Keep the same two-pass order as folderLabel: try normal reads for both names first.
    for candidate in candidates {
        do {
            let data = try Data(contentsOf: candidate)
            let parsed = parseIdentifier(data)
            if let identifier = parsed.identifier {
                return FolderLabelDiagnostic(
                    identifier: identifier,
                    detail: "\(candidate.lastPathComponent): direct read succeeded; \(parsed.detail)"
                )
            }
            attempts.append("\(candidate.lastPathComponent): direct read succeeded; \(parsed.detail)")
        } catch {
            attempts.append("\(candidate.lastPathComponent): direct read failed (\(error.localizedDescription))")
        }
    }

    // This is the same fallback used by readMetaKey: ask BadQuery for the file path,
    // then read and parse the plist. This diagnostic does not write to the device.
    for candidate in candidates {
        var pathCString = candidate.path.utf8CString.map { Int8($0) }
        let handle = bad_query(&pathCString, true, nil, false, nil)
        guard handle >= 0 else {
            attempts.append("\(candidate.lastPathComponent): BadQuery-assisted open failed (handle=\(handle))")
            continue
        }

        let data: Data
        do {
            data = try Data(contentsOf: candidate)
        } catch {
            bad_query_release(handle)
            attempts.append("\(candidate.lastPathComponent): BadQuery-assisted read failed (\(error.localizedDescription))")
            continue
        }

        let parsed = parseIdentifier(data)
        bad_query_release(handle)
        if let identifier = parsed.identifier {
            return FolderLabelDiagnostic(
                identifier: identifier,
                detail: "\(candidate.lastPathComponent): BadQuery-assisted read succeeded; \(parsed.detail)"
            )
        }
        attempts.append("\(candidate.lastPathComponent): BadQuery-assisted read succeeded; \(parsed.detail)")
    }

    return FolderLabelDiagnostic(identifier: nil, detail: attempts.joined(separator: " | "))
}

enum SysBID {
    static var phone = "com.apple.mobilephone"
    static var poster = "com.apple.PosterBoard"
}
