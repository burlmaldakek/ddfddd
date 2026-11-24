import SwiftUI
import UIKit
import ZIPFoundation
import Darwin
import Combine

/// Inverts only static mockup elements in light appearance; live/user artwork is left untouched.
struct LightModeTemplateInversion: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if colorScheme == .light {
            content.colorInvert()
        } else {
            content
        }
    }
}

private enum FindMyImageTarget: Identifiable {
    case deviceSource(String)
    case mapInfoBox(String)
    case tccImage(String)

    var id: String {
        switch self {
        case .deviceSource(let key): return "source:\(key)"
        case .mapInfoBox(let key): return "map:\(key)"
        case .tccImage(let permission): return "tcc:\(permission)"
        }
    }
}

private enum FindMyStatusOption: String, CaseIterable, Identifiable {
    case both = "Both"
    case offline = "Offline"
    case online = "Online"

    var id: String { rawValue }
}

private enum FindMyFileVariant: String, CaseIterable {
    case online
    case offline
}

private enum FindMyAssetKind {
    case sourceList
    case infoBox

    var filenameToken: String {
        switch self {
        case .sourceList: return "sourcelist"
        case .infoBox: return "infobox"
        }
    }

    var cacheToken: String { filenameToken }
}

private struct FindMyPendingWrite {
    let key: String
    let variant: FindMyFileVariant
    let kind: FindMyAssetKind
    let filename: String
    let data: Data
}

private struct FindMyWriteTarget {
    let variant: FindMyFileVariant
    let filename: String
}

private struct FindMyStoredDevice: Codable, Identifiable {
    let deviceKey: String
    let deviceType: String
    let hardwareModel: String

    // Compatibility fields let the v25 manifest continue to load.
    let hasSourceList: Bool
    let hasInfoBox: Bool
    let sourceCacheFile: String?
    let infoCacheFile: String?

    let onlineSourceFilename: String?
    let onlineInfoBoxFilename: String?
    let offlineSourceFilename: String?
    let offlineInfoBoxFilename: String?

    let onlineSourceCacheFile: String?
    let onlineInfoCacheFile: String?
    let offlineSourceCacheFile: String?
    let offlineInfoCacheFile: String?

    var id: String { deviceKey }

    private enum CodingKeys: String, CodingKey {
        case deviceKey, deviceType, hardwareModel
        case hasSourceList, hasInfoBox, sourceCacheFile, infoCacheFile
        case onlineSourceFilename, onlineInfoBoxFilename, offlineSourceFilename, offlineInfoBoxFilename
        case onlineSourceCacheFile, onlineInfoCacheFile, offlineSourceCacheFile, offlineInfoCacheFile
    }

    init(entry: FindMyDeviceEntry) {
        deviceKey = entry.deviceKey
        deviceType = entry.deviceType
        hardwareModel = entry.hardwareModel
        hasSourceList = entry.onlineSourceFilename != nil || entry.offlineSourceFilename != nil
        hasInfoBox = entry.onlineInfoBoxFilename != nil || entry.offlineInfoBoxFilename != nil
        sourceCacheFile = entry.onlineSourceCacheFile ?? entry.offlineSourceCacheFile
        infoCacheFile = entry.onlineInfoCacheFile ?? entry.offlineInfoCacheFile
        onlineSourceFilename = entry.onlineSourceFilename
        onlineInfoBoxFilename = entry.onlineInfoBoxFilename
        offlineSourceFilename = entry.offlineSourceFilename
        offlineInfoBoxFilename = entry.offlineInfoBoxFilename
        onlineSourceCacheFile = entry.onlineSourceCacheFile
        onlineInfoCacheFile = entry.onlineInfoCacheFile
        offlineSourceCacheFile = entry.offlineSourceCacheFile
        offlineInfoCacheFile = entry.offlineInfoCacheFile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key = try container.decode(String.self, forKey: .deviceKey)
        let type = try container.decode(String.self, forKey: .deviceType)
        let model = try container.decode(String.self, forKey: .hardwareModel)
        let legacyHasSource = try container.decodeIfPresent(Bool.self, forKey: .hasSourceList) ?? false
        let legacyHasInfo = try container.decodeIfPresent(Bool.self, forKey: .hasInfoBox) ?? false
        let legacySourceCache = try container.decodeIfPresent(String.self, forKey: .sourceCacheFile)
        let legacyInfoCache = try container.decodeIfPresent(String.self, forKey: .infoCacheFile)

        let hasVariantSchema = container.contains(.onlineSourceFilename)
            || container.contains(.onlineInfoBoxFilename)
            || container.contains(.offlineSourceFilename)
            || container.contains(.offlineInfoBoxFilename)
            || container.contains(.onlineSourceCacheFile)
            || container.contains(.offlineSourceCacheFile)
            || container.contains(.onlineInfoCacheFile)
            || container.contains(.offlineInfoCacheFile)
        let onlineSourceName: String? = hasVariantSchema
            ? try container.decodeIfPresent(String.self, forKey: .onlineSourceFilename)
            : (legacyHasSource ? "\(key)-online-sourcelist__3x.png" : nil)
        let onlineInfoName: String? = hasVariantSchema
            ? try container.decodeIfPresent(String.self, forKey: .onlineInfoBoxFilename)
            : (legacyHasInfo ? "\(key)-online-infobox__3x.png" : nil)
        let offlineSourceName = try container.decodeIfPresent(String.self, forKey: .offlineSourceFilename)
        let offlineInfoName = try container.decodeIfPresent(String.self, forKey: .offlineInfoBoxFilename)
        let onlineSourceCache: String? = hasVariantSchema
            ? try container.decodeIfPresent(String.self, forKey: .onlineSourceCacheFile)
            : (legacyHasSource ? legacySourceCache : nil)
        let onlineInfoCache: String? = hasVariantSchema
            ? try container.decodeIfPresent(String.self, forKey: .onlineInfoCacheFile)
            : (legacyHasInfo ? legacyInfoCache : nil)
        let offlineSourceCache = try container.decodeIfPresent(String.self, forKey: .offlineSourceCacheFile)
        let offlineInfoCache = try container.decodeIfPresent(String.self, forKey: .offlineInfoCacheFile)

        deviceKey = key
        deviceType = type
        hardwareModel = model
        onlineSourceFilename = onlineSourceName
        onlineInfoBoxFilename = onlineInfoName
        offlineSourceFilename = offlineSourceName
        offlineInfoBoxFilename = offlineInfoName
        onlineSourceCacheFile = onlineSourceCache
        onlineInfoCacheFile = onlineInfoCache
        offlineSourceCacheFile = offlineSourceCache
        offlineInfoCacheFile = offlineInfoCache
        hasSourceList = legacyHasSource || onlineSourceName != nil || offlineSourceName != nil
        hasInfoBox = legacyHasInfo || onlineInfoName != nil || offlineInfoName != nil
        sourceCacheFile = try container.decodeIfPresent(String.self, forKey: .sourceCacheFile)
            ?? onlineSourceCache ?? offlineSourceCache
        infoCacheFile = try container.decodeIfPresent(String.self, forKey: .infoCacheFile)
            ?? onlineInfoCache ?? offlineInfoCache
    }
}

