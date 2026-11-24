import SwiftUI

private enum HomeThemingCategory: String, CaseIterable, Identifiable {
    case passcode = "Passcode"
    case wallpapers = "Wallpapers"

    var id: String { rawValue }
}

/// The Home entry point for the existing passcode theme gallery and the
/// downloadable custom wallpaper gallery.
struct HomeThemingExploreView: View {
    @State private var selectedCategory: HomeThemingCategory = .passcode
    @State private var searchText = ""
    @State private var refreshToken = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Picker("Explore", selection: $selectedCategory) {
                    ForEach(HomeThemingCategory.allCases) { category in
                        Text(category.rawValue).tag(category)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 10)

                Group {
                    switch selectedCategory {
                    case .passcode:
                        PasscodeExploreView(searchText: searchText, refreshToken: refreshToken)
                    case .wallpapers:
                        WallpaperExploreContent(searchText: searchText, refreshToken: refreshToken)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.visible)
        .refreshable { refreshToken += 1 }
        .navigationTitle("Explore")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search themes"
        )
    }
}

private struct ErosionCatalogWallpaper: Decodable, Identifiable {
    let id: Int
    let name: String
    let description: String?
    let url: String
    let preview: String
    let authors: String?
}

private enum WallpaperCatalogError: LocalizedError {
    case badResponse
    case invalidURL
    case invalidWallpaperFile
    case importFailed

    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "The wallpaper catalog could not be loaded. Please try again."
        case .invalidURL:
            return "The wallpaper download address is invalid."
        case .invalidWallpaperFile:
            return "This download is not a valid .tendies wallpaper file."
        case .importFailed:
            return "The downloaded wallpaper could not be imported."
        }
    }
}

private enum WallpaperCatalogService {
    private static let repositoryBaseURL = URL(
        string: "https://raw.githubusercontent.com/SerStars/nugget-wallpapers/main/"
    )!

    static func fetchCustomWallpapers() async throws -> ([ErosionCatalogWallpaper], URL) {
        // Fetch the custom catalog directly. Resolving the latest commit through
        // the GitHub API first added an unnecessary sequential network round-trip.
        let catalogURL = repositoryBaseURL.appendingPathComponent("wallpapers-custom.json")
        let (catalogData, catalogResponse) = try await URLSession.shared.data(from: catalogURL)
        guard let catalogHTTP = catalogResponse as? HTTPURLResponse,
              (200...299).contains(catalogHTTP.statusCode) else {
            throw WallpaperCatalogError.badResponse
        }

        let wallpapers = try JSONDecoder().decode([ErosionCatalogWallpaper].self, from: catalogData)
        return (wallpapers, repositoryBaseURL)
    }

    static func resolve(_ path: String, relativeTo baseURL: URL) -> URL? {
        if let absoluteURL = URL(string: path), absoluteURL.scheme != nil {
            return absoluteURL
        }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL
    }
}

private struct WallpaperExploreContent: View {
    let searchText: String
    let refreshToken: Int

    @AppStorage("tendiesArray") private var tendiesArray: [TendiesObject] = []
    @State private var wallpapers: [ErosionCatalogWallpaper] = []
    @State private var repositoryBaseURL: URL?
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var loadError: String?
    @State private var downloading: Set<Int> = []

    private let columns = [GridItem(.adaptive(minimum: 155), spacing: 12)]
    private let previewHeight: CGFloat = 214
    private let cardHeight: CGFloat = 308

