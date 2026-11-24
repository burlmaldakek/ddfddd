import SwiftUI

struct AirliftAppContainersView: View {
    @EnvironmentObject private var airlift: AirliftBridge
    @State private var search = ""

    private var filteredApps: [AirliftAppContainer] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return airlift.installedAppContainers }
        return airlift.installedAppContainers.filter {
            $0.bundleID.lowercased().contains(query) || $0.container.lowercased().contains(query)
        }
    }

    var body: some View {
        List {
            Section {
                TextField("Search bundle ID or path…", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    Text("Results")
                    Spacer()
                    Text("\(filteredApps.count)/\(airlift.installedAppContainers.count)")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Find an app", systemImage: "magnifyingglass")
            }

            Section {
                if filteredApps.isEmpty {
                    ContentUnavailableView(
                        airlift.appScanRunning ? "Scanning…" : "No matching apps",
                        systemImage: airlift.appScanRunning ? "arrow.triangle.2.circlepath" : "app.badge"
                    )
                } else {
                    ForEach(filteredApps) { app in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.bundleID).font(.system(size: 13, weight: .medium, design: .monospaced))
                            Text(app.container).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        .textSelection(.enabled)
                    }
                }
            } header: {
                Label("Application Containers", systemImage: "square.stack.3d.up")
            }

            Section {
                ScrollView {
                    Text(airlift.appScanLog.isEmpty ? "No scan output yet." : airlift.appScanLog.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 120, maxHeight: 240)
            } header: {
                Label("App Scan Log", systemImage: "doc.text")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Application Containers")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { airlift.maybeAutoScanInstalledAppContainers() }
    }
}