private struct FindMyDeviceEntry: Identifiable {
    let deviceKey: String
    let deviceType: String
    let hardwareModel: String

    var onlineSourceFilename: String?
    var onlineInfoBoxFilename: String?
    var offlineSourceFilename: String?
    var offlineInfoBoxFilename: String?

    var onlineSourceCacheFile: String?
    var onlineInfoCacheFile: String?
    var offlineSourceCacheFile: String?
    var offlineInfoCacheFile: String?

    var onlineSourceListData: Data?
    var onlineInfoBoxData: Data?
    var offlineSourceListData: Data?
    var offlineInfoBoxData: Data?
    var isPlaceholder = false

    var id: String { deviceKey }

    func sourceListData(for status: FindMyStatusOption) -> Data? {
        switch status {
        case .both, .online:
            return onlineSourceListData ?? offlineSourceListData
        case .offline:
            return offlineSourceListData ?? onlineSourceListData
        }
    }

    func infoBoxData(for status: FindMyStatusOption) -> Data? {
        switch status {
        case .both, .online:
            return onlineInfoBoxData ?? offlineInfoBoxData
        case .offline:
            return offlineInfoBoxData ?? onlineInfoBoxData
        }
    }

    var storedValue: FindMyStoredDevice { FindMyStoredDevice(entry: self) }
}

private struct FindMyScanRecord {
    var onlineSource: URL?
    var onlineInfoBox: URL?
    var offlineSource: URL?
    var offlineInfoBox: URL?

    mutating func set(_ url: URL, variant: FindMyFileVariant, kind: FindMyAssetKind) {
        switch (variant, kind) {
        case (.online, .sourceList): onlineSource = url
        case (.online, .infoBox): onlineInfoBox = url
        case (.offline, .sourceList): offlineSource = url
        case (.offline, .infoBox): offlineInfoBox = url
        }
    }

}

/// Long-lived in-process state, following the singleton-store pattern used by
/// PasscodeThemeLibraryStore. Files and pending selections are also persisted on disk.
@MainActor
private final class FindMySession: ObservableObject {
    static let shared = FindMySession()

    @Published var devices: [FindMyDeviceEntry] = []
    @Published var selectedDeviceKey = UserDefaults.standard.string(forKey: "findmy.selectedDeviceKey.v1") ?? ""
    @Published var replacementSourceListData: [String: Data] = [:]
    @Published var replacementInfoBoxData: [String: Data] = [:]
    var didRestore = false
    var didAttemptInitialIPadScan = false

    private init() {}
}

