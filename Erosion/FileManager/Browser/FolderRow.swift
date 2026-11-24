//
//  FolderRow.swift
//  AccessiblePlus
//
//  Created by lunginspector on 5/20/26.
//

import SwiftUI
import QuickLook
import ZIPFoundation

struct FolderRow: View {
    @EnvironmentObject var mgr: ErosionManager
    var file: FileItem
    var shouldGrant: Bool
    var isContainer: Bool = false
    var readOnly: Bool = false
    var airliftRemoteRoot: String? = nil
    var airliftLocalRoot: String? = nil
    var displayName: String? = nil
    var navigationBlocked: Bool = false
    var metadataOnly: Bool = false

    @State private var previewURL: URL?
    @State private var showInfo = false

    private var airliftRemotePath: String? {
        guard let root = airliftRemoteRoot, let localRoot = airliftLocalRoot else { return nil }
        return AirliftBridge.remotePath(remoteRoot: root, localRoot: localRoot, localURL: file.fileURL)
    }

    private var isAirliftRemote: Bool {
        airliftRemotePath != nil && airliftRemoteRoot != nil && airliftLocalRoot != nil
    }

    private func remoteMutationAllowed() -> Bool {
        AirliftBridge.shared.fileBrowserWriteReady()
    }

    private var rowLabelContents: some View {
        HStack(spacing: isSolariumUI() ? 12 : 10) {
            Image(systemName: "folder")
                .frame(width: 20, alignment: .center)
                .foregroundStyle((navigationBlocked || file.hidden) ? .secondary : .primary)

            VStack(alignment: .leading, spacing: 0) {
                Text(displayName ?? file.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle((!navigationBlocked && !file.hidden) ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var infoButton: some View {
        Button {
            showInfo.toggle()
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(navigationBlocked ? Color.primary : (file.hidden ? Color.secondary : Color.primary))
        .accessibilityLabel("Get Info for \(displayName ?? file.name)")
    }

    var body: some View {
        if metadataOnly {
            HStack(spacing: isSolariumUI() ? 12 : 10) {
                rowLabelContents
                infoButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Color(.label))
            .sheet(isPresented: $showInfo) {
                InfoViewer(file, pathOverride: airliftRemotePath)
            }
        } else {
            HStack(spacing: 0) {
                Group {
                    if navigationBlocked {
                        rowLabelContents
                    } else {
                        NavigationLink(destination: FileBrowserView(
                            path: (readOnly && SystemReadOnlyAccess.isSystemPath(file.fileURL)) ? file.fileURL : file.destURL,
                            shouldGrant: shouldGrant,
                            readOnly: readOnly,
                            airliftRemoteRoot: airliftRemoteRoot,
                            airliftLocalRoot: airliftLocalRoot
                        )) {
                            rowLabelContents
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .contextMenu {
                    if !readOnly && !isContainer {
                        Button {
                        Alertinator.shared.prompt(title: "What would you like to call this folder?", placeholder: file.name) { result in
                            guard let name = result, !name.isEmpty else { return }
                            let oldURL = file.fileURL
                            let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
                            guard !fm.fileExists(atPath: newURL.path) else {
                                Alertinator.shared.alert(title: "Failed to rename folder!", body: "A folder with that name already exists.")
                                return
                            }

                            if isAirliftRemote {
                                guard remoteMutationAllowed(), let oldRemote = airliftRemotePath else {
                                    Alertinator.shared.alert(title: "Airlift write unavailable", body: "Enable LocalDevVPN and make sure the pairing file is imported.")
                                    return
                                }
                                let parent = URL(fileURLWithPath: oldRemote).deletingLastPathComponent()
                                let newRemote = parent.appendingPathComponent(name, isDirectory: true).path
                                do {
                                    try fm.copyItem(at: oldURL, to: newURL)
                                } catch {
                                    Alertinator.shared.alert(title: "Failed to rename folder!", body: error.localizedDescription)
                                    return
                                }
                                Task {
                                    let wrote = await AirliftBridge.shared.createRemoteDirectory(localURL: newURL, remotePath: newRemote)
                                    let deleted = wrote ? await AirliftBridge.shared.removeRemotePath(oldRemote) : false
                                    if wrote && !deleted {
                                        _ = await AirliftBridge.shared.removeRemotePath(newRemote)
                                    }
                                    await MainActor.run {
                                        if wrote && deleted {
                                            try? fm.removeItem(at: oldURL)
                                            mgr.refreshFiles.toggle()
                                        } else {
                                            try? fm.removeItem(at: newURL)
                                            Alertinator.shared.alert(title: "Failed to rename folder!", body: "The remote Airlift rename failed. Check the Airlift log.")
                                        }
                                    }
                                }
                            } else {
                                do {
                                    try fm.moveItem(at: oldURL, to: newURL)
                                    mgr.refreshFiles.toggle()
                                } catch {
                                    Alertinator.shared.alert(title: "Failed to rename folder!", body: error.localizedDescription)
                                }
                            }
                        }
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                    }

                    if readOnly {
                        Button {
                            let sourceURL = file.fileURL
                            Task { @MainActor in
                                do {
                                    let archiveURL = try await Task.detached(priority: .userInitiated) {
                                        try zipItemToWorkspace(at: sourceURL, isDirectory: true)
                                    }.value
                                    mgr.refreshFiles.toggle()
                                    Alertinator.shared.alert(
                                        title: "Compressed to Workspace",
                                        body: archiveURL.lastPathComponent
                                    )
                                } catch {
                                    Alertinator.shared.alert(title: "Failed to compress folder!", body: error.localizedDescription)
                                }
                            }
                        } label: {
                            Label("Compress", systemImage: "archivebox")
                        }
                    } else if !isContainer {
                        Button {
                            guard !isAirliftRemote || remoteMutationAllowed() else {
                                Alertinator.shared.alert(title: "Airlift write unavailable", body: "Enable LocalDevVPN and make sure the pairing file is imported.")
                                return
                            }
                            let zipURL = file.fileURL.deletingLastPathComponent().appendingPathComponent(file.name + ".zip")
                            guard !fm.fileExists(atPath: zipURL.path) else {
                                Alertinator.shared.alert(title: "Failed to compress folder!", body: "An archive with that name already exists.")
                                return
                            }
                            guard zipFile(file.fileURL, isDirectory: true) else {
                                Alertinator.shared.alert(title: "Failed to compress folder!", body: Errors.checkLogs)
                                return
                            }

                            guard isAirliftRemote else {
                                mgr.refreshFiles.toggle()
                                return
                            }
                            let siblingRemote = URL(fileURLWithPath: airliftRemotePath ?? "")
                                .deletingLastPathComponent()
                                .appendingPathComponent(zipURL.lastPathComponent)
                                .path
                            Task {
                                let ok = await AirliftBridge.shared.writeBack(localURL: zipURL, remotePath: siblingRemote)
                                await MainActor.run {
                                    if ok {
                                        mgr.refreshFiles.toggle()
                                    } else {
                                        try? fm.removeItem(at: zipURL)
                                        Alertinator.shared.alert(title: "Failed to compress folder!", body: "The remote Airlift write failed. Check the Airlift log.")
                                    }
                                }
                            }
                        } label: {
                            Label("Compress", systemImage: "archivebox")
                        }
                    }

                    Divider()

                    Button {
                        previewURL = file.fileURL
                    } label: {
                        Label("Quick Look", systemImage: "eye")
                    }

                    Button {
                        showInfo.toggle()
                    } label: {
                        Label("Get Info", systemImage: "info.circle")
                    }

                    if !readOnly && !isContainer {
                        Button(role: .destructive) {
                            guard !isAirliftRemote || remoteMutationAllowed() else {
                                Alertinator.shared.alert(title: "Airlift write unavailable", body: "Enable LocalDevVPN and make sure the pairing file is imported.")
                                return
                            }
                            if isAirliftRemote, let remotePath = airliftRemotePath {
                                Task {
                                    let ok = await AirliftBridge.shared.removeRemotePath(remotePath)
                                    await MainActor.run {
                                        if ok {
                                            do {
                                                try fm.removeItem(at: file.fileURL)
                                                mgr.refreshFiles.toggle()
                                            } catch {
                                                Alertinator.shared.alert(title: "Remote delete succeeded", body: "The snapshot could not be removed locally: \(error.localizedDescription)")
                                            }
                                        } else {
                                            Alertinator.shared.alert(title: "Failed to delete folder!", body: "The remote Airlift delete failed. The local snapshot was kept unchanged. Check the Airlift log.")
                                        }
                                    }
                                }
                            } else {
                                do {
                                    try fm.removeItem(at: file.fileURL)
                                    mgr.refreshFiles.toggle()
                                } catch {
                                    Alertinator.shared.alert(title: "Failed to delete folder!", body: error.localizedDescription)
                                }
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }

                infoButton
                    .padding(.leading, isSolariumUI() ? 12 : 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Color(.label))
            .sheet(isPresented: $showInfo) {
                InfoViewer(file, pathOverride: airliftRemotePath)
            }
            .quickLookPreview($previewURL)

    }
    }

}
