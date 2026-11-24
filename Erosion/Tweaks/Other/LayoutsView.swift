import SwiftUI
import Combine
import UniformTypeIdentifiers
import Foundation

private let iconStateRemotePath = "/var/mobile/Library/SpringBoard/IconState.plist"

struct SavedIconLayout: Codable, Identifiable, Equatable {
    let id: String
    var displayName: String
    let createdAt: Date
}

private enum IconStatePathPart {
    case key(String)
    case index(Int)
}

private struct IconStateDocument {
    private var root: Any
    private let iconListsPath: [IconStatePathPart]
    private let plistFormat: PropertyListSerialization.PropertyListFormat
    let pages: [[Any]]

    init(data: Data) throws {
        var format = PropertyListSerialization.PropertyListFormat.xml
        let rootValue = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        guard let found = Self.findIconLists(in: rootValue, path: []), !found.pages.isEmpty else {
            throw LayoutsError.invalidIconState
        }
        root = rootValue
        iconListsPath = found.path
        plistFormat = format
        pages = found.pages
    }

    func serialized(replacingPages newPages: [[Any]]) throws -> Data {
        guard let newRoot = Self.replacing(root, at: iconListsPath[...], with: newPages) else {
            throw LayoutsError.invalidIconState
        }
        return try PropertyListSerialization.data(fromPropertyList: newRoot, format: plistFormat, options: 0)
    }

    private static func findIconLists(
        in value: Any,
        path: [IconStatePathPart]
    ) -> (path: [IconStatePathPart], pages: [[Any]])? {
        if let dictionary = value as? [String: Any] {
            if let candidate = dictionary["iconLists"] as? [Any],
               candidate.allSatisfy({ $0 is [Any] }),
               let pages = candidate as? [[Any]],
               pages.contains(where: { page in page.contains(where: hasBundleIdentifier) }) {
                return (path + [.key("iconLists")], pages)
            }

            // Prefer the main iconState branch when present; folder iconLists can be nested deeper.
            let orderedKeys = dictionary.keys.sorted { lhs, rhs in
                if lhs == "iconState" { return true }
                if rhs == "iconState" { return false }
                return lhs < rhs
            }
            for key in orderedKeys {
                guard let child = dictionary[key] else { continue }
                if let result = findIconLists(in: child, path: path + [.key(key)]) { return result }
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                if let result = findIconLists(in: child, path: path + [.index(index)]) { return result }
            }
        }
        return nil
    }

    private static func hasBundleIdentifier(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if dictionary["bundleIdentifier"] is String || dictionary["displayIdentifier"] is String { return true }
            return dictionary.values.contains(where: hasBundleIdentifier)
        }
        if let array = value as? [Any] { return array.contains(where: hasBundleIdentifier) }
        return false
    }

    private static func replacing(
        _ value: Any,
        at path: ArraySlice<IconStatePathPart>,
        with replacement: Any
    ) -> Any? {
        guard let first = path.first else { return replacement }
        let remainder = path.dropFirst()
        switch first {
        case .key(let key):
            guard var dictionary = value as? [String: Any], let child = dictionary[key],
                  let updated = replacing(child, at: remainder, with: replacement) else { return nil }
            dictionary[key] = updated
            return dictionary
        case .index(let index):
            guard var array = value as? [Any], array.indices.contains(index),
                  let updated = replacing(array[index], at: remainder, with: replacement) else { return nil }
            array[index] = updated
            return array
        }
    }
}

private enum LayoutsError: LocalizedError {
    case invalidIconState
    case missingLayout

    var errorDescription: String? {
        switch self {
        case .invalidIconState:
            return "This file does not contain a recognizable IconState iconLists structure."
        case .missingLayout:
            return "The saved layout could not be found."
        }
    }
}

@MainActor
final class LayoutsStore: ObservableObject {
    static let shared = LayoutsStore()

    @Published private(set) var layouts: [SavedIconLayout] = []
    @Published private(set) var shouldApplyTopLayout = false

    private let fileManager = FileManager.default
    private let rootDirectory: URL
    private let manifestURL: URL
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private init() {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        rootDirectory = support.appendingPathComponent("ErosionLayouts", isDirectory: true)
        manifestURL = rootDirectory.appendingPathComponent("layouts.json")
        try? fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        loadManifest()
    }