struct FindMyView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var airlift: AirliftBridge
    @StateObject private var session = FindMySession.shared
    @StateObject private var tccSession = TCCSession.shared
    @StateObject private var layoutsStore = LayoutsStore.shared
    @AppStorage("erosion.findmy.statusSelection.v1") private var selectedStatusRaw = "Both"
    @AppStorage("erosion.tcc.permissionSelection.v1") private var tccPermissionRaw = "All"

    private static let isTCCSectionVisible = false
    private static let savedDevicesDefaultsKey = "findmy.savedDevices.v1"
    private static let selectedDeviceDefaultsKey = "findmy.selectedDeviceKey.v1"
    private static let deviceManifestFilename = "device-list-v1.json"
    private let devicesPath = "/var/mobile/Library/Caches/com.apple.findmy.imagecache/devices"

    @State private var activePicker: FindMyImageTarget?
    @State private var isScanning = false
    @State private var isApplying = false
    @State private var isResetting = false
    @State private var showApplySuccessAlert = false

    private var shouldShowFindMyControls: Bool {
        UIDevice.current.userInterfaceIdiom != .pad
    }

    private var selectedStatus: FindMyStatusOption {
        FindMyStatusOption(rawValue: selectedStatusRaw) ?? .both
    }

    private var selectedTCCPermission: TCCPermission {
        TCCPermission(rawValue: tccPermissionRaw) ?? .all
    }

    private var hasPendingTCCImage: Bool {
        tccSession.hasPendingImage(for: selectedTCCPermission)
    }

    private var selectedDeviceKey: String {
        get { session.selectedDeviceKey }
        nonmutating set {
            session.selectedDeviceKey = newValue
            UserDefaults.standard.set(newValue, forKey: Self.selectedDeviceDefaultsKey)
        }
    }

    private var devices: [FindMyDeviceEntry] {
        get { session.devices }
        nonmutating set { session.devices = newValue }
    }

    private var replacementSourceListData: [String: Data] {
        get { session.replacementSourceListData }
        nonmutating set { session.replacementSourceListData = newValue }
    }

    private var replacementInfoBoxData: [String: Data] {
        get { session.replacementInfoBoxData }
        nonmutating set { session.replacementInfoBoxData = newValue }
    }

    var body: some View {
        List {
            if shouldShowFindMyControls {
                Section {
                    preview
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 8, trailing: 8))
                        .listRowBackground(Color.clear)
                } header: {
                    HeaderLabel("Find My", symbol: "location.circle.fill")
                }

                Section {
                    Button(isResetting ? "Resetting…" : (isScanning ? "Scanning…" : "Scan")) {
                        scanDevicesFolder()
                    }
                    .disabled(isScanning || isApplying || isResetting)
                    .tint(Color.accentColor)

                    HStack(spacing: 12) {
                        Text("Target")
                        Spacer(minLength: 8)
                        Picker("Target", selection: $selectedStatusRaw) {
                            ForEach(FindMyStatusOption.allCases) { option in
                                Text(option.rawValue).tag(option.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                } header: {
                    HeaderLabel("Settings", symbol: "gearshape")
                }
            }

            // TCC remains implemented and can be shown again by changing this flag.
            if Self.isTCCSectionVisible {
                TCCView(onSelectImage: {
                    let permission = TCCPermission(rawValue: tccPermissionRaw) ?? .all
                    activePicker = .tccImage(permission.rawValue)
                })
            }

            LayoutsView()
                .environment(\.editMode, .constant(.active))

            Section {
                NavigationLink {
                    AppsManagementView()
                } label: {
                    Text("App Decrypt")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .overlay(alignment: .trailing) {
                    Button {
                        Alertinator.shared.alert(
                            title: "Information",
                            body: "This method of App Decrypting is honestly not perfect and may not work properly. Decrypted App Store apps will have FairPlay protection."
                        )
                    } label: {
                        Image(systemName: "info.circle")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 20)
                    .zIndex(1)
                    .accessibilityLabel("App Decrypt information")
                }
            } header: {
                HeaderLabel("Apps", symbol: "square.grid.2x2")
            }

        }
        .listStyle(.insetGrouped)
        .navigationTitle("Other")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isApplying || tccSession.isApplying ? "Applying…" : "Apply", role: .adaptiveConfirm) {
                    Task { await applyPendingChanges() }
                }
                .disabled(
                    isScanning || isApplying || isResetting || tccSession.isApplying || tccSession.isResetting
                        || (!(shouldShowFindMyControls && hasApplicableReplacements) && !hasPendingTCCImage && !layoutsStore.shouldApplyTopLayout)
                )
            }
        }
        .sheet(item: $activePicker) { target in
            ImagePickerView { data in
                switch target {
                case .deviceSource(let key):
                    setPendingSourceReplacement(data, for: key)
                case .mapInfoBox(let key):
                    setPendingInfoBoxReplacement(data, for: key)
                case .tccImage(let permissionRawValue):
                    guard let permission = TCCPermission(rawValue: permissionRawValue) else { return }
                    tccSession.selectCustomImage(data, for: permission)
                }
            }
        }
        .onAppear {
            if shouldShowFindMyControls {
                restoreSavedDevices()
                scanForMissingIPadDeviceImagesIfNeeded()
            }
        }
        .alert("Successfully applied images!", isPresented: $showApplySuccessAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Restart Find My to see changes.")
        }
    }

    private var preview: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let selectedDevice = selectedPreviewDevice
            let localKey = Self.placeholderKey(for: Self.hardwareMachineIdentifier() ?? "Device")
            let markerData = selectedDevice.flatMap {
                replacementInfoBoxData[$0.deviceKey] ?? $0.infoBoxData(for: selectedStatus)
            } ?? replacementInfoBoxData[localKey]

            ZStack {
                Image(colorScheme == .light ? "findmy_preview_light" : "findmy_preview")
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()

                marker(
                    imageData: markerData,
                    diameter: width * 0.18456,
                    visibleOutline: true
                ) {
                    let targetKey = selectedDevice?.deviceKey ?? localKey
                    activePicker = .mapInfoBox(targetKey)
                }
                .position(x: width * 0.5024, y: height * 0.1384)

                deviceRows(width: width, height: height)

            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .contextMenu {
                Button(action: exportAllDeviceImages) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(isScanning || isApplying || isResetting || devices.isEmpty)

                Button(role: .destructive, action: requestResetAllDeviceImages) {
                    Label("Reset", systemImage: "gobackward")
                }
                .disabled(isScanning || isApplying || isResetting)
            }
        }
        .aspectRatio(colorScheme == .light ? (1632.0 / 2582.0) : (1922.0 / 2822.0), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func deviceRows(width: CGFloat, height: CGFloat) -> some View {
        let visibleDevices = displayedDevices
        let rowHeight = width * 0.181
        let diameter = width * 0.113
        let leadingInset = width * 0.029
        let rowSpacing = width * 0.018
        let listWidth = width * 0.94
        let listHeight = height * 0.38
        let trailingInset = width * 0.035

        return ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(visibleDevices) { device in
                    FindMyDeviceRowView(
                        device: device,
                        avatarData: replacementSourceListData[device.deviceKey] ?? device.sourceListData(for: selectedStatus),
                        rowHeight: rowHeight,
                        diameter: diameter,
                        rowSpacing: rowSpacing,
                        showSeparator: device.deviceKey != visibleDevices.last?.deviceKey,
                        isDisabled: isScanning || isApplying || isResetting,
                        onOpenSourcePicker: { openSourcePicker(for: device) },
                        onSelect: { selectDevice(device) }
                    )
                }
            }
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
        }
        .frame(width: listWidth, height: listHeight)
        .clipped()
        .position(x: width * 0.5, y: height * 0.783)
    }

    private func marker(imageData: Data?, diameter: CGFloat, visibleOutline: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color(.tertiarySystemFill))

                if let imageData, let image = UIImage(data: imageData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: diameter * 0.82, height: diameter * 0.82)
                }

                Circle()
                    .stroke(
                        visibleOutline
                            ? (colorScheme == .dark ? Color.white.opacity(0.36) : Color.black.opacity(0.16))
                            : Color.clear,
                        lineWidth: 1.26
                    )
            }
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: diameter, height: diameter)
        .disabled(isScanning || isApplying || isResetting)
    }

    private var displayedDevices: [FindMyDeviceEntry] {
        guard devices.isEmpty else { return devices }
        let machine = Self.hardwareMachineIdentifier() ?? "Device"
        return [FindMyDeviceEntry(
            deviceKey: Self.placeholderKey(for: machine),
            deviceType: "",
            hardwareModel: "",
            onlineSourceFilename: nil,
            onlineInfoBoxFilename: nil,
            offlineSourceFilename: nil,
            offlineInfoBoxFilename: nil,
            onlineSourceCacheFile: nil,
            onlineInfoCacheFile: nil,
            offlineSourceCacheFile: nil,
            offlineInfoCacheFile: nil,
            onlineSourceListData: nil,
            onlineInfoBoxData: nil,
            offlineSourceListData: nil,
            offlineInfoBoxData: nil,
            isPlaceholder: true
        )]
    }

    private var selectedPreviewDevice: FindMyDeviceEntry? {
        devices.first(where: { $0.deviceKey == selectedDeviceKey }) ?? devices.first
    }

    private var hasApplicableReplacements: Bool {
        for key in replacementSourceListData.keys {
            guard let device = devices.first(where: { $0.deviceKey == key }) else { continue }
            if !writeTargets(for: device, kind: .sourceList).isEmpty { return true }
        }
        for key in replacementInfoBoxData.keys {
            guard let device = devices.first(where: { $0.deviceKey == key }) else { continue }
            if !writeTargets(for: device, kind: .infoBox).isEmpty { return true }
        }
        return false
    }

    private func openSourcePicker(for device: FindMyDeviceEntry) {
        guard !isScanning, !isApplying, !isResetting else { return }
        if !device.isPlaceholder {
            selectedDeviceKey = device.deviceKey
        }
        activePicker = .deviceSource(device.deviceKey)
    }

    private func selectDevice(_ device: FindMyDeviceEntry) {
        guard !device.isPlaceholder else { return }
        selectedDeviceKey = device.deviceKey
    }

    private func restoreSavedDevices() {
        guard !session.didRestore else { return }
        session.didRestore = true

        let cacheDirectory = Self.persistentAssetDirectory()
        let manifestURL = cacheDirectory.appendingPathComponent(Self.deviceManifestFilename)
        let fallbackData = UserDefaults.standard.string(forKey: Self.savedDevicesDefaultsKey)?.data(using: .utf8)
        let manifestData = (try? Data(contentsOf: manifestURL)) ?? fallbackData

        let stored = manifestData.flatMap { try? JSONDecoder().decode([FindMyStoredDevice].self, from: $0) } ?? []

        devices = stored.map { item in
            func load(_ filename: String?) -> Data? {
                filename.flatMap { try? Data(contentsOf: cacheDirectory.appendingPathComponent($0)) }
            }
            return FindMyDeviceEntry(
                deviceKey: item.deviceKey,
                deviceType: item.deviceType,
                hardwareModel: item.hardwareModel,
                onlineSourceFilename: item.onlineSourceFilename,
                onlineInfoBoxFilename: item.onlineInfoBoxFilename,
                offlineSourceFilename: item.offlineSourceFilename,
                offlineInfoBoxFilename: item.offlineInfoBoxFilename,
                onlineSourceCacheFile: item.onlineSourceCacheFile,
                onlineInfoCacheFile: item.onlineInfoCacheFile,
                offlineSourceCacheFile: item.offlineSourceCacheFile,
                offlineInfoCacheFile: item.offlineInfoCacheFile,
                onlineSourceListData: load(item.onlineSourceCacheFile),
                onlineInfoBoxData: load(item.onlineInfoCacheFile),
                offlineSourceListData: load(item.offlineSourceCacheFile),
                offlineInfoBoxData: load(item.offlineInfoCacheFile)
            )
        }

        replacementSourceListData = [:]
        replacementInfoBoxData = [:]
        let localPlaceholder = Self.placeholderKey(for: Self.hardwareMachineIdentifier() ?? "Device")
        let persistedKeys = stored.map(\.deviceKey) + [localPlaceholder]
        for key in Set(persistedKeys) {
            let pendingSourceURL = cacheDirectory.appendingPathComponent(Self.pendingCacheFilename(for: key, kind: "sourcelist"))
            let pendingInfoURL = cacheDirectory.appendingPathComponent(Self.pendingCacheFilename(for: key, kind: "infobox"))
            if let pending = try? Data(contentsOf: pendingSourceURL) {
                replacementSourceListData[key] = pending
            }
            if let pending = try? Data(contentsOf: pendingInfoURL) {
                replacementInfoBoxData[key] = pending
            }
        }

        selectedDeviceKey = UserDefaults.standard.string(forKey: Self.selectedDeviceDefaultsKey) ?? ""
        if !devices.contains(where: { $0.deviceKey == selectedDeviceKey }) {
            let machine = Self.hardwareMachineIdentifier()?.lowercased()
            selectedDeviceKey = devices.first(where: { item in
                guard let machine else { return false }
                return item.deviceKey.lowercased().contains(machine)
            })?.deviceKey ?? devices.first?.deviceKey ?? ""
        }
        UserDefaults.standard.set(selectedDeviceKey, forKey: Self.selectedDeviceDefaultsKey)
    }

    private func scanForMissingIPadDeviceImagesIfNeeded() {
        guard UIDevice.current.userInterfaceIdiom == .pad,
              !session.didAttemptInitialIPadScan else { return }

        // The iPad preview's device rows specifically need source-list artwork.
        // An info-box image alone must not suppress the initial device-image scan.
        let hasCachedDeviceArtwork = devices.contains { device in
            device.sourceListData(for: selectedStatus) != nil
        }
        guard !hasCachedDeviceArtwork else { return }

        let bridge = airlift
        DispatchQueue.global(qos: .utility).async {
            let isReady = bridge.airliftFeatureReady()
            DispatchQueue.main.async {
                guard isReady, !isScanning, !isApplying, !isResetting else { return }
                session.didAttemptInitialIPadScan = true
                scanDevicesFolder()
            }
        }
    }

    private func scanDevicesFolder() {
        guard !isScanning, !isApplying, !isResetting else { return }
        isScanning = true
        airlift.appendLog("[Find My] Scanning device image cache at \(devicesPath).")

        airlift.readRemoteFolderArchive(path: devicesPath, logLabel: "Find My device artwork", feature: "findmy") { archiveData in
            guard let archiveData else {
                isScanning = false
                airlift.appendLog("[Find My] Scan failed: Airlift did not return a directory archive.")
                return
            }

            let machineIdentifier = Self.hardwareMachineIdentifier()?.lowercased()
            let priorSelection = self.selectedDeviceKey

            DispatchQueue.global(qos: .userInitiated).async {
                let fileManager = FileManager.default
                let uniqueToken = UUID().uuidString
                let root = fileManager.temporaryDirectory.appendingPathComponent("erosion_findmy_scan_\(uniqueToken)", isDirectory: true)
                let zipURL = fileManager.temporaryDirectory.appendingPathComponent("erosion_findmy_scan_\(uniqueToken).zip")

                do {
                    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
                    try archiveData.write(to: zipURL, options: .atomic)
                    try fileManager.unzipItem(at: zipURL, to: root)

                    guard let enumerator = fileManager.enumerator(
                        at: root,
                        includingPropertiesForKeys: [.isRegularFileKey],
                        options: [.skipsHiddenFiles]
                    ) else {
                        throw FindMyScanError.noFiles
                    }

                    var records: [String: FindMyScanRecord] = [:]
                    for case let fileURL as URL in enumerator {
                        guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                        let name = fileURL.lastPathComponent
                        for variant in FindMyFileVariant.allCases {
                            for kind in [FindMyAssetKind.sourceList, .infoBox] {
                                guard let key = Self.deviceKey(from: name, variant: variant, kind: kind) else { continue }
                                var record = records[key] ?? FindMyScanRecord()
                                record.set(fileURL, variant: variant, kind: kind)
                                records[key] = record
                            }
                        }
                    }

                    guard !records.isEmpty else { throw FindMyScanError.noFindMyImages }

                    let selectedKey = records.keys.first(where: { key in
                        guard let machineIdentifier else { return false }
                        return key.lowercased().contains(machineIdentifier)
                    })
                    let sortedKeys = records.keys.sorted { left, right in
                        let leftMatches = left == selectedKey
                        let rightMatches = right == selectedKey
                        if leftMatches != rightMatches { return leftMatches }
                        return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
                    }

                    let cacheDirectory = Self.persistentAssetDirectory()
                    let entries: [FindMyDeviceEntry] = sortedKeys.map { key in
                        let record = records[key] ?? FindMyScanRecord()
                        func read(_ url: URL?) -> Data? { url.flatMap { try? Data(contentsOf: $0) } }
                        func cacheName(_ data: Data?, variant: FindMyFileVariant, kind: FindMyAssetKind) -> String? {
                            guard let data else { return nil }
                            let filename = "\(Self.cacheToken(for: key))-\(variant.rawValue)-\(kind.cacheToken).png"
                            return Self.storeCachedData(data, filename: filename, in: cacheDirectory)
                        }
                        let onlineSource = read(record.onlineSource)
                        let onlineInfo = read(record.onlineInfoBox)
                        let offlineSource = read(record.offlineSource)
                        let offlineInfo = read(record.offlineInfoBox)
                        let descriptor = Self.deviceDescriptor(forKey: key)

                        return FindMyDeviceEntry(
                            deviceKey: key,
                            deviceType: descriptor.type,
                            hardwareModel: descriptor.model,
                            onlineSourceFilename: record.onlineSource?.lastPathComponent,
                            onlineInfoBoxFilename: record.onlineInfoBox?.lastPathComponent,
                            offlineSourceFilename: record.offlineSource?.lastPathComponent,
                            offlineInfoBoxFilename: record.offlineInfoBox?.lastPathComponent,
                            onlineSourceCacheFile: cacheName(onlineSource, variant: .online, kind: .sourceList),
                            onlineInfoCacheFile: cacheName(onlineInfo, variant: .online, kind: .infoBox),
                            offlineSourceCacheFile: cacheName(offlineSource, variant: .offline, kind: .sourceList),
                            offlineInfoCacheFile: cacheName(offlineInfo, variant: .offline, kind: .infoBox),
                            onlineSourceListData: onlineSource,
                            onlineInfoBoxData: onlineInfo,
                            offlineSourceListData: offlineSource,
                            offlineInfoBoxData: offlineInfo
                        )
                    }

                    guard entries.contains(where: {
                        $0.onlineSourceListData != nil || $0.onlineInfoBoxData != nil
                            || $0.offlineSourceListData != nil || $0.offlineInfoBoxData != nil
                    }) else {
                        throw FindMyScanError.noReadableImages
                    }

                    DispatchQueue.main.async {
                        let localPlaceholder = Self.placeholderKey(for: Self.hardwareMachineIdentifier() ?? "Device")
                        let machineEntry = entries.first(where: { keyMatchesMachine($0.deviceKey, machineIdentifier: machineIdentifier) })
                        let selected = entries.first(where: { $0.deviceKey == priorSelection }) ?? machineEntry ?? entries.first
                        let newSelection = selected?.deviceKey ?? ""

                        // Images selected before the first scan are transferred only to
                        // the actual hardware-model match, never to an arbitrary first row.
                        if let machineEntry {
                            if let pending = replacementSourceListData.removeValue(forKey: localPlaceholder) {
                                Self.removeCachedData(filename: Self.pendingCacheFilename(for: localPlaceholder, kind: "sourcelist"), from: Self.persistentAssetDirectory())
                                setPendingSourceReplacement(pending, for: machineEntry.deviceKey)
                            }
                            if let pending = replacementInfoBoxData.removeValue(forKey: localPlaceholder) {
                                Self.removeCachedData(filename: Self.pendingCacheFilename(for: localPlaceholder, kind: "infobox"), from: Self.persistentAssetDirectory())
                                setPendingInfoBoxReplacement(pending, for: machineEntry.deviceKey)
                            }
                        }

                        devices = entries
                        selectedDeviceKey = newSelection
                        persistDeviceList(entries)
                        airlift.appendLog("[Find My] Scan completed: found \(entries.count) device image set(s), including online/offline variants where present.")
                        isScanning = false
                    }
                } catch {
                    DispatchQueue.main.async {
                        airlift.appendLog("[Find My] Scan failed: \(error.localizedDescription)")
                        isScanning = false
                    }
                }

                try? fileManager.removeItem(at: root)
                try? fileManager.removeItem(at: zipURL)
            }
        }
    }

    private func applyPendingChanges() async {
        let shouldApplyFindMy = shouldShowFindMyControls && hasApplicableReplacements
        let permission = selectedTCCPermission
        let shouldApplyTCC = tccSession.hasPendingImage(for: permission)
        let shouldApplyLayout = layoutsStore.shouldApplyTopLayout
        guard shouldApplyFindMy || shouldApplyTCC || shouldApplyLayout else { return }

        // A deliberate reorder of Layouts queues the first item for the shared Apply button.
        // Only consume that queue after the remote write succeeds.
        if shouldApplyLayout {
            var outcomes: [(String, Bool)] = []
            if shouldApplyFindMy {
                outcomes.append(("Find My", await applyReplacements(showSuccessAlert: false)))
            }
            if shouldApplyTCC {
                outcomes.append(("TCC", await tccSession.applySelectedImage(using: airlift, permission: permission)))
            }
            let layoutName = layoutsStore.layouts.first?.displayName ?? "Layout"
            let layoutSucceeded = await layoutsStore.applyTopLayout(using: airlift)
            outcomes.append(("Layout (\(layoutName))", layoutSucceeded))

            let allSucceeded = outcomes.allSatisfy { $0.1 }
            let details = outcomes.map { "\($0.0): \($0.1 ? "success" : "failed")" }.joined(separator: "\n")
            Alertinator.shared.alert(
                title: allSucceeded ? "Successfully applied changes!" : "Some changes could not be applied",
                body: allSucceeded ? "\(details)" : "\(details)\nCheck the Airlift log for details."
            )
            if allSucceeded { Haptic.shared.play(.soft) }
            return
        }

        if shouldApplyFindMy && shouldApplyTCC {
            let findMySucceeded = await applyReplacements(showSuccessAlert: false)
            let tccSucceeded = await tccSession.applySelectedImage(using: airlift, permission: permission)
            if findMySucceeded && tccSucceeded {
                Alertinator.shared.alert(
                    title: permission == .all
                        ? "Successfully applied TCC images and Find My images!"
                        : "Successfully applied TCC image and Find My images!",
                    body: "Find My images and the selected TCC preview were applied."
                )
                Haptic.shared.play(.soft)
            } else {
                Alertinator.shared.alert(
                    title: "Some changes could not be applied",
                    body: "Find My: \(findMySucceeded ? "success" : "failed"). TCC: \(tccSucceeded ? "success" : "failed"). Check the Airlift log for details."
                )
            }
            return
        }

        if shouldApplyTCC {
            let succeeded = await tccSession.applySelectedImage(using: airlift, permission: permission)
            if succeeded {
                Alertinator.shared.alert(
                    title: permission == .all ? "Successfully applied TCC images!" : "Successfully applied TCC image!",
                    body: permission == .all
                        ? "The preview image was applied to all TCC permission categories."
                        : "The preview image was applied to the selected permission category."
                )
                Haptic.shared.play(.soft)
            } else {
                Alertinator.shared.alert(title: "Failed to apply TCC image!", body: AppMsg.opFailed)
            }
            return
        }

        _ = await applyReplacements()
    }

    private func applyReplacements(showSuccessAlert: Bool = true) async -> Bool {
        guard !isApplying, !isScanning, !isResetting, hasApplicableReplacements else { return false }
        isApplying = true
        airlift.appendLog("[Find My] Applying image replacement(s) with Status = \(selectedStatus.rawValue).")

        var writes: [FindMyPendingWrite] = []
        for (key, data) in Array(replacementSourceListData) {
            guard let originalDevice = devices.first(where: { $0.deviceKey == key }) else { continue }
            for target in writeTargets(for: originalDevice, kind: .sourceList) {
                writes.append(FindMyPendingWrite(
                    key: key,
                    variant: target.variant,
                    kind: .sourceList,
                    filename: target.filename,
                    data: data
                ))
            }
        }

        for (key, data) in Array(replacementInfoBoxData) {
            guard let originalDevice = devices.first(where: { $0.deviceKey == key }) else { continue }
            for target in writeTargets(for: originalDevice, kind: .infoBox) {
                writes.append(FindMyPendingWrite(
                    key: key,
                    variant: target.variant,
                    kind: .infoBox,
                    filename: target.filename,
                    data: data
                ))
            }
        }

        var succeeded = 0
        var failed = 0
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("erosion_findmy_write_\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            var stagedFiles: [String: Data] = [:]
            for write in writes {
                let filename = write.filename
                guard !filename.isEmpty,
                      filename == URL(fileURLWithPath: filename).lastPathComponent,
                      !filename.contains("/"), !filename.contains("\\") else {
                    throw NSError(domain: "FindMyWrite", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid remote image filename."])
                }
                if let previous = stagedFiles[filename], previous != write.data {
                    throw NSError(domain: "FindMyWrite", code: 2, userInfo: [NSLocalizedDescriptionKey: "Two replacement images target the same remote filename."])
                }
                stagedFiles[filename] = write.data
            }

            guard !stagedFiles.isEmpty else {
                throw NSError(domain: "FindMyWrite", code: 3, userInfo: [NSLocalizedDescriptionKey: "No replacement images are selected for the current target."])
            }

            for (filename, data) in stagedFiles {
                try data.write(to: stagingDirectory.appendingPathComponent(filename), options: .atomic)
            }

            // Match Custom Passcode's directory-write mechanism while preserving
            // Find My's exact online/offline target filenames and selected status.
            let batchSucceeded = await airlift.writeDirectoryBatch(
                localDirectoryURL: stagingDirectory,
                remotePath: devicesPath,
                logFeature: "findmy"
            )

            if batchSucceeded {
                for write in writes {
                    cacheAppliedImage(write.data, key: write.key, variant: write.variant, kind: write.kind)
                    succeeded += 1
                }

                for key in Set(writes.filter { $0.kind == .sourceList }.map(\.key)) {
                    clearPendingSourceReplacement(for: key)
                }
                for key in Set(writes.filter { $0.kind == .infoBox }.map(\.key)) {
                    clearPendingInfoBoxReplacement(for: key)
                }
            } else {
                failed = writes.count
            }
        } catch {
            failed = writes.count
            airlift.appendFeatureLog("findmy", "Could not stage image replacement batch: \(error.localizedDescription)")
        }

        try? FileManager.default.removeItem(at: stagingDirectory)

        persistDeviceList(devices)
        isApplying = false
        airlift.appendLog("[Find My] Apply finished: \(succeeded) write(s) succeeded, \(failed) failed.")
        let completed = succeeded > 0 && failed == 0
        if completed && showSuccessAlert {
            showApplySuccessAlert = true
        }
        return completed
    }

    private func requestResetAllDeviceImages() {
        guard !isResetting, !isScanning, !isApplying else { return }
        Alertinator.shared.alert(
            title: "Are you sure you'd like to reset Find My images?",
            body: "This will reset Find My device images. Do you want to continue?",
            actionLabel: "Confirm",
            action: {
                Task { await resetAllDeviceImages() }
            }
        )
    }

    private func resetAllDeviceImages() async {
        guard !isResetting, !isScanning, !isApplying else { return }

        isResetting = true
        airlift.appendFeatureLog("findmy", "Reset requested: removing the complete remote devices directory at \(devicesPath).")

        // The Airlift primitive supports removing a directory directly. Use one
        // recursive directory operation instead of deleting each image serially.
        let removed = await airlift.removeRemotePath(devicesPath, logFeature: "findmy")
        if removed {
            let localDirectory = Self.persistentAssetDirectory()
            do {
                try FileManager.default.removeItem(at: localDirectory)
                try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
            } catch {
                airlift.appendFeatureLog("findmy", "Remote devices directory was removed, but local Find My cache cleanup failed: \(error.localizedDescription)")
            }

            devices = []
            replacementSourceListData = [:]
            replacementInfoBoxData = [:]
            selectedDeviceKey = ""
            UserDefaults.standard.removeObject(forKey: Self.savedDevicesDefaultsKey)
            UserDefaults.standard.set("", forKey: Self.selectedDeviceDefaultsKey)
            // Keep this view from restoring a stale in-memory manifest after navigation.
            session.didRestore = true
            airlift.appendFeatureLog("findmy", "Reset succeeded: removed the entire remote devices directory. Local device list and pending image replacements were cleared.")
            Alertinator.shared.alert(
                title: "Successfully reset Find My images!",
                body: "Find My images were reset."
            )
        } else {
            airlift.appendFeatureLog("findmy", "Reset failed: could not remove the complete remote devices directory at \(devicesPath).")
            Alertinator.shared.alert(
                title: "Failed to reset Find My images",
                body: "The device image directory could not be removed. Check the Airlift log."
            )
        }

        isResetting = false
    }

    private func exportAllDeviceImages() {
        guard !isScanning, !isApplying, !isResetting else { return }
        let cacheDirectory = Self.persistentAssetDirectory()
        var exportedByFilename: [String: Data] = [:]

        for device in devices where !device.isPlaceholder {
            let candidates: [(String?, Data?, String?, FindMyFileVariant, FindMyAssetKind)] = [
                (device.onlineSourceFilename, device.onlineSourceListData, device.onlineSourceCacheFile, .online, .sourceList),
                (device.onlineInfoBoxFilename, device.onlineInfoBoxData, device.onlineInfoCacheFile, .online, .infoBox),
                (device.offlineSourceFilename, device.offlineSourceListData, device.offlineSourceCacheFile, .offline, .sourceList),
                (device.offlineInfoBoxFilename, device.offlineInfoBoxData, device.offlineInfoCacheFile, .offline, .infoBox)
            ]

            for candidate in candidates {
                guard let filename = candidate.0,
                      !filename.isEmpty,
                      filename == URL(fileURLWithPath: filename).lastPathComponent,
                      !filename.contains("/") && !filename.contains("\\"),
                      Self.deviceKey(from: filename, variant: candidate.3, kind: candidate.4) == device.deviceKey,
                      exportedByFilename[filename] == nil else { continue }
                let cachedData = candidate.2.flatMap { try? Data(contentsOf: cacheDirectory.appendingPathComponent($0)) }
                if let data = candidate.1 ?? cachedData {
                    exportedByFilename[filename] = data
                }
            }
        }

        guard !exportedByFilename.isEmpty else {
            Alertinator.shared.alert(title: "Failed to export images", body: "No cached image data is available for the scanned devices.")
            return
        }

        let fileManager = FileManager.default
        let token = UUID().uuidString
        let stagingDirectory = fileManager.temporaryDirectory.appendingPathComponent("erosion_findmy_export_all_\(token)", isDirectory: true)
        let archiveName = "FindMy-Devices.zip"
        let archiveURL = fileManager.temporaryDirectory.appendingPathComponent(archiveName)

        do {
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            for (filename, data) in exportedByFilename.sorted(by: { $0.key < $1.key }) {
                try data.write(to: stagingDirectory.appendingPathComponent(filename), options: .atomic)
            }
            try? fileManager.removeItem(at: archiveURL)
            try fileManager.zipItem(at: stagingDirectory, to: archiveURL, shouldKeepParent: false)
            try? fileManager.removeItem(at: stagingDirectory)
            airlift.appendFeatureLog("findmy", "Export succeeded: archived \(exportedByFilename.count) image file(s) from \(Set(devices.map(\.deviceKey)).count) device(s) to \(archiveName).")
            presentShareSheet(with: archiveURL)
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            try? fileManager.removeItem(at: archiveURL)
            airlift.appendFeatureLog("findmy", "Export failed: \(error.localizedDescription)")
            Alertinator.shared.alert(title: "Failed to export images", body: error.localizedDescription)
        }
    }

    private func writeTargets(for device: FindMyDeviceEntry, kind: FindMyAssetKind) -> [FindMyWriteTarget] {
        let onlineFilename = kind == .sourceList ? device.onlineSourceFilename : device.onlineInfoBoxFilename
        let offlineFilename = kind == .sourceList ? device.offlineSourceFilename : device.offlineInfoBoxFilename

        switch selectedStatus {
        case .both:
            var targets: [FindMyWriteTarget] = []
            if let onlineFilename { targets.append(FindMyWriteTarget(variant: .online, filename: onlineFilename)) }
            if let offlineFilename { targets.append(FindMyWriteTarget(variant: .offline, filename: offlineFilename)) }
            return targets
        case .online:
            return onlineFilename.map { [FindMyWriteTarget(variant: .online, filename: $0)] } ?? []
        case .offline:
            return offlineFilename.map { [FindMyWriteTarget(variant: .offline, filename: $0)] } ?? []
        }
    }

    private func cacheAppliedImage(_ data: Data, key: String, variant: FindMyFileVariant, kind: FindMyAssetKind) {
        guard let index = devices.firstIndex(where: { $0.deviceKey == key }) else { return }
        var entry = devices[index]
        let existingCache: String?
        switch (variant, kind) {
        case (.online, .sourceList): existingCache = entry.onlineSourceCacheFile
        case (.online, .infoBox): existingCache = entry.onlineInfoCacheFile
        case (.offline, .sourceList): existingCache = entry.offlineSourceCacheFile
        case (.offline, .infoBox): existingCache = entry.offlineInfoCacheFile
        }
        let cacheFilename = existingCache ?? "\(Self.cacheToken(for: key))-\(variant.rawValue)-\(kind.cacheToken).png"
        let storedFilename = Self.storeCachedData(data, filename: cacheFilename, in: Self.persistentAssetDirectory())

        switch (variant, kind) {
        case (.online, .sourceList):
            entry.onlineSourceListData = data
            if let storedFilename { entry.onlineSourceCacheFile = storedFilename }
        case (.online, .infoBox):
            entry.onlineInfoBoxData = data
            if let storedFilename { entry.onlineInfoCacheFile = storedFilename }
        case (.offline, .sourceList):
            entry.offlineSourceListData = data
            if let storedFilename { entry.offlineSourceCacheFile = storedFilename }
        case (.offline, .infoBox):
            entry.offlineInfoBoxData = data
            if let storedFilename { entry.offlineInfoCacheFile = storedFilename }
        }
        devices[index] = entry
    }

    private func persistDeviceList(_ entries: [FindMyDeviceEntry]) {
        let values = entries.map(\.storedValue)
        guard let data = try? JSONEncoder().encode(values) else { return }
        let directory = Self.persistentAssetDirectory()
        let manifestURL = directory.appendingPathComponent(Self.deviceManifestFilename)
        do {
            try data.write(to: manifestURL, options: .atomic)
            if let string = String(data: data, encoding: .utf8) {
                UserDefaults.standard.set(string, forKey: Self.savedDevicesDefaultsKey)
            }
        } catch {
            airlift.appendLog("[Find My] Could not persist the device manifest: \(error.localizedDescription)")
        }
    }

    private func setPendingSourceReplacement(_ data: Data, for key: String) {
        replacementSourceListData[key] = data
        _ = Self.storeCachedData(data, filename: Self.pendingCacheFilename(for: key, kind: "sourcelist"), in: Self.persistentAssetDirectory())
    }

    private func setPendingInfoBoxReplacement(_ data: Data, for key: String) {
        replacementInfoBoxData[key] = data
        _ = Self.storeCachedData(data, filename: Self.pendingCacheFilename(for: key, kind: "infobox"), in: Self.persistentAssetDirectory())
    }

    private func clearPendingSourceReplacement(for key: String) {
        replacementSourceListData.removeValue(forKey: key)
        Self.removeCachedData(filename: Self.pendingCacheFilename(for: key, kind: "sourcelist"), from: Self.persistentAssetDirectory())
    }

    private func clearPendingInfoBoxReplacement(for key: String) {
        replacementInfoBoxData.removeValue(forKey: key)
        Self.removeCachedData(filename: Self.pendingCacheFilename(for: key, kind: "infobox"), from: Self.persistentAssetDirectory())
    }

    private static func persistentAssetDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = support.appendingPathComponent("ErosionFindMyAssets", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func storeCachedData(_ data: Data, filename: String?, in directory: URL) -> String? {
        guard let filename else { return nil }
        let url = directory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            return filename
        } catch {
            return nil
        }
    }

    private static func cacheToken(for key: String) -> String {
        Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func pendingCacheFilename(for key: String, kind: String) -> String {
        "\(cacheToken(for: key))-pending-\(kind).png"
    }

    private static func removeCachedData(filename: String, from directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
    }

    private static func placeholderKey(for machine: String) -> String {
        "__local__\(machine)"
    }

    private static func deviceKey(from filename: String, variant: FindMyFileVariant, kind: FindMyAssetKind) -> String? {
        // Prefer the real PNG spelling but also accept the extension-less infobox
        // filename form seen on some cache snapshots. Writes preserve the exact name.
        let stem = "-\(variant.rawValue)-\(kind.filenameToken)__3x"
        for suffix in [".png", ""] {
            let fullSuffix = stem + suffix
            if filename.hasSuffix(fullSuffix) {
                let key = String(filename.dropLast(fullSuffix.count))
                return key.isEmpty ? nil : key
            }
        }
        return nil
    }

    private static func deviceDescriptor(forKey key: String) -> (type: String, model: String) {
        let components = key.split(separator: "-").map(String.init)
        let model = components.first(where: { looksLikeHardwareModel($0) })
            ?? components.first(where: { $0.rangeOfCharacter(from: .decimalDigits) != nil && !$0.allSatisfy(\.isNumber) })
            ?? key
        let familyToken = components.first ?? model
        return (friendlyDeviceName(from: familyToken == model ? model : familyToken), model)
    }

    private static func looksLikeHardwareModel(_ value: String) -> Bool {
        value.range(of: #"[A-Za-z]+[0-9]+,[0-9]+"#, options: .regularExpression) != nil
    }

    private static func friendlyDeviceName(from value: String) -> String {
        let lower = value.lowercased()
        if lower.hasPrefix("iphone") { return "iPhone" }
        if lower.hasPrefix("ipad") { return "iPad" }
        if lower.hasPrefix("ipod") { return "iPod" }
        if lower.hasPrefix("watch") || lower.hasPrefix("applewatch") { return "Apple Watch" }
        if lower.hasPrefix("airpods") { return "AirPods" }
        if lower.hasPrefix("mac") { return "Mac" }
        if lower.hasPrefix("appletv") || lower.hasPrefix("apple-tv") { return "Apple TV" }
        if lower.hasPrefix("homepod") { return "HomePod" }
        return value.isEmpty ? "Device" : value
    }

    private static func hardwareMachineIdentifier() -> String? {
        var size: size_t = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var machine = [CChar](repeating: 0, count: Int(size))
        let result = machine.withUnsafeMutableBufferPointer { buffer in
            sysctlbyname("hw.machine", buffer.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        return String(cString: machine)
    }
}

private struct FindMyDeviceRowView: View {
    @Environment(\.colorScheme) private var colorScheme
    let device: FindMyDeviceEntry
    let avatarData: Data?
    let rowHeight: CGFloat
    let diameter: CGFloat
    let rowSpacing: CGFloat
    let showSeparator: Bool
    let isDisabled: Bool
    let onOpenSourcePicker: () -> Void
    let onSelect: () -> Void

    private var rowContent: some View {
        HStack(spacing: rowSpacing) {
            Button(action: onOpenSourcePicker) {
                deviceAvatar
            }
            .buttonStyle(.plain)
            .frame(width: diameter, height: diameter)
            .disabled(isDisabled)

            if device.isPlaceholder {
                Spacer(minLength: 0)
            } else {
                Button(action: onSelect) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.deviceType)
                            .font(.system(size: max(11, min(15, diameter * 0.32)), weight: .semibold))
                            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                            .lineLimit(1)

                        Text(device.hardwareModel)
                            .font(.system(size: max(9, min(12, diameter * 0.25)), weight: .regular))
                            .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.56) : Color.black.opacity(0.52))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var deviceAvatar: some View {
        ZStack {
            Circle()
                .fill(Color(.tertiarySystemFill))

            if let avatarData, let image = UIImage(data: avatarData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: diameter * 0.82, height: diameter * 0.82)
            }

            Circle()
                .stroke(Color.clear, lineWidth: 1.23)
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .contentShape(Circle())
    }

    var body: some View {
        VStack(spacing: 0) {
            rowContent

            if showSeparator {
                Rectangle()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.19) : Color.black.opacity(0.12))
                    .frame(height: 0.6)
                    .padding(.leading, diameter + rowSpacing)
            }
        }
        .padding(.leading, 0)
        .padding(.trailing, 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(device.deviceKey)
    }
}

private func keyMatchesMachine(_ key: String, machineIdentifier: String?) -> Bool {
    guard let machineIdentifier else { return false }
    return key.lowercased().contains(machineIdentifier)
}

private enum FindMyScanError: LocalizedError {
    case noFiles
    case noFindMyImages
    case noReadableImages

    var errorDescription: String? {
        switch self {
        case .noFiles: return "The Airlift directory snapshot could not be enumerated."
        case .noFindMyImages: return "No matching online/offline Find My image filenames were found."
        case .noReadableImages: return "The matching Find My image files could not be opened."
        }
    }
}
