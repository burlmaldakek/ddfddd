import SwiftUI
import Combine
import Foundation
import UniformTypeIdentifiers

struct PasscodeLibraryTheme: Identifiable, Sendable {
    let filename: String
    let name: String
    let url: URL
    let keyCount: Int

    var id: String { filename }
}

enum PasscodeThemeLibraryError: LocalizedError {
    case invalidTheme
    case missingSavedTheme

    var errorDescription: String? {
        switch self {
        case .invalidTheme:
            return "This file does not contain a valid passcode theme."
        case .missingSavedTheme:
            return "The theme was saved, but could not be loaded from Library."
        }
    }
}

/// Persistent archive library used only by Custom Passcode.
@MainActor
final class PasscodeThemeLibraryStore: ObservableObject {
    static let shared = PasscodeThemeLibraryStore()

    private let selectedFilenameKey = "erosion.passcodeLibrary.selectedFilename"
    @Published private(set) var themes: [PasscodeLibraryTheme] = []
    @Published private(set) var isLoading = false
    @Published private(set) var selectedFilename: String? = UserDefaults.standard.string(forKey: "erosion.passcodeLibrary.selectedFilename")
    private var reloadTask: Task<Void, Never>?
    private var reloadWorker: Task<[PasscodeLibraryTheme], Never>?
    private var reloadGeneration = 0

    var directoryURL: URL { AppURL.ps }

    private var legacyDirectoryURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("ErosionPasscodeLibrary", isDirectory: true)
    }

    private func migrateLegacyThemesIfNeeded() {
        let fm = FileManager.default
        guard let legacyURLs = try? fm.contentsOfDirectory(at: legacyDirectoryURL, includingPropertiesForKeys: nil) else { return }
        for source in legacyURLs where source.pathExtension.lowercased() == "passthm" {
            let destination = directoryURL.appendingPathComponent(source.lastPathComponent)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            try? fm.copyItem(at: source, to: destination)
        }
    }

    // Do not scan/extract .passthm archives in init. The Library destination may be
    // constructed while Custom Passcode is being presented, and a synchronous scan
    // here blocks the main thread before the screen can render.
    private init() {}

    func reload() {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        selectedFilename = UserDefaults.standard.string(forKey: selectedFilenameKey)
        isLoading = true
        reloadTask?.cancel()
        reloadWorker?.cancel()

        let directory = directoryURL
        let legacyDirectory = legacyDirectoryURL
        let worker = Task.detached(priority: .utility) {
            Self.readThemes(directoryURL: directory, legacyDirectoryURL: legacyDirectory)
        }
        reloadWorker = worker
        reloadTask = Task { [weak self] in
            let loaded = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }

            guard let self, !Task.isCancelled, self.reloadGeneration == generation else { return }
            self.reloadWorker = nil
            self.themes = loaded
            self.isLoading = false
            if let selected = self.selectedFilename,
               !loaded.contains(where: { $0.filename == selected }) {
                self.clearSelection()
            }
        }
    }

    private nonisolated static func readThemes(
        directoryURL: URL,
        legacyDirectoryURL: URL
    ) -> [PasscodeLibraryTheme] {
        let fm = FileManager.default
        try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if let legacyURLs = try? fm.contentsOfDirectory(at: legacyDirectoryURL, includingPropertiesForKeys: nil) {
            for source in legacyURLs where source.pathExtension.lowercased() == "passthm" {
                let destination = directoryURL.appendingPathComponent(source.lastPathComponent)
                guard !fm.fileExists(atPath: destination.path) else { continue }
                try? fm.copyItem(at: source, to: destination)
            }
        }

        let urls = (try? fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)) ?? []
        let themeURLs = urls
            .filter { $0.pathExtension.lowercased() == "passthm" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var loaded: [PasscodeLibraryTheme] = []
        for url in themeURLs {
            if Task.isCancelled { return [] }
            guard let keyCount = ErosionPasscodeThemeReader.keyCount(in: url) else { continue }
            loaded.append(PasscodeLibraryTheme(
                filename: url.lastPathComponent,
                name: url.deletingPathExtension().lastPathComponent,
                url: url,
                keyCount: keyCount
            ))
        }
        return loaded
    }

    @discardableResult
    func importTheme(from sourceURL: URL, preferredName: String? = nil) throws -> PasscodeLibraryTheme {
        guard let parsed = ErosionPasscodeThemeReader.inspect(url: sourceURL) else {
            throw PasscodeThemeLibraryError.invalidTheme
        }

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let sourceName = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawName = (sourceName?.isEmpty == false ? sourceName! : sourceURL.deletingPathExtension().lastPathComponent)
        let safeName = Self.safeFilename(rawName)
        let destination = directoryURL.appendingPathComponent(safeName).appendingPathExtension("passthm")
        let data = try Data(contentsOf: sourceURL)
        try data.write(to: destination, options: .atomic)

        // Update the in-memory list immediately from the validated archive. reload()
        // continues in the background and cannot make a successful import appear to fail.
        let saved = PasscodeLibraryTheme(
            filename: destination.lastPathComponent,
            name: destination.deletingPathExtension().lastPathComponent,
            url: destination,
            keyCount: parsed.keys.count
        )
        if let index = themes.firstIndex(where: { $0.filename == saved.filename }) {
            themes[index] = saved
        } else {
            themes.append(saved)
        }
        themes.sort { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        reload()
        return saved
    }

    func select(_ theme: PasscodeLibraryTheme) {
        selectedFilename = theme.filename
        UserDefaults.standard.set(theme.filename, forKey: selectedFilenameKey)
    }

    func clearSelection() {
        selectedFilename = nil
        UserDefaults.standard.removeObject(forKey: selectedFilenameKey)
    }

    func deleteTheme(_ theme: PasscodeLibraryTheme) throws {
        try FileManager.default.removeItem(at: theme.url)
        if selectedFilename == theme.filename {
            clearSelection()
        }
        reload()
    }

    private static func safeFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_()."))
        let cleaned = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return cleaned.isEmpty ? "Passcode Theme" : cleaned
    }
}

