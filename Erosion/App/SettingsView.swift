//
//  SettingsView.swift
//  Erosion
//
//  Created by lunginspector on 8/20/26.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @AppStorage("autoRespring") private var autoRespring = false
    @AppStorage("erosion.displayUnstablePaths") private var displayUnstablePaths = true
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Auto-Respring", isOn: $autoRespring)
                    if !isIOS272OrLater() {
                        Toggle("Display Unstable Paths", isOn: $displayUnstablePaths)
                    }
                } header: {
                    HeaderLabel("App Settings", symbol: "gearshape")
                } footer: {
                    Text("Automatically resprings your device after applying a tweak.")
                }

                Section {
                    Link(destination: URL(string: "https://t.me/usrlibexec")!) {
                        AppInfoCell(build: "Release", appName: "Erosion mod", appVersion: "3.1")
                    }
                    .tint(.white)
                } header: {
                    HeaderLabel("About", symbol: "info.circle")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Made with love by the [jailbreak.party](https://jailbreak.party) team.\nNeed support or want to know about new releases? Join the [jailbreak.party Discord server!](https://jailbreak.party/discord)")
                    }
                }
                
                Section {
                    LinkCreditCell(image: Image("lunginspector"), name: "lunginspector", description: "Primary developer and maintainer.", url: "https://github.com/lunginspector")
                    LinkCreditCell(image: Image("forcequit"), name: "forcequit", description: "Developed and published worse_query sandbox escape.", url: "https://github.com/forcequitOS")
                    LinkCreditCell(image: Image("skadz108"), name: "Skadz", description: "Minor UI adjustments, respring implementation, and various backend functions.", url: "https://github.com/skadz108")
                    LinkCreditCell(image: Image("rooootdev"), name: "rooootdev", description: "Various backend components.", url: "https://github.com/rooootdev")
                    LinkCreditCell(image: Image("neonmodder123"), name: "neonmodder123", description: "Developed WebView respring method.", url: "https://github.com/neonmodder123")
                } header: {
                    HeaderLabel("Credits", symbol: "star")
                }

                Section {
                    Button(role: .destructive) {
                        Alertinator.shared.alert(
                            title: "Clear Erosion cache?",
                            body: "This removes Erosion's cached themes, prepared apps, snapshots, cached artwork, and temporary files.",
                            actionLabel: "Confirm",
                            actionStyle: .destructive,
                            action: {
                                if ErosionCacheCleaner.hasActiveOperation {
                                    Alertinator.shared.alert(
                                        title: "Cannot clear cache yet",
                                        body: "An Airlift read, write, pairing, exploit, passcode apply, or Wallet artwork operation is still running. Wait for it to finish, then try again."
                                    )
                                    return
                                }
                                let result = ErosionCacheCleaner.clear()
                                Alertinator.shared.alert(title: result.title, body: result.message)
                            }
                        )
                    } label: {
                        Text("Clear Cache")
                    }
                    .tint(.red)

                    Button(role: .destructive) {
                        Alertinator.shared.alert(
                            title: "Clear Workspace?",
                            body: "This removes all contents of Workspace.",
                            actionLabel: "Confirm",
                            actionStyle: .destructive,
                            action: {
                                Task { @MainActor in
                                    let result = await Task.detached(priority: .utility) {
                                        ErosionWorkspaceCleaner.clear()
                                    }.value
                                    if result.failures.isEmpty {
                                        Alertinator.shared.alert(
                                            title: "Workspace cleared",
                                            body: "Removed \(result.removed) items from Workspace"
                                        )
                                    } else {
                                        let details = result.failures.joined(separator: "\n")
                                        Alertinator.shared.alert(
                                            title: "Workspace partially cleared",
                                            body: "Removed \(result.removed) items from Workspace.\n\n\(details)"
                                        )
                                    }
                                }
                            }
                        )
                    } label: {
                        Text("Clear Workspace")
                    }
                    .tint(.red)
                } header: {
                    HeaderLabel("Data", symbol: "loupe")
                }
            }
            .navigationTitle("Settings")
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
    }




}


