import SwiftUI
import UIKit

/// Image-catalog viewer for compiled Apple .car files. Assets are decoded on
/// demand, and the library grid uses lazy cells to avoid loading the whole file.
struct CARAssetCatalogPreview: View {
    let url: URL

    @State private var catalog: CARAssetCatalogSession?
    @State private var selectedIndex = 0
    @State private var selectedImage: UIImage?
    @State private var isLoading = true
    @State private var isLoadingAsset = false
    @State private var isLibraryPresented = false
    @State private var errorMessage: String?
    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    @State private var requestGeneration = UUID()

    private var currentAssetName: String {
        guard let catalog, catalog.assetNames.indices.contains(selectedIndex) else { return "" }
        return catalog.assetNames[selectedIndex]
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(committedScale * value, 0.25), 8)
            }
            .onEnded { _ in
                committedScale = scale
            }
    }

    private var panAndSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard scale > 1.02 else { return }
                offset = CGSize(
                    width: committedOffset.width + value.translation.width,
                    height: committedOffset.height + value.translation.height
                )
            }
            .onEnded { value in
                guard let catalog else { return }
                let horizontalSwipe = abs(value.translation.width) > 48
                    && abs(value.translation.width) > abs(value.translation.height)
                if scale <= 1.02 && horizontalSwipe {
                    let nextIndex = value.translation.width < 0
                        ? min(selectedIndex + 1, catalog.assetNames.count - 1)
                        : max(selectedIndex - 1, 0)
                    guard nextIndex != selectedIndex else { return }
                    Task { await selectAsset(at: nextIndex) }
                } else if scale > 1.02 {
                    committedOffset = offset
                }
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(String(format: "%.1f×", Double(scale)))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            GeometryReader { proxy in
                ZStack {
                    if let selectedImage {
                        Image(uiImage: selectedImage)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(scale)
                            .offset(offset)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .contentShape(Rectangle())
                            .gesture(SimultaneousGesture(zoomGesture, panAndSwipeGesture))
                            .onTapGesture(count: 2) { resetZoom() }
                            .onLongPressGesture(minimumDuration: 0.45) {
                                isLibraryPresented = true
                            }
                    } else if let errorMessage {
                        ContentUnavailableView(
                            "Unable to Open Asset Catalog",
                            systemImage: "square.grid.3x3.slash",
                            description: Text(errorMessage)
                        )
                    } else if isLoading || isLoadingAsset {
                        ProgressView(isLoading ? "Loading assets…" : "Loading asset…")
                    } else {
                        ContentUnavailableView(
                            "Asset Unavailable",
                            systemImage: "photo",
                            description: Text(currentAssetName)
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .clipped()
            }

            VStack(spacing: 3) {
                Text(currentAssetName.isEmpty ? url.lastPathComponent : currentAssetName)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 10) {
                    if let selectedImage {
                        Text("\(Int((selectedImage.size.width * selectedImage.scale).rounded())) × \(Int((selectedImage.size.height * selectedImage.scale).rounded()))")
                    }
                    if let catalog {
                        Text("\(selectedIndex + 1) / \(catalog.assetNames.count)")
                    }
                    Text("Hold for assets")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11, design: .monospaced))
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .task(id: url) {
            await loadCatalog()
        }
        .onDisappear {
            // Invalidate pending UI updates. Do not manually nil the catalog
            // here: the asset-library sheet and detached thumbnail tasks may
            // still hold active references while SwiftUI is dismissing views.
            // The bridge releases CoreUI objects on its serial queue when the
            // last real reference goes away.
            requestGeneration = UUID()
            isLibraryPresented = false
        }
        .sheet(isPresented: $isLibraryPresented) {
            if let catalog {
                CARAssetLibraryView(
                    catalog: catalog,
                    selectedIndex: selectedIndex
                ) { index in
                    isLibraryPresented = false
                    Task { await selectAsset(at: index) }
                }
                .presentationDetents([.large])
            }
        }
    }

    @MainActor
    private func loadCatalog() async {
        let generation = UUID()
        requestGeneration = generation
        isLoading = true
        errorMessage = nil
        selectedImage = nil
        catalog = nil
        do {
            let sourceURL = url
            let loadedCatalog = try await Task.detached(priority: .userInitiated) {
                try CARAssetCatalogSession(url: sourceURL)
            }.value
            guard requestGeneration == generation else { return }
            catalog = loadedCatalog
            isLoading = false
            await selectAsset(at: 0)
        } catch {
            guard requestGeneration == generation else { return }
            errorMessage = error.localizedDescription
        }
        if requestGeneration == generation {
            isLoading = false
        }
    }

    @MainActor
    private func selectAsset(at index: Int) async {
        guard let catalog, catalog.assetNames.indices.contains(index) else { return }
        let generation = UUID()
        requestGeneration = generation
        selectedIndex = index
        selectedImage = nil
        isLoadingAsset = true
        resetZoom(animated: false)
        let name = catalog.assetNames[index]
        let image = await Task.detached(priority: .utility) {
            catalog.image(named: name)
        }.value
        guard requestGeneration == generation else { return }
        selectedImage = image
        isLoading = false
        isLoadingAsset = false
    }

    private func resetZoom(animated: Bool = true) {
        let reset = {
            scale = 1
            committedScale = 1
            offset = .zero
            committedOffset = .zero
        }
        if animated {
            withAnimation(.easeOut(duration: 0.2), reset)
        } else {
            reset()
        }
    }
}

private struct CARAssetLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    let catalog: CARAssetCatalogSession
    let selectedIndex: Int
    let onSelect: (Int) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)

    private var filteredIndices: [Int] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Array(catalog.assetNames.indices) }
        return catalog.assetNames.indices.filter {
            catalog.assetNames[$0].localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(filteredIndices, id: \.self) { index in
                            Button {
                                onSelect(index)
                                dismiss()
                            } label: {
                                VStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.secondary.opacity(0.12))
                                        .aspectRatio(1, contentMode: .fit)
                                        .overlay {
                                            CARAssetThumbnail(
                                                catalog: catalog,
                                                assetName: catalog.assetNames[index]
                                            )
                                            .padding(5)
                                        }
                                    Text(catalog.assetNames[index])
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                        .frame(maxWidth: .infinity)
                                }
                                .padding(3)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(index == selectedIndex ? Color.accentColor.opacity(0.12) : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                    .padding(12)
                }
                .searchable(text: $searchText, prompt: "Search assets")
                .task {
                    // Let the first LazyVGrid layout pass complete before
                    // resolving the selected tile's scroll position.
                    await Task.yield()
                    await Task.yield()
                    let anchor: UnitPoint = selectedIndex < columns.count ? .top : .center
                    proxy.scrollTo(selectedIndex, anchor: anchor)
                }
            }
            .navigationTitle("Assets (\(catalog.assetNames.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct CARAssetThumbnail: View {
    let catalog: CARAssetCatalogSession
    let assetName: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: assetName) {
            let catalog = catalog
            let name = assetName
            let loadedThumbnail = await Task.detached(priority: .utility) {
                catalog.thumbnail(named: name)
            }.value
            guard !Task.isCancelled else { return }
            image = loadedThumbnail
        }
    }
}
