import SwiftUI
import UIKit

private enum AirliftContainerCategory: String, CaseIterable, Identifiable {
    case applications = "Applications"
    case daemons = "Daemons"
    case plugins = "Plugins"
    case appGroups = "AppGroups"

    var id: String { rawValue }

    var title: String { rawValue }

    var symbol: String {
        switch self {
        case .applications: return "square.stack.3d.up"
        case .daemons: return "shippingbox"
        case .plugins: return "puzzlepiece.extension"
        case .appGroups: return "person.2"
        }
    }
}

private struct AirliftContainerResult: Identifiable {
    let label: String
    let path: String
    var id: String { path }
}

struct AirliftContainersView: View {
    @EnvironmentObject private var airlift: AirliftBridge
    @State private var selectedCategory: AirliftContainerCategory = .applications
    @State private var search = ""
    @State private var resolvedBundleIDs: [String: String] = [:]
    @State private var bundleIDLookupResults: [String: FolderLabelDiagnostic] = [:]
    @State private var bundleIDResolutionStarted: Set<String> = []

    private var normalizedSearch: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizedPath(_ path: String) -> String {
        path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
    }

    // Applications must contain only Data/Application paths. InstallationProxy also
    // returns other container metadata in the same payload, which belongs in other tabs.
    private var applicationResults: [AirliftContainerResult] {
        airlift.installedAppContainers.compactMap { app in
            let path = normalizedPath(app.container)
            guard path.hasPrefix("/var/mobile/Containers/Data/Application/")
                    || path.hasPrefix("/var/containers/Data/Application/") else { return nil }
            return AirliftContainerResult(label: app.bundleID, path: path)
        }
        .filter { matchesSearch(label: $0.label, path: $0.path) }
        .sorted { $0.label == $1.label ? $0.path < $1.path : $0.label < $1.label }
    }

    private var appGroupResults: [AirliftContainerResult] {
        var values: [AirliftContainerResult] = airlift.installedAppGroups.map { group in
            AirliftContainerResult(
                label: group.groupIDs.first ?? "?",
                path: normalizedPath(group.container)
            )
        }
        values += airlift.appGroupAfcContainerPaths.map {
            AirliftContainerResult(label: airlift.appGroupDisplayName(for: $0.container), path: normalizedPath($0.container))
        }
        values += airlift.appGroupContainerPaths.map {
            AirliftContainerResult(label: airlift.appGroupDisplayName(for: $0.container), path: normalizedPath($0.container))
        }
        var seen = Set<String>()
        return values
            .filter { seen.insert($0.path).inserted }
            .filter { matchesSearch(label: $0.label, path: $0.path) }
            .sorted { $0.label == $1.label ? $0.path < $1.path : $0.label < $1.label }
    }

    private var specialMetadataPaths: [AirliftAdditionalContainerPath] {
        switch selectedCategory {
        case .daemons: return airlift.installationProxyInternalDaemonPaths
        case .plugins: return airlift.installationProxyPluginKitPluginPaths
        default: return []
        }
    }

    private var specialAfcPaths: [String] {
        switch selectedCategory {
        case .daemons: return airlift.internalDaemonAfcPaths
        case .plugins: return airlift.pluginKitPluginAfcPaths
        default: return []
        }
    }

    private var specialBadQueryPaths: [String] {
        switch selectedCategory {
        case .daemons: return airlift.internalDaemonBadQueryPaths
        case .plugins: return airlift.pluginKitPluginBadQueryPaths
        default: return []
        }
    }

    private var specialPaths: [String] {
        Array(Set(specialMetadataPaths.map { normalizedPath($0.path) }
            + specialAfcPaths.map(normalizedPath)
            + specialBadQueryPaths.map(normalizedPath))).sorted()
    }

    private var specialPathSignature: String {
        guard selectedCategory == .daemons || selectedCategory == .plugins else { return "" }
        let metadata = specialMetadataPaths.map {
            "\(normalizedPath($0.path))=>\($0.sourceApps.sorted().joined(separator: ","))"
        }.sorted().joined(separator: "\n")
        return specialPaths.joined(separator: "\n") + "\n--metadata--\n" + metadata
    }