    func addLayout(data: Data, displayName: String? = nil, placeAtTop: Bool = false) throws -> SavedIconLayout {
        _ = try IconStateDocument(data: data) // Validate before keeping a user file.
        let now = Date()
        let id = UUID().uuidString
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = SavedIconLayout(
            id: id,
            displayName: (name?.isEmpty == false) ? name! : "Layout \(dateFormatter.string(from: now))",
            createdAt: now
        )
        let directory = rootDirectory.appendingPathComponent(id, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try data.write(to: directory.appendingPathComponent("IconState.plist"), options: .atomic)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        if placeAtTop {
            layouts.insert(record, at: 0)
        } else {
            layouts.append(record)
        }
        saveManifest()
        return record
    }

    func requestTopLayoutApply() {
        guard !layouts.isEmpty else { return }
        shouldApplyTopLayout = true
    }

    /// Persist the reordered list. Apply is enabled only when the moved row(s)
    /// were dropped at the first position; moving items elsewhere is local-only.
    @discardableResult
    func moveLayouts(from source: IndexSet, to destination: Int) -> Bool {
        guard !source.isEmpty else { return false }
        let previousOrder = layouts.map(\.id)
        layouts.move(fromOffsets: source, toOffset: destination)
        if destination != 0 {
            shouldApplyTopLayout = false
        }
        guard layouts.map(\.id) != previousOrder else { return false }
        saveManifest()
        shouldApplyTopLayout = destination == 0
        return true
    }

    func applyTopLayout(using airlift: AirliftBridge) async -> Bool {
        guard shouldApplyTopLayout, let topLayout = layouts.first,
              let url = fileURL(for: topLayout.id) else { return false }
        let succeeded = await airlift.writeBack(localURL: url, remotePath: iconStateRemotePath, logFeature: "layouts")
        if succeeded {
            shouldApplyTopLayout = false
        }
        return succeeded
    }

    func rename(id: String, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = layouts.firstIndex(where: { $0.id == id }) else { return }
        layouts[index].displayName = name
        saveManifest()
    }

    func delete(id: String) {
        guard let index = layouts.firstIndex(where: { $0.id == id }) else { return }
        try? fileManager.removeItem(at: rootDirectory.appendingPathComponent(id, isDirectory: true))
        layouts.remove(at: index)
        if layouts.isEmpty { shouldApplyTopLayout = false }
        saveManifest()
    }

    /// Removes every locally saved layout and resets the pending apply state.
    /// The current IconState.plist on the device is not changed.
    func clearAll() throws {
        do {
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            let storedItems = try fileManager.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: nil,
                options: []
            )
            for item in storedItems {
                try fileManager.removeItem(at: item)
            }

            let emptyManifest = try JSONEncoder().encode([SavedIconLayout]())
            try emptyManifest.write(to: manifestURL, options: .atomic)
            layouts = []
            shouldApplyTopLayout = false
        } catch {
            // Reconcile the published list if clearing stopped partway through.
            loadManifest()
            throw error
        }
    }

    func fileURL(for id: String) -> URL? {
        guard layouts.contains(where: { $0.id == id }) else { return nil }
        let url = rootDirectory.appendingPathComponent(id, isDirectory: true).appendingPathComponent("IconState.plist")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL),
              let stored = try? JSONDecoder().decode([SavedIconLayout].self, from: data) else {
            layouts = []
            return
        }
        layouts = stored.filter { fileManager.fileExists(atPath: rootDirectory.appendingPathComponent($0.id, isDirectory: true).appendingPathComponent("IconState.plist").path) }
    }

    private func saveManifest() {
        do {
            let data = try JSONEncoder().encode(layouts)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            print("(layouts) failed to save layout manifest: \(error.localizedDescription)")
        }
    }
}

/// Saved layout list and layout actions embedded in Other's existing List.
struct LayoutsView: View {
    @EnvironmentObject private var airlift: AirliftBridge
    @ObservedObject private var store = LayoutsStore.shared

    @State private var showingImporter = false
    @State private var showingRename = false
    @State private var isGettingCurrent = false
    @State private var renameLayoutID: String?
    @State private var renameText = ""

