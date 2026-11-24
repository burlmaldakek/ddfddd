//
//  DeviceInfoHelpers.swift
//  Erosion
//
//  Created by lunginspector on 8/14/26.
//

import Foundation

import UIKit

// rave is the internal codename for ios 27
func raveSupported() -> Bool {
    let buildNum = buildNumber()
    if buildNum == "24A5355q" || buildNum == "24A5370h" || buildNum == "24A5380h" || buildNum == "24A5390f" || buildNum == "24A5380l" {
        return true
    }
    return false
}

let vrs = ProcessInfo.processInfo.operatingSystemVersion
func isSupported() -> Bool {
    if (vrs.majorVersion == 26 && vrs.minorVersion < 7) || raveSupported() {
        return true
    }
    return false
}

/// User-selectable feature visibility and backend preference.
/// Combined uses InstallationProxy for container lookup and Worse Query for local I/O.
enum ErosionExploitSelection: String, CaseIterable, Identifiable {
    // Keep the persisted value "Both" for compatibility with existing installs;
    // the Settings picker presents it as "Combined".
    case both = "Both"
    case airlift = "Airlift"
    case worseQuery = "worse_query"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .both: return "Combined"
        case .airlift: return "Airlift"
        case .worseQuery: return "worse_query"
        }
    }
}

/// iOS 26 uses the help toolbar instead of the Pair action in Airlift.
func isIOS26() -> Bool {
    vrs.majorVersion == 26
}

/// True starting with the iOS 27.2 version line, independent of the later
/// beta-3 cutoff used specifically for Airlift visibility.
func isIOS272OrLater() -> Bool {
    if vrs.majorVersion > 27 { return true }
    if vrs.majorVersion < 27 { return false }
    return vrs.minorVersion >= 2
}

/// Airlift is no longer exposed on iOS 27.2 beta 3 (24B5099f) and later.
/// The build check is needed for 27.2 because earlier 27.2 prerelease builds
/// must retain the existing Airlift UI.
func isIOS272Beta3OrLater() -> Bool {
    if vrs.majorVersion > 27 { return true }
    if vrs.majorVersion < 27 { return false }
    if vrs.minorVersion > 2 { return true }
    if vrs.minorVersion < 2 { return false }
    if vrs.patchVersion > 0 { return true }

    let build = buildNumber()
    guard build != "Unknown" else { return false }
    return build.compare("24B5099f", options: [.numeric, .caseInsensitive]) != .orderedAscending
}

/// Hard compatibility gate introduced at iOS 27.3 beta 2 (builds newer than
/// 24C5049f). The build comparison also covers later major iOS releases.
func isIOS273Beta2OrLater() -> Bool {
    let build = buildNumber()
    guard build != "Unknown" else { return false }
    return build.compare("24C5049f", options: [.numeric, .caseInsensitive]) == .orderedDescending
}

/// Resolve the selected mode while respecting OS builds where Airlift has been
/// retired from the UI. Older saved preferences remain intact for compatibility.
func effectiveExploitSelection(for rawValue: String? = nil) -> ErosionExploitSelection {
    if isIOS272Beta3OrLater() {
        return .worseQuery
    }
    let storedValue = rawValue
        ?? UserDefaults.standard.string(forKey: "erosion.exploitSelection")
        ?? ErosionExploitSelection.both.rawValue
    return ErosionExploitSelection(rawValue: storedValue) ?? .both
}

func selectedExploitSelection() -> ErosionExploitSelection {
    effectiveExploitSelection()
}

/// Resolve the backend for the features that support both implementations.
/// The Airlift implementation itself remains unchanged; this only selects it.
func usesAirliftForSelectedExploit() -> Bool {
    switch selectedExploitSelection() {
    case .both, .worseQuery:
        // Combined keeps the existing InstallationProxy path lookup, but all
        // local reads/writes for these features are performed through WQ.
        return false
    case .airlift:
        return true
    }
}


/// Platform/build compatibility flag retained for existing unrelated UI gates.
/// It does not override the user's explicit exploit selection for Dialer/Wallpapers.
func isAirliftCompatibilityMode() -> Bool {
    return vrs.majorVersion == 27 && !raveSupported()
}

func wallpaperUsesBedQuery() -> Bool {
    return !usesAirliftForSelectedExploit()
}

/// iOS 27 DB5+ gate used for Airlift-only UI features.
/// DB5 is the last of the known supported 27.x builds; newer builds are
/// represented by Airlift compatibility mode. Keeping this helper separate
/// makes the UI gate explicit instead of coupling it to a wallpaper tweak.
func isIOS27DB1ThroughDB4() -> Bool {
    guard vrs.majorVersion == 27 else { return false }
    let db1ThroughDB4 = ["24A5355q", "24A5370h", "24A5380h", "24A5390f"]
    return db1ThroughDB4.contains(buildNumber())
}

func isIOS27DB5OrLater() -> Bool {
    guard vrs.majorVersion == 27 else { return false }
    // 24A5380l is the fifth known iOS 27 developer-build marker used by
    // Erosion. Any build outside the known pre-DB5 set is treated as DB5+.
    let build = buildNumber()
    let preDB5 = ["24A5355q", "24A5370h", "24A5380h", "24A5390f"]
    return build == "24A5380l" || !preDB5.contains(build)
}

func airliftUIAccessRequired() -> Bool {
    return isIOS27DB5OrLater() && isAirliftCompatibilityMode()
}


func doubleSysVrs() -> Double {
    let pieces = [String(vrs.majorVersion), String(vrs.minorVersion)]
    let combined = pieces.joined(separator: ".")
    return Double(combined) ?? 0.0
}



// device info getters
func machineName() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    let machineMirror = Mirror(reflecting: systemInfo.machine)
    return machineMirror.children.reduce("") { identifier, element in
        guard let value = element.value as? Int8, value != 0 else { return identifier }
        return identifier + String(UnicodeScalar(UInt8(value)))
    }
}

func buildNumber() -> String {
    var versString = [CChar](repeating: 0, count: 16)
    var versStringLen = size_t(versString.count - 1)
    let res = sysctlbyname("kern.osversion", &versString, &versStringLen, nil, 0)
    if res == 0, let buildNum = String(validatingUTF8: versString) {
        return buildNum
    }
    return "Unknown"
}

func isPad() -> Bool {
    return UIDevice.current.userInterfaceIdiom == .pad
}