/// Removes only Erosion-owned persistent libraries and cache directories.
/// The Documents root is never removed, so the Airlift pairing file and other
/// unrelated files in Documents remain untouched.
private enum ErosionCacheCleaner {
    static var hasActiveOperation: Bool {
        let airlift = AirliftBridge.shared
        switch airlift.state {
        case .pairing, .running:
            return true
        default:
            break
        }
        return airlift.readRunning
            || airlift.passcodeFlashRunning
            || (WalletCardSkinManager.shared?.flashRunning ?? false)
            || (WalletCardSkinManager.shared?.isReadingArtworks ?? false)
    }

    static func clear() -> (title: String, message: String) {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL.documentsDirectory

        let targets: [URL] = [
            AppURL.pb,
            AppURL.ps,
            support.appendingPathComponent("ErosionPasscodeLibrary", isDirectory: true),
            support.appendingPathComponent("ErosionAppsManagement", isDirectory: true),
            support.appendingPathComponent("ErosionFileOperationsSnapshots", isDirectory: true),
            caches.appendingPathComponent("ErosionThemingPreviews", isDirectory: true)
        ]

        var removed = 0
        var failures: [String] = []
        for target in targets {
            guard fileManager.fileExists(atPath: target.path) else { continue }
            do {
                try fileManager.removeItem(at: target)
                removed += 1
            } catch {
                failures.append("\(target.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // Clear the app's tmp contents, not the tmp directory itself. Keep the
        // silent audio resource while KeepAlive is actively using it.
        do {
            let temporaryItems = try fileManager.contentsOfDirectory(
                at: fileManager.temporaryDirectory,
                includingPropertiesForKeys: nil,
                options: []
            )
            for item in temporaryItems {
                if item.lastPathComponent == "keepalive.wav" && KeepAlive.shared.audioActive {
                    continue
                }
                do {
                    try fileManager.removeItem(at: item)
                    removed += 1
                } catch {
                    failures.append("\(item.lastPathComponent): \(error.localizedDescription)")
                }
            }
        } catch {
            failures.append("tmp: \(error.localizedDescription)")
        }

        // Remove only Erosion theme archives from Documents; never remove the
        // Documents root or the active Airlift pairing file.
        if let documentItems = try? fileManager.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for item in documentItems where item.pathExtension.lowercased() == "passthm" {
                do {
                    try fileManager.removeItem(at: item)
                    removed += 1
                } catch {
                    failures.append("\(item.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        let defaults = UserDefaults.standard
        let keys = [
            "tendiesArray",
            "erosion.passcodeLibrary.selectedFilename",
        ]
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        if failures.isEmpty {
            return (
                "Cache cleared",
                "Removed \(removed) Erosion data item(s). Restart Erosion to refresh data that was already loaded in memory."
            )
        }
        return (
            "Cache partially cleared",
            "Removed \(removed) item(s). Could not remove: \(failures.joined(separator: "; "))."
        )
    }
}

/// Clears only the contents of Erosion's Workspace folder. The Workspace
/// directory itself and all other Application Support data are preserved.
private enum ErosionWorkspaceCleaner {
    private static var workspaceURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL.documentsDirectory.appendingPathComponent("Application Support", isDirectory: true)
        return support.appendingPathComponent("Workspace", isDirectory: true)
    }

    static func clear() -> (removed: Int, failures: [String]) {
        let fileManager = FileManager.default
        let workspace = workspaceURL
        do {
            try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
            let children = try fileManager.contentsOfDirectory(
                at: workspace,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )

            var removed = 0
            var failures: [String] = []
            for child in children {
                let itemCount = countItems(at: child, fileManager: fileManager)
                do {
                    try fileManager.removeItem(at: child)
                    removed += itemCount
                } catch {
                    failures.append("\(child.lastPathComponent): \(error.localizedDescription)")
                }
            }
            return (removed, failures)
        } catch {
            return (0, [error.localizedDescription])
        }
    }

    /// Counts the top-level item plus all descendants. Symbolic links count as
    /// one item and are never traversed.
    private static func countItems(at url: URL, fileManager: FileManager) -> Int {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return 1
        }
        guard values.isDirectory == true, values.isSymbolicLink != true,
              let children = try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
              ) else {
            return 1
        }
        return 1 + children.reduce(0) { $0 + countItems(at: $1, fileManager: fileManager) }
    }
}
