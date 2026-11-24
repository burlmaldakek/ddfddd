//
//  FMRootView.swift
//  Erosion
//
//  Created by lunginspector on 8/26/26.
//

import SwiftUI

enum FSPaths {
    static let appContainers = "/var/mobile/Containers/Data/Application"
    static var appBundles = "/var/containers/Bundle/Application"
}

enum FSURL {
    static let appContainers = URL(fileURLWithPath: FSPaths.appContainers)
    static let appBundles = URL(fileURLWithPath: FSPaths.appBundles, isDirectory: true)
    static var sysGroup = URL(fileURLWithPath: "/var/containers/Shared/SystemGroup")
    static var configProfiles = FSURL.sysGroup.appendingPathComponent("systemgroup.com.apple.configurationprofiles/Library/ConfigurationProfiles")
    static var internalDaemons = URL(fileURLWithPath: "/var/mobile/Containers/Data/InternalDaemon")
    static var appPlugins = URL(fileURLWithPath: "/var/mobile/Containers/Data/PluginKitPlugin")
    static var appGroup = URL(fileURLWithPath: "/var/mobile/Containers/Shared/AppGroup")
    static var systemData = URL(fileURLWithPath: "/var/containers/Data/System")
    static let stagedSystemApps = URL(fileURLWithPath: "/private/var/staged_system_apps")
    static let systemLibrary = URL(fileURLWithPath: "/System/Library")
    static let systemDeveloper = URL(fileURLWithPath: "/System/Developer")
    static let systemCryptexes = URL(fileURLWithPath: "/System/Cryptexes")
    static let usrLib = URL(fileURLWithPath: "/usr/lib")
    static let usrShare = URL(fileURLWithPath: "/usr/share")
    static let usrLibexec = URL(fileURLWithPath: "/usr/libexec", isDirectory: true)
    static let libraryRingtones = URL(fileURLWithPath: "/Library/Ringtones", isDirectory: true)
    static let libraryRegionFeatures = URL(fileURLWithPath: "/Library/RegionFeatures", isDirectory: true)
    static let bin = URL(fileURLWithPath: "/bin")
    static let sbin = URL(fileURLWithPath: "/sbin")
    static let mobileLibrary = URL(fileURLWithPath: "/var/mobile/Library")
    static let mobileMedia = URL(fileURLWithPath: "/var/mobile/Media")
    static let etc = URL(fileURLWithPath: "/etc")
    static let cores = URL(fileURLWithPath: "/cores")
    static let tmp = URL(fileURLWithPath: "/tmp")
    static let varTmpHeard = URL(fileURLWithPath: "/var/tmp/com.apple.heard")
    static let findMy = URL(fileURLWithPath: "/Applications/FindMy.app")
    static let systemDriverKit = URL(fileURLWithPath: "/System/DriverKit")
    static let dev = URL(fileURLWithPath: "/dev")
}

struct FMRootView: View {
    @EnvironmentObject var mgr: ErosionManager
    @AppStorage("erosion.exploitSelection") private var exploitSelection = ErosionExploitSelection.both.rawValue
    @AppStorage("erosion.displayUnstablePaths") private var displayUnstablePaths = true

