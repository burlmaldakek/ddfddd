import SwiftUI

struct AirliftAppGroupContainersView: View {
    @EnvironmentObject private var airlift: AirliftBridge
    @State private var search = ""

    private var rows: [(label: String, path: String)] {
        var values: [(label: String, path: String)] = airlift.installedAppGroups.map { group in
            (label: group.groupIDs.first ?? "Group identifier unavailable", path: group.container)
        }
        values += airlift.appGroupAfcContainerPaths.map { (label: airlift.appGroupDisplayName(for: $0.container), path: $0.container) }
        values += airlift.appGroupContainerPaths.map { (label: airlift.appGroupDisplayName(for: $0.container), path: $0.container) }
        var seen = Set<String>(); values = values.filter { seen.insert($0.path).inserted }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return values.filter { q.isEmpty || $0.label.lowercased().contains(q) || $0.path.lowercased().contains(q) }.sorted { $0.label < $1.label }
    }

    var body: some View {
        List {
            Section {
                TextField("Search bundle ID or path…", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                HStack { Text("Results"); Spacer(); Text("\(rows.count)/\(totalCount)").foregroundStyle(.secondary) }
            } header: { Label("Find a group", systemImage: "magnifyingglass") }
            Section {
                if rows.isEmpty { ContentUnavailableView("No matching containers", systemImage: "person.2") }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.label).font(.system(size: 13, weight: .medium, design: .monospaced))
                        Text(row.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }.textSelection(.enabled)
                }
            } header: { Label("App Group Containers", systemImage: "person.2") }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("bad_query").font(.headline)
                    Text(airlift.appGroupBadQueryScanLog.isEmpty ? "bad_query scan has not completed yet." : airlift.appGroupBadQueryScanLog.joined(separator: "\n"))
                    Text("AFC").font(.headline)
                    Text(airlift.appGroupAfcScanLog.isEmpty ? "AFC listing has not completed yet." : airlift.appGroupAfcScanLog.joined(separator: "\n"))
                }
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
            } header: { Label("Automatic Scan Log", systemImage: "doc.text") }
        }
        .listStyle(.insetGrouped).navigationTitle("App Group Containers").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            airlift.scanInstalledAppContainers()
            airlift.scanAppGroupContainerPathsViaAirlift()
            airlift.scanAppGroupContainerPaths()
        }
    }
    private var totalCount: Int {
        Set(airlift.installedAppGroups.map(\.container) + airlift.appGroupAfcContainerPaths.map(\.container) + airlift.appGroupContainerPaths.map(\.container)).count
    }
}
import SwiftUI

enum AirliftSpecialContainerKind: Equatable {
    case internalDaemon, pluginKitPlugin
    var title: String { self == .internalDaemon ? "InternalDaemon" : "PluginKitPlugin" }
    var root: String { "/var/mobile/Containers/Data/\(title)" }
}

struct AirliftSpecialContainerView: View {
    @EnvironmentObject private var airlift: AirliftBridge
    let kind: AirliftSpecialContainerKind
    @State private var search = ""
    @State private var resolvedBundleIDs: [String: String] = [:]
    @State private var bundleIDResolutionStarted: Set<String> = []
    @State private var bundleIDLookupResults: [String: FolderLabelDiagnostic] = [:]
    @State private var bundleIDResolutionLog: [String] = []

    private var afcPaths: [String] {
        // PluginKitPlugin is intentionally BadQuery-only; do not use AFC here.
        kind == .internalDaemon ? airlift.internalDaemonAfcPaths : []
    }
    private var badQueryPaths: [String] {
        kind == .internalDaemon ? airlift.internalDaemonBadQueryPaths : airlift.pluginKitPluginBadQueryPaths
    }
    private var allContainerPaths: [String] {
        Array(Set(afcPaths + badQueryPaths)).sorted()
    }
    private var pathsSignature: String {
        allContainerPaths.joined(separator: "\n")
    }

    private func normalizedPath(_ path: String) -> String {
        path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
    }

    private func displayBundleID(for path: String) -> String {
        let normalized = normalizedPath(path)
        // Resolve the container's own MCM metadata. Parent-app identifiers are
        // intentionally not inferred from InstallationProxy for these roots.
        if let resolved = resolvedBundleIDs[normalized], !resolved.isEmpty,
           UUID(uuidString: resolved) == nil {
            return resolved
        }

        return "Bundle identifier unavailable"
    }