    private func displayBundleID(for rawPath: String) -> String {
        let path = normalizedPath(rawPath)
        let leaf = URL(fileURLWithPath: path).lastPathComponent

        if let resolved = resolvedBundleIDs[path], !resolved.isEmpty, UUID(uuidString: resolved) == nil {
            return resolved
        }
        if let metadata = specialMetadataPaths.first(where: { normalizedPath($0.path) == path }),
           let sourceApp = metadata.sourceApps.first(where: { !$0.isEmpty }) {
            return sourceApp
        }

        let rootToken = selectedCategory == .daemons ? "/InternalDaemon/" : "/PluginKitPlugin/"
        if let metadata = specialMetadataPaths.first(where: {
            let candidate = normalizedPath($0.path)
            return candidate.contains(rootToken) && URL(fileURLWithPath: candidate).lastPathComponent == leaf
        }), let sourceApp = metadata.sourceApps.first(where: { !$0.isEmpty }) {
            return sourceApp
        }
        return "?"
    }

    private var specialResults: [AirliftContainerResult] {
        specialPaths
            .map { AirliftContainerResult(label: displayBundleID(for: $0), path: $0) }
            .filter { matchesSearch(label: $0.label, path: $0.path) }
            .sorted { $0.label == $1.label ? $0.path < $1.path : $0.label < $1.label }
    }

    private var visibleResults: [AirliftContainerResult] {
        switch selectedCategory {
        case .applications: return applicationResults
        case .appGroups: return appGroupResults
        case .daemons, .plugins: return specialResults
        }
    }

    private var totalResults: Int {
        switch selectedCategory {
        case .applications:
            return airlift.installedAppContainers.filter {
                let path = normalizedPath($0.container)
                return path.hasPrefix("/var/mobile/Containers/Data/Application/")
                    || path.hasPrefix("/var/containers/Data/Application/")
            }.count
        case .appGroups:
            return Set(airlift.installedAppGroups.map { normalizedPath($0.container) }
                + airlift.appGroupAfcContainerPaths.map { normalizedPath($0.container) }
                + airlift.appGroupContainerPaths.map { normalizedPath($0.container) }).count
        case .daemons, .plugins: return specialPaths.count
        }
    }

    private var selectedLogs: [String] {
        switch selectedCategory {
        case .applications:
            return airlift.appScanLog
        case .appGroups:
            return mergedLogs(airlift.appGroupAfcScanLog, airlift.appGroupBadQueryScanLog)
        case .daemons:
            return mergedLogs(
                airlift.additionalContainerAfcLog(for: "/var/mobile/Containers/Data/InternalDaemon"),
                airlift.additionalContainerBadQueryLog(for: "/var/mobile/Containers/Data/InternalDaemon")
            )
        case .plugins:
            return mergedLogs(
                airlift.additionalContainerAfcLog(for: "/var/mobile/Containers/Data/PluginKitPlugin"),
                airlift.additionalContainerBadQueryLog(for: "/var/mobile/Containers/Data/PluginKitPlugin")
            )
        }
    }

    private func mergedLogs(_ first: [String], _ second: [String]) -> [String] {
        var result: [String] = []
        for line in first + second where !result.contains(line) { result.append(line) }
        return result
    }