struct PasscodeExploreView: View {
    @StateObject private var gallery = PasscodeGalleryManager.shared
    let searchText: String
    let refreshToken: Int

    private let columns = [GridItem(.flexible(), spacing: 14)]

    private var filteredThemes: [PasscodeGalleryTheme] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return gallery.allThemes }
        return gallery.allThemes.filter { theme in
            theme.name.localizedCaseInsensitiveContains(query)
                || theme.description.localizedCaseInsensitiveContains(query)
                || theme.contact.displayName.localizedCaseInsensitiveContains(query)
                || theme.version.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            if gallery.isLoading && gallery.allThemes.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 36)
            } else if gallery.allThemes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No passcode themes available")
                        .fontWeight(.medium)
                    if let error = gallery.loadError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 36)
                .padding(.horizontal, 24)
            } else if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && filteredThemes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No matching themes")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 36)
                .padding(.horizontal, 24)
            }

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(filteredThemes) { theme in
                    Button {
                        Task { await importTheme(theme) }
                    } label: {
                        HStack(alignment: .center, spacing: 14) {
                            HomeThemingRemotePreview(url: gallery.previewURL(for: theme), scaling: .fit)
                                .frame(width: 104, height: 112)
                                .background(Color(.tertiarySystemBackground), in: .rect(cornerRadius: 14))
                                .clipShape(.rect(cornerRadius: 14))

                            VStack(alignment: .leading, spacing: 5) {
                                Text(theme.name)
                                    .fontWeight(.semibold)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2)

                                Text(theme.description)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(3)

                                let author = theme.contact.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !author.isEmpty {
                                    Text(author)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }

                                if gallery.isDownloading(theme) {
                                    ProgressView()
                                        .controlSize(.small)
                                        .padding(.top, 2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
                        .padding(12)
                        .background {
                            RoundedRectangle(cornerRadius: 26)
                                .fill(Color(.secondarySystemBackground))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(gallery.isDownloading(theme))
                }
            }
            .padding(.horizontal, 15)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .task {
            if gallery.allThemes.isEmpty && !gallery.isLoading {
                await gallery.loadThemes()
            }
        }
        .onChange(of: refreshToken) { _, newValue in
            guard newValue > 0 else { return }
            Task { await gallery.refreshRepos(forceRefresh: true) }
        }
    }

    private func importTheme(_ theme: PasscodeGalleryTheme) async {
        guard !gallery.isDownloading(theme) else { return }
        gallery.downloading.insert(theme.id)
        defer { gallery.downloading.remove(theme.id) }

        do {
            guard let remoteURL = gallery.downloadURL(for: theme) else {
                throw URLError(.badURL)
            }
            let (data, response) = try await URLSession.shared.data(from: remoteURL)
            if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
                throw URLError(.badServerResponse)
            }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("erosion_passcode_explore_\(UUID().uuidString)")
                .appendingPathExtension("passthm")
            defer { try? FileManager.default.removeItem(at: tempURL) }
            try data.write(to: tempURL, options: .atomic)
            _ = try PasscodeThemeLibraryStore.shared.importTheme(from: tempURL, preferredName: theme.name)
            Haptic.shared.play(.soft)
            Alertinator.shared.alert(title: "Imported into Library", body: "\(theme.name) is now available in Library.")
        } catch {
            Alertinator.shared.alert(title: "Failed to import theme", body: error.localizedDescription)
        }
    }
}

struct PasscodeLibraryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var showImporter = false
    @EnvironmentObject private var airlift: AirliftBridge
    @ObservedObject private var library = PasscodeThemeLibraryStore.shared

    private var libraryPageBackground: Color {
        colorScheme == .light ? Color(.systemGroupedBackground) : Color(.systemBackground)
    }

    private var libraryCardBackground: Color {
        colorScheme == .light ? Color(.secondarySystemGroupedBackground) : Color(.secondarySystemBackground)
    }
    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 14),
        count: device.userInterfaceIdiom == .pad ? 4 : 2
    )

    var body: some View {
        ScrollView {
            if library.themes.isEmpty {
                Button {
                    showImporter = true
                } label: {
                    CompactAlert(
                        title: "No passcode themes imported!",
                        symbol: "exclamationmark.triangle.fill",
                        text: "Import .passthm yourself or from explore to start applying custom keys."
                    )
                    .padding(.horizontal, 15)
                }
                .buttonStyle(.plain)
            }

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(library.themes) { theme in
                    let isSelected = library.selectedFilename == theme.filename
                    let isBlocked = library.selectedFilename != nil && !isSelected

                    Button {
                        guard !isBlocked else { return }
                        toggleSelection(theme)
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "lock.fill")
                                .imageScale(.large)
                                .foregroundStyle(Color.accentColor)

                            VStack {
                                Text(theme.name)
                                    .lineLimit(1)
                                    .fontWeight(.medium)
                                Text("\(theme.keyCount) key" + (theme.keyCount == 1 ? "" : "s"))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                        .padding(.vertical, 10)
                        .background {
                            RoundedRectangle(cornerRadius: 26)
                                .fill(libraryCardBackground)
                                .overlay {
                                    if isSelected {
                                        RoundedRectangle(cornerRadius: 26)
                                            .fill(Color.clear)
                                            .strokeBorder(lineWidth: 2)
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                        }
                        .opacity(isBlocked ? 0.45 : 1)
                    }
                    .buttonStyle(.plain)
        .contextMenu {
                        Button {
                            fsHandlers.openInFilesApp(library.directoryURL)
                        } label: {
                            Label("Show Data Directory", systemImage: "folder")
                        }

                        Button(role: .destructive) {
                            let wasSelected = library.selectedFilename == theme.filename
                            do {
                                try library.deleteTheme(theme)
                                if wasSelected {
                                    airlift.clearPasscodeTheme()
                                }
                                Haptic.shared.play(.soft)
                            } catch {
                                Alertinator.shared.alert(title: "Failed to delete theme", body: error.localizedDescription)
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 15)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .background(libraryPageBackground)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.archive, UTType(filenameExtension: "passthm") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                _ = try library.importTheme(from: url)
                Haptic.shared.play(.soft)
            } catch {
                Alertinator.shared.alert(
                    title: "Failed to import passcode theme!",
                    body: error.localizedDescription
                )
            }
        }
        .onAppear { library.reload() }
    }

    private func toggleSelection(_ theme: PasscodeLibraryTheme) {
        if library.selectedFilename == theme.filename {
            library.clearSelection()
            airlift.clearPasscodeTheme()
            Haptic.shared.play(.soft)
            return
        }

        guard library.selectedFilename == nil else { return }
        library.select(theme)
        airlift.loadPasscodeTheme(url: theme.url)
        Haptic.shared.play(.soft)
    }
}