    private var rows: [(label: String, path: String)] {
        let values = allContainerPaths.map { (label: displayBundleID(for: $0), path: $0) }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return values.filter { q.isEmpty || $0.label.lowercased().contains(q) || $0.path.lowercased().contains(q) }
            .sorted { $0.label == $1.label ? $0.path < $1.path : $0.label < $1.label }
    }

    private var afcLog: [String] { airlift.additionalContainerAfcLog(for: kind.root) }
    private var badQueryLog: [String] { airlift.additionalContainerBadQueryLog(for: kind.root) }

    var body: some View {
        List {
            Section {
                TextField("Search bundle ID or path…", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                HStack { Text("Results"); Spacer(); Text("\(rows.count)/\(allContainerPaths.count)").foregroundStyle(.secondary) }
            } header: { Label("Find a container", systemImage: "magnifyingglass") }
            Section {
                if rows.isEmpty {
                    ContentUnavailableView("No matching containers", systemImage: "shippingbox")
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.label).font(.system(size: 13, weight: .medium, design: .monospaced))
                        Text(row.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }.textSelection(.enabled)
                }
            } header: { Label(kind.title, systemImage: "shippingbox") }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bundle ID Resolution").font(.headline)
                    ScrollView {
                        Text(bundleIDResolutionLog.isEmpty
                             ? "Bundle ID diagnostics have not completed yet."
                             : bundleIDResolutionLog.joined(separator: "\n"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 210)

                    Text("bad_query").font(.headline)
                    Text(badQueryLog.isEmpty ? "bad_query scan has not completed yet." : badQueryLog.joined(separator: "\n"))
                    if kind == .internalDaemon {
                        Text("AFC").font(.headline)
                        Text(afcLog.isEmpty ? "AFC listing has not completed yet." : afcLog.joined(separator: "\n"))
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
            } header: { Label("Automatic Scan Log", systemImage: "doc.text") }
        }
        .listStyle(.insetGrouped).navigationTitle(kind.title).navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if kind == .internalDaemon {
                airlift.probeAdditionalContainerRootViaAirlift(kind.root)
            }
            airlift.scanAdditionalContainerRootWithBadQuery(kind.root)
            resolveBundleIdentifiersForPaths()
        }
        .onChange(of: pathsSignature) { _, _ in resolveBundleIdentifiersForPaths() }
    }

    /// Resolves each container's own MCM metadata identifier. No InstallationProxy
    /// lookup is used for InternalDaemon or PluginKitPlugin.
    private func resolveBundleIdentifiersForPaths() {
        var pending: [(key: String, path: String)] = []
        for path in allContainerPaths {
            let key = normalizedPath(path)
            guard bundleIDLookupResults[key] == nil,
                  !bundleIDResolutionStarted.contains(key) else { continue }
            bundleIDResolutionStarted.insert(key)
            pending.append((key, path))
        }

        guard !pending.isEmpty else {
            updateBundleIDResolutionLog()
            return
        }
        updateBundleIDResolutionLog()

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
                self.updateBundleIDResolutionLog()
            }
        }
    }

    private func updateBundleIDResolutionLog() {
        var lines: [String] = []
        var mcmIdentifierCount = 0
        var unresolvedCount = 0

        for path in allContainerPaths {
            let key = normalizedPath(path)
            let lookup = bundleIDLookupResults[key]
            let identifier = lookup?.identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let identifier, !identifier.isEmpty, UUID(uuidString: identifier) == nil {
                mcmIdentifierCount += 1
            }
            let usableIdentifier = identifier.flatMap { value -> String? in
                guard !value.isEmpty, UUID(uuidString: value) == nil else { return nil }
                return value
            }
            let displayValue = usableIdentifier ?? "Bundle identifier unavailable"
            if usableIdentifier == nil { unresolvedCount += 1 }
            let mcmValue: String
            if let identifier, !identifier.isEmpty {
                mcmValue = UUID(uuidString: identifier) == nil
                    ? identifier
                    : "\(identifier) (UUID-shaped; not used as Bundle ID)"
            } else {
                mcmValue = lookup == nil ? "pending" : "unavailable"
            }
            let detail = lookup?.detail ?? (bundleIDResolutionStarted.contains(key) ? "metadata lookup pending" : "not scheduled")
            lines.append("[bundle-id] path=\(path) | MCMMetadataIdentifier=\(mcmValue) | lookup=\(detail) | displayed=\(displayValue)")
        }

        let summary = "[bundle-id] SUMMARY: paths=\(allContainerPaths.count), MCM identifier(s) found=\(mcmIdentifierCount), unresolved=\(unresolvedCount)"
        bundleIDResolutionLog = [summary] + lines
    }

    private var totalCount: Int { allContainerPaths.count }
}