    var body: some View {
        Group {
            Section {
                if store.layouts.isEmpty {
                    Text("No saved layouts")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.layouts) { layout in
                        HStack(spacing: 10) {
                            Text(layout.displayName)
                                .foregroundStyle(.primary)

                            Spacer(minLength: 8)

                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .frame(width: 22)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button {
                                exportLayout(layout.id)
                            } label: {
                                Label("Export", systemImage: "square.and.arrow.up")
                            }
                            Button {
                                renameLayoutID = layout.id
                                renameText = layout.displayName
                                showingRename = true
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                Alertinator.shared.alert(
                                    title: "Delete this saved layout?",
                                    body: "This removes the selected layout from Erosion. It does not change the layout on the device.",
                                    actionLabel: "Confirm",
                                    actionStyle: .destructive,
                                    action: { store.delete(id: layout.id) }
                                )
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onMove { source, destination in
                        if store.moveLayouts(from: source, to: destination) {
                            Haptic.shared.play(.soft)
                        }
                    }
                }
            } header: {
                HeaderLabel("Layouts", symbol: "apps.iphone")
            } footer: {
                Text("To apply Home Screen layout drag it to the first place.")
            }

            Section {
                Button(isGettingCurrent ? "Getting Current…" : "Get Current") {
                    getCurrentLayout()
                }
                .disabled(isGettingCurrent)

                Button("Import") {
                    showingImporter = true
                }
                .disabled(isGettingCurrent)

                Button("Clear", role: .destructive) {
                    requestClearSavedLayouts()
                }
                .tint(.red)
                .disabled(isGettingCurrent)

                Button("Reset", role: .destructive) {
                    requestResetCurrentLayout()
                }
                .tint(.red)
                .disabled(isGettingCurrent)
            } header: {
                HeaderLabel("Actions", symbol: "bolt.fill")
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            importLayout(result)
        }
        .alert("Rename Layout", isPresented: $showingRename) {
            TextField("Layout name", text: $renameText)
            Button("Save") {
                if let renameLayoutID { store.rename(id: renameLayoutID, to: renameText) }
                renameLayoutID = nil
            }
            Button("Cancel", role: .cancel) { renameLayoutID = nil }
        } message: {
            Text("Only the name shown in Erosion will change. The exported IconState.plist filename stays the same.")
        }
    }

    private func getCurrentLayout() {
        guard !isGettingCurrent else { return }
        isGettingCurrent = true
        airlift.readRemotePathForFileOperations(path: iconStateRemotePath, kind: .file) { success, snapshotURL, detail in
            guard success, let snapshotURL else {
                isGettingCurrent = false
                Alertinator.shared.alert(title: "Failed to get current layout", body: detail)
                return
            }
            DispatchQueue.global(qos: .utility).async {
                let data = try? Data(contentsOf: snapshotURL)
                try? FileManager.default.removeItem(at: snapshotURL)
                DispatchQueue.main.async {
                    isGettingCurrent = false
                    guard let data else {
                        Alertinator.shared.alert(title: "Failed to read IconState.plist", body: AppMsg.opFailed)
                        return
                    }
                    do {
                        _ = try store.addLayout(data: data, placeAtTop: true)
                        Haptic.shared.play(.soft)
                    } catch {
                        Alertinator.shared.alert(title: "Invalid IconState.plist", body: error.localizedDescription)
                    }
                }
            }
        }
    }

    private func importLayout(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            _ = try store.addLayout(data: data)
            Haptic.shared.play(.soft)
        } catch {
            Alertinator.shared.alert(title: "Failed to import layout", body: error.localizedDescription)
        }
    }

    private func exportLayout(_ id: String) {
        guard let url = store.fileURL(for: id) else {
            Alertinator.shared.alert(title: "Layout unavailable", body: "The saved IconState.plist could not be found.")
            return
        }
        presentShareSheet(with: url)
    }

    private func requestClearSavedLayouts() {
        Alertinator.shared.alert(
            title: "Clear all saved layouts?",
            body: "This permanently removes every layout saved in Erosion. It does not change the current Home Screen layout on the device.",
            actionLabel: "Clear",
            actionStyle: .destructive,
            action: {
                do {
                    try store.clearAll()
                    Haptic.shared.play(.soft)
                    Alertinator.shared.alert(title: "Saved layouts cleared", body: "All layouts saved in Erosion were removed.")
                } catch {
                    Alertinator.shared.alert(title: "Failed to clear saved layouts", body: error.localizedDescription)
                }
            }
        )
    }

    private func requestResetCurrentLayout() {
        Alertinator.shared.alert(
            title: "Reset the current layout?",
            body: "This will restore the device's Home Screen layout state. Saved layouts in Erosion will remain available.",
            actionLabel: "Confirm",
            actionStyle: .destructive,
            action: { Task { await resetCurrentLayout() } }
        )
    }

    private func resetCurrentLayout() async {
        let success = await airlift.removeRemotePath(iconStateRemotePath, logFeature: "layouts")
        if success {
            Alertinator.shared.alert(title: "IconState.plist deleted", body: "The current layout file was removed from the device.")
        } else {
            Alertinator.shared.alert(title: "Failed to reset layout", body: AppMsg.opFailed)
        }
    }
}
