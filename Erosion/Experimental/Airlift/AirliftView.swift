import SwiftUI
import UIKit
import Combine
import QuickLook
import UniformTypeIdentifiers

struct PairingExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct AirliftView: View {
    @EnvironmentObject var airlift: AirliftBridge
    @AppStorage("airlift.fullScreenViewing") private var fullScreenViewing = false
    // Network state is sampled once the screen appears. Initializing these values
    // with three independent getifaddrs scans was needless synchronous work while
    // SwiftUI was constructing navigation destinations.
    @State private var loopbackVPNUp = false
    @State private var tunnelIP: String? = nil
    @State private var deviceIP: String? = nil
    @State private var isVisible = false
    @State private var networkRefreshInProgress = false
    @State private var pairingCheckInProgress = false
    @State private var pairingCheckPending = false
    @State private var pairingAvailable = AirliftView.hasCachedPairingFile()
    @State private var pairedTick = 0
    @State private var showPairingImporter = false
    @State private var showPairingInstructions = false
    @State private var pairingRefreshTick = 0
    @State private var lastObservedPairPIN: String? = nil
    @State private var deletingRemoteTarget = false
    @State private var directReadQuickLookURL: URL? = nil

    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    // PairingController's PIN is a plain property rather than @Published.
    // Poll it for UI display while pairing so the toolbar title cannot miss a short PIN update.
    private let pairingTicker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            pairingSection
            connectionSection
            statusSection
            targetSection
            readSection
            logSection
            settingsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Airlift")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isPaired {
                    Menu {
                        Button {
                            runAirliftProbe()
                        } label: {
                            Label("Run Airlift", systemImage: "antenna.radiowaves.left.and.right")
                        }
                        .disabled(airlift.state == .running)

                        NavigationLink {
                            AirliftSettingsView()
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }

                        Divider()

                        Button(role: .destructive) {
                            guard !airlift.readRunning && !deletingRemoteTarget else { return }
                            airlift.clearLog()
                            airlift.clearReadState()
                        } label: {
                            Label("Clear Everything", systemImage: "xmark")
                        }
                        .disabled(airlift.readRunning || deletingRemoteTarget)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                } else {
                    Button(pairButtonTitle, role: .adaptiveConfirm) {
                        if isPairing {
                            airlift.cancelPairing()
                            lastObservedPairPIN = nil
                            pairedTick &+= 1
                        } else {
                            airlift.runPairing()
                            showPairingInstructions = true
                        }
                    }
                    // iOS 26 imports pairing files manually; keep Pair disabled there.
                    // iOS 27 retains its original Pair behavior.
                    .disabled(isIOS26())
                    .accessibilityLabel(pairButtonTitle)
                }
            }
        }
        .alert("Pairing…", isPresented: $showPairingInstructions) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Go to Settings —> Privacy & Security —> Developer Mode —> Pair with Erosion")
        }
        .onAppear {
            isVisible = true
            refresh()
            refreshPairingAvailability()
            pairedTick &+= 1
            // No InstallationProxy, AFC, or inode-walking scan is started merely
            // by opening Airlift. The existing explicit scan actions remain intact.
        }
        .onDisappear {
            isVisible = false
        }
        .onReceive(ticker) { _ in
            // NavigationLink destinations may be constructed before they are shown.
            // Do not poll interfaces or trigger scans while the Airlift screen is hidden.
            guard isVisible else { return }
            refresh()
        }
        .onReceive(pairingTicker) { _ in
            guard isVisible, isPairing else { return }
            let currentPIN = PairingController.shared.pairingPIN ?? airlift.pairPIN
            guard currentPIN != lastObservedPairPIN else { return }
            lastObservedPairPIN = currentPIN
            pairingRefreshTick &+= 1
        }
        .onChange(of: airlift.state) { _, _ in
            pairedTick &+= 1
            refreshPairingAvailability()
        }
        .refreshable { refresh(); pairedTick &+= 1 }
        .sheet(isPresented: Binding(
            get: { airlift.showReadView && !fullScreenViewing && !readFileNeedsDirectQuickLook },
            set: { isPresented in
                if !isPresented { airlift.showReadView = false }
            }
        )) {
            NavigationStack { readViewContent }
                .environmentObject(airlift)
        }
        .navigationDestination(isPresented: Binding(
            get: { airlift.showReadView && fullScreenViewing },
            set: { isPresented in
                if !isPresented { airlift.showReadView = false }
            }
        )) {
            readViewContent
                .environmentObject(airlift)
        }
        .onChange(of: airlift.showReadView) { _, isPresented in
            guard isPresented, !fullScreenViewing, readFileNeedsDirectQuickLook,
                  let local = airlift.readViewLocalPath else { return }
            let url = URL(fileURLWithPath: local)
            // Do not present Quick Look from inside the Airlift sheet: that creates
            // an empty intermediate sheet on iOS. Dismiss the read flag and present
            // the system preview directly from this screen instead.
            airlift.showReadView = false
            Task { @MainActor in
                await Task.yield()
                directReadQuickLookURL = url
            }
        }
        .quickLookPreview($directReadQuickLookURL)
        .fileImporter(
            isPresented: $showPairingImporter,
            allowedContentTypes: [.propertyList, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    airlift.importPairingFile(from: url)
                    refreshPairingAvailability()
                    pairedTick &+= 1
                }
            case .failure(let error):
                airlift.importPairingFileError(error)
            }
        }
    }

    private var readActionsUnavailable: Bool {
        airlift.readRunning || deletingRemoteTarget
    }

    private func startRead() {
        if airlift.readKind == .file {
            airlift.readRemoteFile()
        } else {
            airlift.readRemoteFolder()
        }
    }

    private func runAirliftProbe() {
        guard airlift.state != .running else { return }
        pairingAvailable = true
        // Keep the probe target fixed and omit detailed exploit logs so no target path
        // is exposed in either Airlift's log panel or Home → Logs.
        airlift.target = "/etc/var"
        airlift.runExploit(logDetails: false) { succeeded in
            airlift.appendLog(succeeded ? "[exploit] Airlift completed" : "[exploit] Airlift failed")
        }
    }

    private var readViewContent: some View {
        Group {
            if let local = airlift.readViewLocalPath {
                if airlift.readViewIsFolder {
                    FileBrowserView(
                        path: URL(fileURLWithPath: local, isDirectory: true),
                        readOnly: false,
                        navigationTitleOverride: URL(fileURLWithPath: airlift.readViewRemotePath ?? local).lastPathComponent,
                        airliftRemoteRoot: airlift.readViewRemotePath,
                        airliftLocalRoot: local
                    )
                } else {
                    AirliftReadFileView(
                        localURL: URL(fileURLWithPath: local),
                        remotePath: airlift.readViewRemotePath ?? airlift.readTarget
                    )
                }
            } else {
                ContentUnavailableView("No read snapshot", systemImage: "doc.questionmark")
            }
        }
    }

    private func confirmDeleteRemoteTarget() {
        let target = airlift.readTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard target.hasPrefix("/"), URL(fileURLWithPath: target).standardizedFileURL.path != "/" else {
            Alertinator.shared.alert(title: "Invalid Path", body: "Enter an absolute remote file or directory path other than '/'.")
            return
        }

        let kind = airlift.readKind
        let objectName = kind == .folder ? "directory" : "file"
        Alertinator.shared.alert(
            title: "Delete this \(objectName)?",
            body: "This permanently deletes the selected remote \(objectName) at \(target). This action cannot be undone.",
            actionLabel: "Confirm",
            actionStyle: .destructive,
            action: { deleteRemoteTarget(at: target, kind: kind) }
        )
    }

    private func deleteRemoteTarget(at target: String, kind: AirliftBridge.ReadKind) {
        deletingRemoteTarget = true
        Task { @MainActor in
            let succeeded = await airlift.removeRemotePath(target)
            deletingRemoteTarget = false

            let objectName = kind == .folder ? "directory" : "file"
            if succeeded {
                let normalizedPath = URL(fileURLWithPath: target).standardizedFileURL.path
                let isExpectedUserPath = normalizedPath == "/var/mobile"
                    || normalizedPath.hasPrefix("/var/mobile/")
                    || normalizedPath == "/var/tmp"
                    || normalizedPath.hasPrefix("/var/tmp/")
                let qualifier = isExpectedUserPath ? "" : " (?)"
                Alertinator.shared.alert(
                    title: "Successfully deleted",
                    body: "The \(objectName) \(target) was successfully deleted.\(qualifier)"
                )
            } else {
                Alertinator.shared.alert(
                    title: "Failed to delete remote target",
                    body: "The \(objectName) could not be deleted. Check Airlift → Logs for details."
                )
            }
        }
    }

    private var pairingSection: some View {
        Section {
            Button {
                showPairingImporter = true
            } label: {
                HStack {
                    Text("Import Pairing")
                        .foregroundStyle(isPaired ? Color.secondary : Color.orange)
                    Spacer()
                    if isPaired {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.green)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isPaired)

            Button(role: .destructive) {
                airlift.deletePairing()
                pairingAvailable = false
                refreshPairingAvailability()
                pairedTick &+= 1
            } label: {
                Text("Delete Pairing")
            }
            .disabled(!isPaired)
        } header: {
            HeaderLabel("Pairing", symbol: "doc.text")
        }
    }

    private var connectionSection: some View {
        Section {
            HStack {
                if loopbackVPNUp, let connectedIP = tunnelIP ?? deviceIP {
                    Text(connectedIP)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.green)
                    Spacer()
                    Image(systemName: "checkmark")
                        .foregroundStyle(.green)
                } else {
                    Text("\u{2014}")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        } header: {
            HeaderLabel("Connection", symbol: "link.circle")
        }
    }

    private var statusSection: some View {
        Section {
            HStack {
                Text("Read")
                Spacer()
                Text(airlift.lastReadSucceeded.map { $0 ? "success" : "failed" } ?? "unknown")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(
                        airlift.lastReadSucceeded.map { $0 ? Color.green : Color.red } ?? Color.secondary
                    )
            }

            if airlift.lastReadSucceeded == true, let fileCount = airlift.lastReadFileCount {
                HStack {
                    Text("Files")
                    Spacer()
                    Text(String(fileCount))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.primary)
                }
            }

            if airlift.lastReadSucceeded == true, let totalSize = airlift.lastReadTotalSize {
                HStack {
                    Text("Size")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.primary)
                }
            }
        } header: {
            HeaderLabel("Read Info", symbol: "info.circle")
        }
    }

    private var targetSection: some View {
        Section {
            TextField("Path", text: $airlift.readTarget)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            HStack(spacing: 12) {
                Text("Object")
                Spacer(minLength: 8)
                Picker("Object", selection: $airlift.readKind) {
                    ForEach(AirliftBridge.ReadKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        } header: {
            HeaderLabel("Target", symbol: "scope")
        }
    }

    private var readSection: some View {
        Section {
            Button {
                startRead()
            } label: {
                HStack {
                    Text(airlift.readRunning ? "Reading…" : "Read")
                    Spacer()
                    if airlift.readRunning { ProgressView() }
                }
            }
            .disabled(readActionsUnavailable || !loopbackVPNUp || !isPaired)

            Button(role: .destructive) {
                confirmDeleteRemoteTarget()
            } label: {
                HStack {
                    Text(deletingRemoteTarget ? "Deleting…" : "Delete")
                    Spacer()
                    if deletingRemoteTarget { ProgressView().controlSize(.small) }
                }
            }
            .tint(.red)
            .disabled(deletingRemoteTarget || airlift.readRunning || !loopbackVPNUp || !isPaired)

            if let path = airlift.readExportPath, FileManager.default.fileExists(atPath: path) {
                Button { airlift.openReadView() } label: {
                    Text("View")
                }
                .disabled(readActionsUnavailable)

                ShareLink(item: URL(fileURLWithPath: path)) {
                    Text("Export")
                }
                .disabled(readActionsUnavailable)
            } else {
                Button("View") { }
                    .disabled(true)
                Button("Export") { }
                    .disabled(true)
            }

        } header: {
            HeaderLabel("Actions", symbol: "bolt.fill")
        }
    }

    private var logSection: some View {
        Section {
            ScrollView(showsIndicators: false) {
                Text(airlift.exploitLog.isEmpty
                     ? "No output yet."
                     : airlift.exploitLog.joined(separator: "\n"))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer().id(0)
            }
            // Give the log text about 5% more usable width without changing the platter width.
            .padding(.horizontal, 6)
            .padding(.top, 18)
            .padding(.bottom, 14)
            // About 10% taller than the previous 270 pt Airlift log area.
            .frame(height: 297)
            .padding(.horizontal)
            .background(Color(.quaternarySystemFill), in: .rect(cornerRadius: logPlatterRad))
        .contextMenu {
                Button {
                    Haptic.shared.play(.soft)
                    UIPasteboard.general.string = airlift.exploitLog.joined(separator: "\n")
                } label: {
                    Label("Copy Output", systemImage: "doc.on.doc")
                }

                Button {
                    do {
                        let formatter = DateFormatter()
                        formatter.dateFormat = "MM-dd-yyyy-HHmmss"
                        let date = formatter.string(from: Date())
                        let tempURL = URL.temporaryDirectory
                            .appendingPathComponent("Airlift-Log-\(date)")
                            .appendingPathExtension("txt")
                        let logData = Data(airlift.exploitLog.joined(separator: "\n").utf8)
                        try logData.write(to: tempURL)
                        presentShareSheet(with: tempURL)
                    } catch {
                        print("(airlift) failed to export logs: \(error.localizedDescription)")
                    }
                } label: {
                    Label("Export Logs", systemImage: "square.and.arrow.up")
                }
            }
        } header: {
            HeaderLabel("Logs", symbol: "apple.terminal")
        }
    }

    private var settingsSection: some View {
        Section {
            Button(role: .destructive) {
                airlift.clearLog()
            } label: {
                Text("Clear Logs")
                    .foregroundStyle(.red)
            }
        } header: {
            HeaderLabel("Settings", symbol: "gearshape")
        }
    }

    private func refresh() {
        // Interface enumeration is synchronous at the POSIX layer. Keep it off
        // the main thread and allow only one request at a time so timer ticks or
        // pull-to-refresh cannot queue overlapping getifaddrs walks.
        guard isVisible, !networkRefreshInProgress else { return }
        networkRefreshInProgress = true

        Task { @MainActor in
            let status = await Task.detached(priority: .utility) {
                let pairs = NetworkStatus.tunnelPairs()
                return (
                    vpn: !pairs.isEmpty,
                    tunnelIP: pairs.first(where: { $0.peer != nil })?.peer,
                    deviceIP: pairs.first?.local
                )
            }.value

            networkRefreshInProgress = false
            guard isVisible else { return }
            if loopbackVPNUp != status.vpn { loopbackVPNUp = status.vpn }
            if tunnelIP != status.tunnelIP { tunnelIP = status.tunnelIP }
            if deviceIP != status.deviceIP { deviceIP = status.deviceIP }
        }
    }

    /// Pairing recovery may enumerate Documents and validate candidate plist files
    /// when the canonical pairing is absent. Never run that filesystem work from
    /// SwiftUI's computed body properties or the main thread.
    @MainActor
    private func refreshPairingAvailability() {
        if pairingCheckInProgress {
            pairingCheckPending = true
            return
        }
        pairingCheckInProgress = true
        pairingCheckPending = false

        Task { @MainActor in
            let available = await Task.detached(priority: .utility) {
                AirliftBridge.shared.hasPairing()
            }.value
            pairingAvailable = available
            pairingCheckInProgress = false

            // If pairing changed while a check was in flight, do one fresh pass
            // instead of allowing an older result to remain on screen.
            if pairingCheckPending {
                pairingCheckPending = false
                refreshPairingAvailability()
            }
        }
    }

    private var isPaired: Bool {
        _ = pairedTick
        if case .ready = airlift.state { return true }
        return pairingAvailable
    }

    /// A pairing file is persisted only after successful import or pairing.
    /// Check the canonical/remembered file directly for the initial toolbar state;
    /// unlike pairingFilePath(), this does not enumerate Documents or recover plists.
    private static func hasCachedPairingFile() -> Bool {
        let fileManager = FileManager.default
        var candidates: [String] = []
        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            candidates.append(documents.appendingPathComponent("erosion_pairing.plist").path)
        }
        if let remembered = UserDefaults.standard.string(forKey: "erosionPairingActiveFilePath"),
           !remembered.isEmpty {
            candidates.append(remembered)
        }

        for path in Set(candidates) {
            guard fileManager.fileExists(atPath: path),
                  let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let size = (attributes[.size] as? NSNumber)?.intValue,
                  size > 0 else { continue }
            return true
        }
        return false
    }

    private var isPairing: Bool {
        if case .pairing = airlift.state { return true }
        return false
    }


    private var livePairPIN: String? {
        _ = pairingRefreshTick
        // Read the controller directly as a fallback: the bridge mirrors its PIN
        // asynchronously, and can otherwise miss the brief update between polls.
        return PairingController.shared.pairingPIN ?? airlift.pairPIN
    }

    private var hasLivePairPIN: Bool {
        guard let pin = livePairPIN else { return false }
        return !pin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var readFileNeedsDirectQuickLook: Bool {
        guard !airlift.readViewIsFolder,
              let local = airlift.readViewLocalPath else { return false }
        return !AirliftReadFileView.hasBuiltInViewer(for: URL(fileURLWithPath: local))
    }

    private var pairButtonTitle: String {
        if isPaired { return "Paired" }
        if isPairing {
            return hasLivePairPIN ? (livePairPIN ?? "Pairing…") : "Pairing…"
        }
        return "Pair"
    }

}


private struct AirliftSettingsView: View {
    @AppStorage("airlift.fullScreenViewing") private var fullScreenViewing = false
    @AppStorage("airlift.saveReadResults") private var saveReadResults = true
    @AppStorage("airlift.shorterLogs") private var shorterLogs = false
    @State private var dataOperationRunning = false
    @State private var isPreparingPairingExport = false
    @State private var shareItem: PairingExportItem?

    var body: some View {
        List {
            Section {
                Toggle("Full Screen Viewing", isOn: $fullScreenViewing)
                Toggle("Save Read Results", isOn: $saveReadResults)
                Toggle("Shorter Logs", isOn: $shorterLogs)
            } header: {
                HeaderLabel("Read", symbol: "doc.text")
            }

            Section {
                if !isIOS272Beta3OrLater() {
                    Button {
                        preparePairingExport()
                    } label: {
                        Text("Export Pairing File")
                            .foregroundStyle(Color.orange)
                    }
                    // The action guards its own in-flight state so the native
                    // Erosion button text never dims while the file is prepared.
                }

                Button {
                    guard !dataOperationRunning else { return }
                    dataOperationRunning = true
                    Task {
                        let result = await Task.detached(priority: .utility) {
                            Result { try AirliftBridge.exportTemporaryDirectory() }
                        }.value
                        dataOperationRunning = false
                        switch result {
                        case .success(let url):
                            presentShareSheet(with: url)
                        case .failure(let error):
                            Alertinator.shared.alert(title: "Export failed", body: error.localizedDescription)
                        }
                    }
                } label: {
                    Text("Export Data")
                        .foregroundStyle(Color.orange)
                }

                Button(role: .destructive) {
                    guard !dataOperationRunning else { return }
                    dataOperationRunning = true
                    Task {
                        let result = await Task.detached(priority: .utility) {
                            AirliftBridge.clearTemporaryDirectoryContents()
                        }.value
                        dataOperationRunning = false
                        AirliftBridge.shared.clearReadSnapshotState()
                        Alertinator.shared.alert(
                            title: "Cleared",
                            body: result.failures.isEmpty
                                ? "Removed \(result.removedObjects) objects."
                                : "Removed \(result.removedObjects) objects.\n\nSome items could not be removed:\n\(result.failures.joined(separator: "\n"))"
                        )
                    }
                } label: {
                    Text("Clear Data")
                        .foregroundStyle(.red)
                }
                .disabled(dataOperationRunning)
            } header: {
                HeaderLabel("Data", symbol: "loupe")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareItem, onDismiss: cleanupShareItem) { item in
            AirliftActivitySheet(items: [item.url])
        }
    }

    private func preparePairingExport() {
        guard !isPreparingPairingExport else { return }
        isPreparingPairingExport = true

        Task { @MainActor in
            let activePath = await Task.detached(priority: .utility) { () -> String? in
                let path = AirliftBridge.shared.pairingFilePath()
                let url = URL(fileURLWithPath: path).standardizedFileURL
                guard FileManager.default.fileExists(atPath: url.path),
                      FileManager.default.isReadableFile(atPath: url.path),
                      let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                      !data.isEmpty else { return nil }
                return url.path
            }.value

            isPreparingPairingExport = false
            guard let activePath else {
                Alertinator.shared.alert(
                    title: "Export Pairing unavailable",
                    body: "Airlift's active pairing file is missing or unreadable. Import or create a pairing first."
                )
                return
            }

            PairingController.customPairingFilePath = activePath
            UserDefaults.standard.set(activePath, forKey: "erosionPairingActiveFilePath")
            shareItem = PairingExportItem(url: URL(fileURLWithPath: activePath))
        }
    }

    private func cleanupShareItem() {
        shareItem = nil
    }
}

private struct AirliftReadFileView: View {
    let localURL: URL
    let remotePath: String

    private static let filePreviewExtensions: Set<String> = [
        "dylib", "bin", "so", "o", "deb", "png", "jpg", "jpeg", "heic", "heif",
        "tif", "tiff", "gif", "webp", "svg", "car", "mp4", "mov", "m4v",
        "mp3", "m4a", "wav", "aiff", "aif", "caf", "flac", "aac"
    ]

    static func hasBuiltInViewer(for url: URL) -> Bool {
        filePreviewExtensions.contains(url.pathExtension.lowercased())
            || conformsToPlistViewer(url)
            || conformsToTextViewer(url)
    }

    var body: some View {
        Group {
            let ext = localURL.pathExtension.lowercased()
            if Self.filePreviewExtensions.contains(ext) {
                FilePreviewView(url: localURL, remotePath: remotePath, remoteWritable: false)
            } else if conformsToPlistViewer(localURL) {
                PlistViewer(localURL, remotePath: remotePath)
            } else if conformsToTextViewer(localURL) {
                TextViewer(localURL, remotePath: remotePath)
            } else {
                QuickLookDirectPreview(url: localURL)
            }
        }
    }
}


struct AirliftActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}
