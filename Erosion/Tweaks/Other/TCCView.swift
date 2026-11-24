import SwiftUI
import Combine
import UIKit
import AVFoundation
import Photos
import Contacts
import CoreLocation
import LocalAuthentication
import CoreBluetooth

enum TCCPermission: String, CaseIterable, Identifiable {
    case all = "All"
    case photos = "Photos"
    case bluetooth = "Bluetooth"
    case faceTouchID = "Face/Touch ID"
    case microphone = "Microphone"
    case location = "Location"
    case camera = "Camera"
    case contacts = "Contacts"

    var id: String { rawValue }

    /// Destination filenames. For All, one user-selected image is written to all seven targets.
    var filenames: [String] {
        switch self {
        case .all:
            return [
                "Location@3x.png",
                "kTCCServicePhotos@3x.png",
                "kTCCServiceAddressBook@3x.png",
                "kTCCServiceMicrophone@3x.png",
                "kTCCServiceBluetoothAlways@3x.png",
                "kTCCServiceCamera@3x.png",
                "kTCCServiceFaceID@3x.png"
            ]
        case .photos: return ["kTCCServicePhotos@3x.png"]
        case .bluetooth: return ["kTCCServiceBluetoothAlways@3x.png"]
        case .faceTouchID: return ["kTCCServiceFaceID@3x.png"]
        case .microphone: return ["kTCCServiceMicrophone@3x.png"]
        case .location: return ["Location@3x.png"]
        case .camera: return ["kTCCServiceCamera@3x.png"]
        case .contacts: return ["kTCCServiceAddressBook@3x.png"]
        }
    }

    var remotePath: String {
        if self == .all { return "/var/mobile/tmp/com.apple.tccd" }
        return "/var/mobile/tmp/com.apple.tccd/\(filenames[0])"
    }

    /// Bundled preview image for each permission category. All uses a neutral placeholder.
    var assetName: String {
        switch self {
        case .all, .camera: return "TCC_Camera"
        case .photos: return "TCC_Photos"
        case .bluetooth: return "TCC_Bluetooth"
        case .faceTouchID: return "TCC_FaceID"
        case .microphone: return "TCC_Microphone"
        case .location: return "TCC_Location"
        case .contacts: return "TCC_Contacts"
        }
    }

    /// Text shown in the prompt template, controlled by the Permission picker.
    var promptSubject: String {
        switch self {
        case .all: return "All"
        case .camera: return "Camera"
        case .photos: return "Photos"
        case .bluetooth: return "Bluetooth"
        case .faceTouchID: return "Face/Touch ID"
        case .microphone: return "Microphone"
        case .location: return "Location"
        case .contacts: return "Contacts"
        }
    }

    var promptTitle: String { "Allow “Erosion” to use \(promptSubject)?" }

    var promptDetail: String {
        "This is a preview of how TCC notifications will look."
    }
}

/// Stores a custom preview per selected Permission and applies it through the
/// shared top-right Apply button on the Other screen.
@MainActor
final class TCCSession: ObservableObject {
    static let shared = TCCSession()
    static let permissionDefaultsKey = "erosion.tcc.permissionSelection.v1"
    private static let customImageKeyPrefix = "erosion.tcc.customImage.v2."
    private static let pendingImagePermissionsKey = "erosion.tcc.pendingImages.v1"

    private let remoteDirectory = "/var/mobile/tmp/com.apple.tccd"

    @Published private(set) var imageRevision = 0
    @Published private(set) var isApplying = false
    @Published private(set) var isResetting = false