    private var categoryScanRunning: Bool {
        switch selectedCategory {
        case .applications: return airlift.appScanRunning
        case .appGroups: return airlift.appGroupAfcScanRunning || airlift.appGroupBadQueryScanRunning
        case .daemons: return airlift.internalDaemonAfcProbeRunning || airlift.internalDaemonBadQueryRunning
        case .plugins: return airlift.pluginKitPluginAfcProbeRunning || airlift.pluginKitPluginBadQueryRunning
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Container type", selection: $selectedCategory) {
                    ForEach(AirliftContainerCategory.allCases) { category in
                        Text(category.title).tag(category)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Container type")
                    .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                TextField("Search bundle ID or path…", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                HStack {
                    Text("Results")
                    Spacer()
                    Text("\(visibleResults.count)/\(totalResults)")
                        .foregroundStyle(.secondary)
                    if categoryScanRunning { ProgressView().controlSize(.small) }
                }
            }

            Section {
                if visibleResults.isEmpty {
                    ContentUnavailableView(
                        categoryScanRunning ? "Scanning…" : "No matching containers",
                        systemImage: categoryScanRunning ? "arrow.triangle.2.circlepath" : selectedCategory.symbol
                    )
                } else {
                    ForEach(visibleResults) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.label)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                            Text(result.path)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .textSelection(.enabled)
                    }
                }
            } header: {
                Label(selectedCategory.title, systemImage: selectedCategory.symbol)
            }

            Section {
                ScrollView(.vertical, showsIndicators: false) {
                    Text(selectedLogs.isEmpty ? "No output yet." : selectedLogs.joined(separator: "\n"))
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                }
                .modifier(TerminalPlatter())
                .clipShape(RoundedRectangle(cornerRadius: terminalRad))
                .contextMenu {
                    Button {
                        Haptic.shared.play(.soft)
                        UIPasteboard.general.string = selectedLogs.joined(separator: "\n")
                    } label: {
                        Label("Copy Output", systemImage: "doc.on.doc")
                    }
                    Button {
                        exportSelectedLogs()
                    } label: {
                        Label("Export Logs", systemImage: "square.and.arrow.up")
                    }
                }
            } header: {
                HeaderLabel("Logs", symbol: "apple.terminal")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Containers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    airlift.rescanAllContainers()
                } label: {
                    if airlift.containerScansRunning {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.2.circlepath")
                    }
                }
                .disabled(airlift.containerScansRunning)
                .accessibilityLabel("Rescan all containers")
            }
        }
        .onChange(of: selectedCategory) { _, _ in
            search = ""
            resolveBundleIdentifiersForCurrentCategory()
        }
        .onChange(of: specialPathSignature) { _, _ in
            resolveBundleIdentifiersForCurrentCategory()
        }
        .onAppear {
            resolveBundleIdentifiersForCurrentCategory()
        }
    }

    private func matchesSearch(label: String, path: String) -> Bool {
        normalizedSearch.isEmpty
            || label.lowercased().contains(normalizedSearch)
            || path.lowercased().contains(normalizedSearch)
    }

    private func resolveBundleIdentifiersForCurrentCategory() {
        guard selectedCategory == .daemons || selectedCategory == .plugins else { return }
        var pending: [(key: String, path: String)] = []
        for path in specialPaths {
            let key = normalizedPath(path)
            guard bundleIDLookupResults[key] == nil,
                  !bundleIDResolutionStarted.contains(key) else { continue }
            bundleIDResolutionStarted.insert(key)
            pending.append((key, path))
        }
        guard !pending.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async {
            var results: [String: FolderLabelDiagnostic] = [:]
            for item in pending {
                results[item.key] = diagnoseFolderLabel(url: URL(fileURLWithPath: item.path))
            }
            DispatchQueue.main.async {
                for (path, result) in results {
                    self.bundleIDLookupResults[path] = result
                    if let rawIdentifier = result.identifier {
                        let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !identifier.isEmpty, UUID(uuidString: identifier) == nil {
                            self.resolvedBundleIDs[path] = identifier
                        }
                    }
                }
            }
        }
    }

    private func exportSelectedLogs() {
        do {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd-yyyy-HHmmss"
            let date = formatter.string(from: Date())
            let tempURL = URL.temporaryDirectory
                .appendingPathComponent("Airlift-Containers-Log-\(date)")
                .appendingPathExtension("txt")
            try Data(selectedLogs.joined(separator: "\n").utf8).write(to: tempURL)
            presentShareSheet(with: tempURL)
        } catch {
            print("(airlift containers) failed to export logs: \(error.localizedDescription)")
        }
    }
}