    var body: some View {
        let selection = effectiveExploitSelection(for: exploitSelection)
        NavigationStack {
            List {
                if selection != .airlift {
                    Section {
                        NavigationLink("Data Containers", destination: AppsSystemFileBrowserView(path: FSURL.appContainers, isContainer: true))
                        NavigationLink("Plugin Containers", destination: AppsSystemFileBrowserView(path: FSURL.appPlugins, isContainer: true))
                        NavigationLink("App Groups", destination: AppsSystemFileBrowserView(path: FSURL.appGroup, shouldGrant: true))
                    } header: {
                        HeaderLabel("Apps", symbol: "square.grid.2x2")
                    }

                    Section {
                        NavigationLink("Daemon Containers", destination: AppsSystemFileBrowserView(path: FSURL.internalDaemons, isContainer: true))
                        NavigationLink("System Containers", destination: AppsSystemFileBrowserView(path: FSURL.systemData, shouldGrant: true))
                        NavigationLink("SystemGroup Containers", destination: AppsSystemFileBrowserView(path: FSURL.sysGroup, isContainer: true))
                    } header: {
                        HeaderLabel("System", symbol: "gear")
                    }
                }

                if !isIOS272OrLater() && displayUnstablePaths {
                    Section {
                        NavigationLink("Daemon", destination: FileBrowserView(path: FSURL.usrLibexec, readOnly: true, navigationTitleOverride: "libexec"))
                        NavigationLink("Ringtones", destination: FileBrowserView(path: FSURL.libraryRingtones, readOnly: true, navigationTitleOverride: "Ringtones"))
                        NavigationLink("Regional Features", destination: FileBrowserView(path: FSURL.libraryRegionFeatures, readOnly: true, navigationTitleOverride: "RegionFeatures"))
                    } header: {
                        HeaderLabel("CVE-2026-112706", symbol: "folder.badge.gearshape")
                            .foregroundStyle(Color(uiColor: .secondaryLabel))
                    }
                }

                Section {
                    if !isIOS272Beta3OrLater() {
                        NavigationLink("Airlift", destination: AirliftView())
                    }
                    NavigationLink("Workspace", destination: WorkspaceBrowserView())
                } header: {
                    HeaderLabel("Other Stuff", symbol: "ellipsis")
                }
            }
            .navigationTitle("File Browser")
        }

    }
}

/// A virtual work folder backed by persistent app storage. The backing location is
/// intentionally not exposed as a filesystem path in the File Browser UI.
private struct WorkspaceBrowserView: View {
    private let workspaceURL: URL

    init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL.documentsDirectory.appendingPathComponent("Application Support", isDirectory: true)
        let folder = applicationSupport.appendingPathComponent("Workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        workspaceURL = folder
    }

    var body: some View {
        FileBrowserView(
            path: workspaceURL,
            readOnly: false,
            navigationTitleOverride: "Workspace"
        )
    }
}

/// A virtual parent folder whose rows open the actual read-only system directories.
private struct SystemPathsBrowserView: View {
    private var files: [URL] {
        [FSURL.systemDeveloper, FSURL.systemCryptexes, FSURL.systemLibrary]
            .filter { SystemReadOnlyAccess.canReadDirectory($0) }
    }

    var body: some View {
        FileBrowserView(
            path: URL(fileURLWithPath: "/System"),
            readOnly: true,
            fixedFiles: files,
            navigationTitleOverride: "System"
        )
    }
}

/// A virtual parent folder grouping the real /usr/lib, /usr/share and /usr/libexec paths.
private struct UsrPathsBrowserView: View {
    private var files: [URL] {
        [FSURL.usrLib, FSURL.usrShare].filter { SystemReadOnlyAccess.canReadDirectory($0) }
            + [FSURL.usrLibexec]
    }

    var body: some View {
        FileBrowserView(
            path: URL(fileURLWithPath: "/usr"),
            readOnly: true,
            fixedFiles: files,
            navigationTitleOverride: "usr"
        )
    }
}

private struct EtcBrowserView: View {
    private let files: [URL] = [
        URL(fileURLWithPath: "/etc/hosts"),
        URL(fileURLWithPath: "/etc/passwd"),
        URL(fileURLWithPath: "/etc/services"),
        URL(fileURLWithPath: "/etc/protocols"),
        URL(fileURLWithPath: "/etc/group")
    ]

    var body: some View {
        FileBrowserView(
            path: FSURL.etc,
            readOnly: true,
            fixedFiles: files,
            navigationTitleOverride: "etc"
        )
    }
}

private struct SystemReadOnlyTextViewer: View {
    let fileURL: URL
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
                .tint(Color.accentColor)
        }
        .navigationTitle(fileURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Text("Read-only")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
        }
        .onAppear {
            text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "Unable to read file."
        }
    }
}