    private init() {
        // Migrate images imported by earlier TCC builds to the pending queue once.
        // This preserves an image the user already selected before updating Erosion.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.pendingImagePermissionsKey) == nil {
            let previouslySelected = TCCPermission.allCases.compactMap { permission -> String? in
                let key = Self.customImageKeyPrefix + permission.rawValue
                guard let data = defaults.data(forKey: key), UIImage(data: data) != nil else { return nil }
                return permission.rawValue
            }
            defaults.set(previouslySelected, forKey: Self.pendingImagePermissionsKey)
        }
    }

    private func customImageKey(for permission: TCCPermission) -> String {
        Self.customImageKeyPrefix + permission.rawValue
    }

    func customImageData(for permission: TCCPermission) -> Data? {
        UserDefaults.standard.data(forKey: customImageKey(for: permission))
    }

    func hasCustomImage(for permission: TCCPermission) -> Bool {
        guard let data = customImageData(for: permission), UIImage(data: data) != nil else { return false }
        return true
    }

    /// Indicates whether the selected permission has an image waiting to be applied.
    func hasPendingImage(for permission: TCCPermission) -> Bool {
        let pending = UserDefaults.standard.stringArray(forKey: Self.pendingImagePermissionsKey) ?? []
        return pending.contains(permission.rawValue)
    }

    /// Updates the persisted pending queue after selecting, applying, or resetting an image.
    private func setPendingImage(_ isPending: Bool, for permission: TCCPermission) {
        var pending = Set(UserDefaults.standard.stringArray(forKey: Self.pendingImagePermissionsKey) ?? [])
        if isPending {
            pending.insert(permission.rawValue)
        } else {
            pending.remove(permission.rawValue)
        }
        UserDefaults.standard.set(pending.sorted(), forKey: Self.pendingImagePermissionsKey)
        imageRevision &+= 1
    }

    /// Called when the user taps the displayed image and picks a replacement.
    /// The replacement is resized immediately and saved silently; no alert is shown.
    func selectCustomImage(_ data: Data, for permission: TCCPermission) {
        guard let normalized = Self.normalized207PNG(data) else { return }
        UserDefaults.standard.set(normalized, forKey: customImageKey(for: permission))
        setPendingImage(true, for: permission)
    }

    func applySelectedImage(using airlift: AirliftBridge, permission: TCCPermission) async -> Bool {
        guard !isApplying, !isResetting,
              let imageData = customImageData(for: permission),
              let normalized = Self.normalized207PNG(imageData) else { return false }
        isApplying = true
        defer { isApplying = false }

        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("erosion_tcc_stage_\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            for filename in permission.filenames {
                try normalized.write(to: stage.appendingPathComponent(filename), options: .atomic)
            }

            let succeeded = await airlift.writeDirectoryBatch(
                localDirectoryURL: stage,
                remotePath: remoteDirectory,
                logFeature: "tcc"
            )
            try? FileManager.default.removeItem(at: stage)
            if succeeded {
                // Applying through All means this same artwork is now the active preview
                // for every individual permission category too. Do not do this when a
                // single category is applied.
                if permission == .all {
                    for category in TCCPermission.allCases where category != .all {
                        UserDefaults.standard.set(normalized, forKey: customImageKey(for: category))
                        setPendingImage(false, for: category)
                    }
                }
                setPendingImage(false, for: permission)
            }
            return succeeded
        } catch {
            try? FileManager.default.removeItem(at: stage)
            airlift.appendFeatureLog("tcc", "Could not stage TCC image(s): \(error.localizedDescription)")
            return false
        }
    }

    func resetSelected(using airlift: AirliftBridge, permission: TCCPermission) async -> Bool {
        guard !isApplying, !isResetting else { return false }
        isResetting = true
        defer { isResetting = false }
        let succeeded = await airlift.removeRemotePath(permission.remotePath, logFeature: "tcc")
        if succeeded {
            if permission == .all {
                UserDefaults.standard.removeObject(forKey: Self.pendingImagePermissionsKey)
                imageRevision &+= 1
            } else {
                setPendingImage(false, for: permission)
            }
        }
        return succeeded
    }

    /// Produces a square PNG with exactly 207 × 207 pixels (69 pt at 3× scale).
    private static func normalized207PNG(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let pointSize = CGSize(width: 69, height: 69)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 3
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: pointSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: pointSize))
        }.pngData()
    }
}

