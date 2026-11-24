import SwiftUI
import UniformTypeIdentifiers

/// Transfers immutable preview images from the worker task to SwiftUI without
/// decoding the entire theme again on the main thread.
private final class PasscodePreviewImageBox: @unchecked Sendable {
    let images: [String: UIImage]
    init(_ images: [String: UIImage]) { self.images = images }
}

struct ExperimentalPasscodeView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var airlift: AirliftBridge
    @State private var showImporter = false
    @State private var selectedDigit: String?
    @State private var showImagePicker = false
    @AppStorage("erosion.passcode.keySizeRaw") private var keySizeRaw = KPSize.defSize.rawValue
    @AppStorage("erosion.passcode.customWidth") private var custW = 0
    @AppStorage("erosion.passcode.customHeight") private var custH = 0
    @AppStorage("erosion.passcode.maskKeys") private var maskKeys = false
    @State private var showSizeAlert = false
    @State private var isEditingCustomSize = false
    @State private var lastCommittedKeySizeRaw = UserDefaults.standard.integer(forKey: "erosion.passcode.keySizeRaw")
    @State private var draftCustomWidth = 0
    @State private var draftCustomHeight = 0
    @State private var awaitingApplyResult = false
    @State private var processedPreviewImages: [String: UIImage] = [:]

    private let digits = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", ""]]

    private var keySize: KPSize {
        KPSize(rawValue: keySizeRaw) ?? .defSize
    }

    /// Light appearance uses the same grouped surface already used by Library;
    /// dark appearance keeps the existing Custom Passcode surface unchanged.
    private var passcodePageBackground: Color {
        colorScheme == .light ? Color(.systemGroupedBackground) : Color(.systemBackground)
    }

    private var keySizeBackground: Color {
        // Keep the Key Size capsule on exactly the same surface as the page.
        // In light appearance this removes the brighter edge/halo against the
        // darker grouped background; dark appearance remains unchanged.
        passcodePageBackground
    }

    private var keySizeBinding: Binding<KPSize> {
        Binding(
            get: { KPSize(rawValue: keySizeRaw) ?? .defSize },
            set: { keySizeRaw = $0.rawValue }
        )
    }

    var body: some View {
        VStack(spacing: 10) {
            themeSections
            keySizePicker
                .zIndex(2)
            keypadPreview
                .zIndex(1)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.horizontal, 16)
        // Move Library, Key Size, and the complete keypad down together by 6 pt.
        .padding(.top, -28)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(passcodePageBackground.ignoresSafeArea())
                .task(id: previewConfigurationKey) {
                    await rebuildPreviewImages()
                }
                .navigationTitle("Custom Passcode")
                .navigationBarTitleDisplayMode(.inline)
                // Match Dialer Themer's normal system surface in both appearances.
                // The embedded grouped List can otherwise activate the navigation
                // bar's translucent scroll-edge appearance while this page is shown.
                .toolbarBackground(passcodePageBackground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                showImporter = true
                            } label: {
                                Label("Import .passthm", systemImage: "square.and.arrow.down")
                            }

                            Button {
                                maskKeys = true
                                Haptic.shared.play(.soft)
                            } label: {
                                Label("Mask Keys", systemImage: "circle")
                            }

                            Button {
                                airlift.getCurrentPasscodeKeys()
                            } label: {
                                Label("Get Current Keys", systemImage: "externaldrive")
                            }
                            .disabled(airlift.passcodeFlashRunning || airlift.readRunning)

                            Divider()

                            Button {
                                keySizeRaw = KPSize.defSize.rawValue
                                custW = 0
                                custH = 0
                                maskKeys = false
                                airlift.clearPasscodeKeys()
                                Haptic.shared.play(.soft)
                            } label: {
                                Label("Clear Keys", systemImage: "xmark")
                            }
                            .disabled(airlift.passcodeFlashRunning)

                            Button(role: .destructive) {
                                Alertinator.shared.alert(
                                    title: "Are you sure you'd like to reset your passcode keys?",
                                    body: "This removes the current contents of /var/mobile/Library/Caches/TelephonyUI-10 on the device. Your selected theme remains available to apply again.",
                                    actionLabel: "Confirm",
                                    action: {
                                        keySizeRaw = KPSize.defSize.rawValue
                                        custW = 0
                                        custH = 0
                                        maskKeys = false
                                        Task {
                                            let succeeded = await airlift.resetPasscodeKeys()
                                            if succeeded {
                                                Alertinator.shared.alert(
                                                    title: "Successfully reset passcode keys!",
                                                    body: "Passcode keys were reset."
                                                )
                                            } else {
                                                Alertinator.shared.alert(
                                                    title: "Failed to reset passcode keys!",
                                                    body: AppMsg.opFailed
                                                )
                                            }
                                        }
                                    }
                                )
                            } label: {
                                Label("Reset Keys", systemImage: "trash")
                            }
                            .disabled(airlift.passcodeFlashRunning)
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Apply", role: .adaptiveConfirm) {
                            awaitingApplyResult = true
                            airlift.flashPasscodeTheme(
                                keySize: keySize,
                                customWidth: custW,
                                customHeight: custH,
                                maskKeys: maskKeys
                            )
                        }
                        .disabled(airlift.passcodeFlashRunning || airlift.passcodeTheme == nil)
                    }
                }
                .fileImporter(isPresented: $showImporter, allowedContentTypes: [.archive, UTType(filenameExtension: "passthm") ?? .data], allowsMultipleSelection: false) { result in
                    guard case .success(let urls) = result, let url = urls.first else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer {
                        if scoped { url.stopAccessingSecurityScopedResource() }
                    }
                    // Keep the imported theme active on the keypad immediately, and quietly
                    // preserve the same archive in Library. Explore's own import confirmation
                    // remains unchanged.
                    if airlift.loadPasscodeTheme(url: url, logMessages: false) {
                        do {
                            _ = try PasscodeThemeLibraryStore.shared.importTheme(from: url)
                        } catch {
                            // Keep the active keypad theme even if Library storage fails.
                            print("(passcode) failed to add imported theme to Library: \(error.localizedDescription)")
                        }
                        PasscodeThemeLibraryStore.shared.clearSelection()
                    }
                }
                .sheet(isPresented: $showImagePicker) {
                    ImagePickerView { data in
                        guard let digit = selectedDigit, let image = UIImage(data: data) else { return }
                        airlift.setPasscodeKeyImage(digit: digit, image: image, data: data)
                    }
                }
                .onChange(of: airlift.passcodeFlashRunning) { wasRunning, isRunning in
                    guard awaitingApplyResult, wasRunning, !isRunning else { return }
                    awaitingApplyResult = false

                    let succeeded = airlift.passcodeLastApplySucceeded == true
                    if succeeded {
                        Alertinator.shared.alert(
                            title: "Successfully applied custom passcode keys!",
                            body: "Lock your device to see the new passcode artwork."
                        )
                        Haptic.shared.play(.soft)
                    } else {
                        Alertinator.shared.alert(
                            title: "Failed to apply custom passcode keys!",
                            body: AppMsg.opFailed
                        )
                    }
                }
    }

    private var keySizePicker: some View {
        VStack(spacing: 2) {
            Text("Key Size")
            Picker("", selection: keySizeBinding) {
                ForEach(KPSize.allCases, id: \.self) { size in
                    Text(size.label + (size == .custom ? " (\(custW)x\(custH))" : "")).tag(size)
                }
            }
            .alert("What would you like the custom size to be?", isPresented: $showSizeAlert) {
                TextField("Width", value: $draftCustomWidth, format: .number)
                    .keyboardType(.numberPad)
                TextField("Height", value: $draftCustomHeight, format: .number)
                    .keyboardType(.numberPad)
                Button("Cancel", role: .cancel) {
                    isEditingCustomSize = false
                    keySizeRaw = KPSize.defSize.rawValue
                }
                Button("Set") {
                    // Commit custom dimensions only after the alert is confirmed,
                    // matching Dialer Themer's deferred resize behavior.
                    custW = draftCustomWidth
                    custH = draftCustomHeight
                    isEditingCustomSize = false
                    lastCommittedKeySizeRaw = keySizeRaw
                    maskKeys = false
                }
            }
            .onChange(of: keySizeRaw) { _, rawValue in
                let newSize = KPSize(rawValue: rawValue) ?? .defSize
                if newSize == .custom {
                    draftCustomWidth = custW
                    draftCustomHeight = custH
                    isEditingCustomSize = true
                    showSizeAlert = true
                } else {
                    isEditingCustomSize = false
                    lastCommittedKeySizeRaw = rawValue
                    maskKeys = false
                }
            }
            .pickerStyle(.menu)
        }
        .padding(6)
        .background(keySizeBackground, in: .rect(cornerRadius: cornerRad.component))
    }

    private var themeSections: some View {
        List {
            Section {
                NavigationLink("Library", destination: PasscodeLibraryView())
            }
        }
        .listStyle(.insetGrouped)
        .scrollDisabled(true)
        .scrollIndicators(.hidden)
        .scrollContentBackground(colorScheme == .light ? .visible : .hidden)
        // Extend the embedded grouped row slightly closer to the screen edges.
        .padding(.horizontal, -22)
        .frame(height: 128)
        .offset(y: 10)
    }

    private var keypadPreview: some View {
        let allDigits = digits.flatMap { $0 }
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
            spacing: 14
        ) {
            ForEach(Array(allDigits.enumerated()), id: \.offset) { index, digit in
                if digit.isEmpty {
                    Color.clear.frame(width: 80, height: 80)
                } else {
                    Button {
                        selectedDigit = digit
                        showImagePicker = true
                    } label: {
                        keypadKeyLabel(for: digit)
                    }
                    .frame(width: 80, height: 80)
                    .aspectRatio(1, contentMode: .fit)
                    .contentShape(Circle())
                    .buttonStyle(.plain)
                    .accessibilityLabel("Choose artwork for key \(digit)")
                    // Bring only the side keys inward. The button offset moves
                    // its glass circle and custom artwork together without
                    // changing either the key dimensions or vertical spacing.
                    .offset(x: horizontalKeyOffset(for: index % 3))
                }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: 325)
        .frame(maxWidth: .infinity)
    }

    private func horizontalKeyOffset(for column: Int) -> CGFloat {
        switch column {
        case 0: return 10
        case 2: return -10
        default: return 0
        }
    }

    @ViewBuilder
    private func keypadKeyLabel(for digit: String) -> some View {
        if let image = previewImage(for: digit) {
            // Match Dialer Themer's artwork sizing, with only 2 pt vertical compression.
            PasscodeKeyArtworkImage(image: image)
        } else {
            let keypadID = KeypadID.allCases.first { $0.dialerNumber == digit }
            VStack(spacing: 1) {
                Text(digit)
                    .font(.system(size: 34, weight: .regular))
                if let letters = keypadID?.dialerLetters, !letters.isEmpty {
                    Text(letters)
                        .font(.system(size: 11, weight: .medium))
                        .tracking(1.5)
                }
            }
            .frame(width: 78, height: 78)
            .aspectRatio(1, contentMode: .fit)
            .foregroundStyle(Color(.label))
            .glassEffect(.clear.interactive(), in: .circle)
        }
    }

    private func previewImage(for digit: String) -> UIImage? {
        guard let theme = airlift.passcodeTheme else { return nil }
        // All preview states use the same prepared image data as Dialer Themer.
        // Keep the original theme data untouched; this cache is display-only.
        return processedPreviewImages[digit] ?? theme.keys[digit]
    }

    private var previewConfigurationKey: String {
        let themeID = airlift.passcodeTheme?.id.uuidString ?? "no-theme"
        let committedSizeRaw = isEditingCustomSize ? lastCommittedKeySizeRaw : keySizeRaw
        return "\(themeID)|\(committedSizeRaw)|\(custW)|\(custH)|\(maskKeys)"
    }

    private func rebuildPreviewImages() async {
        // Build display-only images for every mode. Dialer Themer normalizes imported
        // artwork through KeypadManager.resizeAndRet even in Default mode; Passcode
        // preview must use that same path to avoid displaying raw archive images.
        processedPreviewImages = [:]
        guard let theme = airlift.passcodeTheme else { return }

        // Theme readers and the image picker store rawData alongside every image.
        // Read only those bytes here; never encode UIImage on the main thread.
        var sourceData: [String: Data] = [:]
        for row in digits {
            for digit in row where !digit.isEmpty {
                if let data = theme.rawData[digit] {
                    sourceData[digit] = data
                }
            }
        }
        guard !sourceData.isEmpty else { return }

        let themeID = theme.id.uuidString
        let sizeRaw = isEditingCustomSize ? lastCommittedKeySizeRaw : keySizeRaw
        let width = custW
        let height = custH
        let shouldMask = maskKeys
        let worker = Task.detached(priority: .utility) { () -> PasscodePreviewImageBox in
            var images: [String: UIImage] = [:]
            let size = KPSize(rawValue: sizeRaw) ?? .defSize
            for (digit, data) in sourceData {
                if Task.isCancelled { break }
                let processedData: Data
                if size == .defSize && !shouldMask {
                    // Exact Default-mode preparation used by Dialer Themer on import.
                    processedData = KeypadManager.shared.resizeAndRet(withData: data, isDefault: true)
                } else {
                    processedData = processPasscodeKeyData(
                        data,
                        size: size,
                        customWidth: width,
                        customHeight: height,
                        mask: shouldMask
                    )
                }
                // UIImage decoding also stays on the worker thread. Returning the
                // immutable results in a box prevents large PNGs being decoded by
                // SwiftUI while it is laying out the keypad.
                if let image = UIImage(data: processedData) {
                    images[digit] = image
                }
            }
            return PasscodePreviewImageBox(images)
        }

        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled,
              previewConfigurationKey == "\(themeID)|\(sizeRaw)|\(width)|\(height)|\(shouldMask)" else { return }
        processedPreviewImages = result.images
    }


    /// Custom Passcode-only renderer: matches Dialer Themer's artwork sizing
    /// while preserving the same circular key backdrop.
    private struct PasscodeKeyArtworkImage: View {
        let image: UIImage

        var body: some View {
            let denoVal: Float = isPad() ? 2.1 : 3.0
            Image(uiImage: image)
                .resizable()
                .frame(
                    width: CGFloat(Float(image.size.width) / denoVal),
                    height: CGFloat(Float(image.size.height) / denoVal)
                )
                .background {
                    Circle()
                        .fill(Color.clear)
                        .glassEffect(.clear, in: .circle)
                        .frame(width: 78, height: 78)
                }
        }
    }


}