    private var filteredWallpapers: [ErosionCatalogWallpaper] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return wallpapers }
        return wallpapers.filter { wallpaper in
            wallpaper.name.localizedCaseInsensitiveContains(query)
                || (wallpaper.description ?? "").localizedCaseInsensitiveContains(query)
                || (wallpaper.authors ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            if isLoading && wallpapers.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 36)
            } else if let loadError, wallpapers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Couldn't load wallpapers")
                        .fontWeight(.medium)
                    Text(loadError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 36)
                .padding(.horizontal, 24)
            } else if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && filteredWallpapers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No matching wallpapers")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 36)
            } else if didLoad && filteredWallpapers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No wallpapers available")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 36)
            }

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(filteredWallpapers) { wallpaper in
                    wallpaperCard(wallpaper)
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .task {
            if !didLoad && !isLoading {
                await loadWallpapers()
            }
        }
        .onChange(of: refreshToken) { _, newValue in
            guard newValue > 0 else { return }
            Task { await loadWallpapers(forceRefresh: true) }
        }
    }

    private func wallpaperCard(_ wallpaper: ErosionCatalogWallpaper) -> some View {
        let previewURL = repositoryBaseURL.flatMap {
            WallpaperCatalogService.resolve(wallpaper.preview, relativeTo: $0)
        }
        let isDownloading = downloading.contains(wallpaper.id)

        return Button {
            Task { await importWallpaper(wallpaper) }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HomeThemingRemotePreview(url: previewURL, scaling: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(height: previewHeight)
                    .background(Color(.tertiarySystemBackground), in: .rect(cornerRadius: 17))
                    .clipShape(.rect(cornerRadius: 17))
                    .padding(7)

                VStack(alignment: .leading, spacing: 4) {
                    if isDownloading {
                        // Prefer the indicator beside a short, single-line title.
                        // If the title needs the available width, ViewThatFits moves
                        // the same indicator to the trailing edge of the author row.
                        ViewThatFits(in: .horizontal) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .center, spacing: 7) {
                                    Text(wallpaper.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.primary)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                    ProgressView()
                                        .controlSize(.small)
                                        .frame(width: 16, height: 16)
                                    Spacer(minLength: 0)
                                }
                                .frame(height: 42, alignment: .topLeading)

                                Text(wallpaper.authors ?? " ")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .frame(height: 18, alignment: .topLeading)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(wallpaper.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.primary)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2)
                                    .frame(height: 42, alignment: .topLeading)

                                HStack(alignment: .center, spacing: 7) {
                                    Text(wallpaper.authors ?? " ")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    ProgressView()
                                        .controlSize(.small)
                                        .frame(width: 16, height: 16)
                                }
                                .frame(height: 18, alignment: .topLeading)
                            }
                        }
                    } else {
                        Text(wallpaper.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                            .frame(height: 42, alignment: .topLeading)

                        Text(wallpaper.authors ?? " ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(height: 18, alignment: .topLeading)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 1)
                .padding(.bottom, 10)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: cardHeight, alignment: .top)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 26))
            .clipShape(.rect(cornerRadius: 26))
            .contentShape(.rect(cornerRadius: 26))
        }
        .buttonStyle(.plain)
        .disabled(isDownloading)
        .accessibilityLabel("Import wallpaper \(wallpaper.name)")
    }

    @MainActor
    private func loadWallpapers(forceRefresh: Bool = false) async {
        guard !isLoading, (!didLoad || forceRefresh) else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let result = try await WallpaperCatalogService.fetchCustomWallpapers()
            guard !Task.isCancelled else { return }
            wallpapers = result.0
            repositoryBaseURL = result.1
            didLoad = true
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
    }

    @MainActor
    private func importWallpaper(_ wallpaper: ErosionCatalogWallpaper) async {
        guard !downloading.contains(wallpaper.id), let repositoryBaseURL,
              let downloadURL = WallpaperCatalogService.resolve(wallpaper.url, relativeTo: repositoryBaseURL) else {
            return
        }
        guard downloadURL.pathExtension.lowercased() == "tendies" else {
            Alertinator.shared.alert(title: "Failed to import wallpaper", body: WallpaperCatalogError.invalidWallpaperFile.localizedDescription)
            return
        }

        downloading.insert(wallpaper.id)
        defer { downloading.remove(wallpaper.id) }

        do {
            let (data, response) = try await URLSession.shared.data(from: downloadURL)
            if let response = response as? HTTPURLResponse,
               !(200...299).contains(response.statusCode) {
                throw WallpaperCatalogError.badResponse
            }

            try FileManager.default.createDirectory(at: AppURL.pbFolders, withIntermediateDirectories: true)
            let safeName = wallpaper.name
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: "\\", with: "-")
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(safeName)-\(UUID().uuidString)")
                .appendingPathExtension("tendies")
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            try data.write(to: temporaryURL, options: .atomic)

            guard var imported = pbHandler.makeObjectFromTendies(at: temporaryURL) else {
                throw WallpaperCatalogError.importFailed
            }
            imported.name = wallpaper.name
            withAnimation {
                tendiesArray.append(imported)
            }

            Haptic.shared.play(.soft)
            Alertinator.shared.alert(
                title: "Imported into Wallpapers",
                body: "\(wallpaper.name) has been added to Custom Wallpapers."
            )
        } catch {
            Alertinator.shared.alert(title: "Failed to import wallpaper", body: error.localizedDescription)
        }
    }
}