struct TCCView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var airlift: AirliftBridge
    let onSelectImage: () -> Void
    @AppStorage("erosion.tcc.permissionSelection.v1") private var selectedPermissionRaw = "All"
    @AppStorage("erosion.tcc.prepare.completed.v1") private var didPrepare = false
    @StateObject private var preparer = TCCPermissionPreparer()
    @StateObject private var session = TCCSession.shared

    private var selectedPermission: TCCPermission {
        TCCPermission(rawValue: selectedPermissionRaw) ?? .all
    }

    private var promptCardBackground: Color {
        colorScheme == .light
            ? Color(UIColor.secondarySystemGroupedBackground)
            : Color(UIColor.secondarySystemBackground)
    }

    private var customPreviewImage: UIImage? {
        if let data = session.customImageData(for: selectedPermission), let image = UIImage(data: data) {
            return image
        }
        guard selectedPermission != .all else { return nil }
        return UIImage(named: selectedPermission.assetName)
            ?? UIImage(systemName: "camera.fill")
    }

    var body: some View {
        Section {
            // Keep Permission in its own List row. If the preview's context menu
            // shares a row with the picker, iOS highlights the picker on long press.
            VStack(spacing: 2) {
                Text("Permission")
                    .foregroundStyle(Color(.label))
                Picker("Permission", selection: $selectedPermissionRaw) {
                    ForEach(TCCPermission.allCases) { permission in
                        Text(permission.rawValue).tag(permission.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.orange)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 8, trailing: 8))

            promptCard
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 8, trailing: 8))
        } header: {
            HeaderLabel("TCC", symbol: "hand.raised.fingers.spread.fill")
        }
    }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: onSelectImage) {
                Group {
                    if selectedPermission == .all && customPreviewImage == nil {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(UIColor.systemGray3))
                    } else if let image = customPreviewImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(UIColor.systemGray3))
                    }
                }
                .frame(width: 69, height: 69)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose preview image from Photos")
            .disabled(session.isApplying || session.isResetting)

            VStack(alignment: .leading, spacing: 8) {
                Text(selectedPermission.promptTitle)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text(selectedPermission.promptDetail)
                    .font(.system(size: 16))
                    .foregroundColor(Color.white.opacity(0.48))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .modifier(LightModeTemplateInversion())

            HStack(spacing: 10) {
                promptButton("Don’t Allow")
                promptButton("Allow")
            }
            .modifier(LightModeTemplateInversion())
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // Match the grouped List sections in light appearance while preserving
            // the exact existing dark-mode card surface.
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(promptCardBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
                .modifier(LightModeTemplateInversion())
        }
        // Limit long-press actions to the preview card only, not the Permission picker.
        // Disabling text selection also avoids the unrelated system "Ask Siri" item.
        .textSelection(.disabled)
        .contextMenu {
            Button {
                Task {
                    await preparer.prepare()
                    didPrepare = true
                }
            } label: {
                Label(
                    didPrepare ? "Prepared" : (preparer.isPreparing ? "Preparing…" : "Prepare"),
                    systemImage: "checkmark.shield.fill"
                )
            }
            .disabled(didPrepare || preparer.isPreparing || session.isApplying || session.isResetting)

            Button(role: .destructive) {
                requestResetSelectedPermission()
            } label: {
                Label("Reset", systemImage: "gobackward")
            }
            .disabled(session.isApplying || session.isResetting)
        }
    }

    private func requestResetSelectedPermission() {
        let permission = selectedPermission
        Alertinator.shared.alert(
            title: permission == .all ? "Reset all TCC previews?" : "Reset this TCC preview?",
            body: "This will reset the selected preview state. Do you want to continue?",
            actionLabel: "Confirm",
            actionStyle: .destructive,
            action: { Task { await resetSelectedPermission(permission) } }
        )
    }

    private func resetSelectedPermission(_ permission: TCCPermission) async {
        let succeeded = await session.resetSelected(using: airlift, permission: permission)
        if succeeded {
            Alertinator.shared.alert(
                title: permission == .all ? "Successfully reset TCC images!" : "Successfully reset TCC image!",
                body: permission == .all
                    ? "All TCC preview images have been reset."
                    : "The selected TCC preview image has been reset."
            )
        } else {
            Alertinator.shared.alert(
                title: "Failed to reset TCC image!",
                body: AppMsg.opFailed
            )
        }
    }

    private func promptButton(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 17, weight: .medium))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.13))
            .clipShape(Capsule())
    }
}

@MainActor
private final class TCCPermissionPreparer: NSObject, ObservableObject, CLLocationManagerDelegate, CBCentralManagerDelegate {
    @Published private(set) var isPreparing = false

    private var locationManager: CLLocationManager?
    private var locationContinuation: CheckedContinuation<Void, Never>?
    private var bluetoothManager: CBCentralManager?
    private var bluetoothContinuation: CheckedContinuation<Void, Never>?

    func prepare() async {
        guard !isPreparing else { return }
        isPreparing = true

        // Queue each request so system permission sheets never overlap.
        await requestMicrophone()
        await requestCamera()
        await requestPhotos()
        await requestLocation()
        await requestContacts()
        await requestFaceID()
        await requestBluetooth()

        isPreparing = false
    }

    private func requestMicrophone() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { _ in continuation.resume() }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { _ in continuation.resume() }
            }
        }
    }

    private func requestCamera() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            AVCaptureDevice.requestAccess(for: .video) { _ in continuation.resume() }
        }
    }

    private func requestPhotos() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if #available(iOS 14.0, *) {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in continuation.resume() }
            } else {
                PHPhotoLibrary.requestAuthorization { _ in continuation.resume() }
            }
        }
    }

    private func requestLocation() async {
        let manager = CLLocationManager()
        manager.delegate = self
        locationManager = manager
        let status: CLAuthorizationStatus
        if #available(iOS 14.0, *) {
            status = manager.authorizationStatus
        } else {
            status = CLLocationManager.authorizationStatus()
        }
        guard status == .notDetermined else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            locationContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    @available(iOS 14.0, *)
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        finishLocationRequestIfNeeded(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        finishLocationRequestIfNeeded(status)
    }

    private func finishLocationRequestIfNeeded(_ status: CLAuthorizationStatus) {
        guard status != .notDetermined,
              let continuation = locationContinuation else { return }
        locationContinuation = nil
        continuation.resume()
    }

    private func requestContacts() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            CNContactStore().requestAccess(for: .contacts) { _, _ in continuation.resume() }
        }
    }

    private func requestFaceID() async {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Erosion is testing the Face ID system prompt."
            ) { _, _ in continuation.resume() }
        }
    }

    private func requestBluetooth() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            bluetoothContinuation = continuation
            bluetoothManager = CBCentralManager(delegate: self, queue: nil)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state != .unknown,
              central.state != .resetting,
              let continuation = bluetoothContinuation else { return }
        bluetoothContinuation = nil
        continuation.resume()
    }
}
