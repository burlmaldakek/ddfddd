//
//  KeypadView.swift
//  Erosion
//
//  Created by lunginspector on 8/28/26.
//

import SwiftUI

import PhotosUI

struct KeypadView: View {
    @StateObject private var kpMgr = KeypadManager.shared
    @AppStorage("mpContainerPath") private var mpContainerPath = ""
    @AppStorage("mpContainerPathSource") private var mpContainerPathSource = ""
    @AppStorage("erosion.exploitSelection") private var exploitSelection = ErosionExploitSelection.both.rawValue
    @State private var resolvingMobilePhonePath = false
    let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
    @State private var size: KPSize = KPSize.defSize
    @State private var showSizeAlert = false
    @State private var custW = 0
    @State private var custH = 0
    @State private var showFileImporter = false
    @State private var isResettingKeys = false
    
    var body: some View {
        VStack {
            LazyVGrid(columns: columns, alignment: .center, spacing: 14) {
                ForEach($kpMgr.mpKeypad) { $item in
                    KeyItem(size: $size, kpID: item.kpID, imgData: $item.imgData)
                        .environmentObject(kpMgr)
                }
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 2) {
                    Text("Key Size")
                    Picker("", selection: $size) {
                        ForEach(KPSize.allCases, id: \.self) { kpSize in
                            Text(kpSize.label + (kpSize == .custom ? " (\(custW)x\(custH))" : "")).tag(kpSize)
                        }
                    }
                    .alert("What would you like the custom size to be?", isPresented: $showSizeAlert) {
                        TextField("Width", value: $custW, format: .number)
                            .keyboardType(.numberPad)
                        TextField("Height", value: $custH, format: .number)
                            .keyboardType(.numberPad)
                        Button("Cancel", role: .cancel) {
                            size = .defSize
                        }
                        Button("Set") {
                            kpMgr.changeSizeOfKeypads(size: size, custW: custW, custH: custH)
                        }
                    }
                    .onChange(of: size) { _, newSize in
                        if newSize != KPSize.custom {
                            kpMgr.changeSizeOfKeypads(size: newSize)
                        } else {
                            showSizeAlert.toggle()
                        }
                    }
                }
                .padding(6)
                .background(Color(.systemBackground), in: .rect(cornerRadius: cornerRad.component))
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    let res = kpMgr.applyKeypadItems()
                    if res {
                        Alertinator.shared.alert(title: "Successfully applied custom keypads!", body: KPMsg.applyComp, actionLabel: "Open Phone", action: {
                            openApp(withBID: SysBID.phone)
                        })
                        Haptic.shared.play(.soft)
                    } else {
                        Alertinator.shared.alert(title: "Failed to apply custom keypads!", body: AppMsg.opFailed)
                    }
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(KeypadButtonStyle(isConfirm: true))
                .disabled(resolvingMobilePhonePath)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 10)
            }
        }
        .navigationTitle(isPad() ? "" : "Dialer Themer")
        .frame(maxWidth: 325)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        kpMgr.maskKeysIntoCircle(size: size, custW: custW, custH: custH)
                    } label: {
                        Label("Mask Keys", systemImage: "circle")
                    }
                    if effectiveExploitSelection(for: exploitSelection) != .airlift {
                        Button {
                            getCurrentKeys()
                        } label: {
                            Label("Get Current Keys", systemImage: "externaldrive")
                        }
                        .disabled(resolvingMobilePhonePath)
                    }
                    Button {
                        openApp(withBID: SysBID.phone)
                    } label: {
                        Label("Open Phone", systemImage: "arrow.up.right.square")
                    }
                    Divider()
                    Button {
                        size = .defSize
                        kpMgr.clearKeypads()
                    } label: {
                        Label("Clear Keys", systemImage: "xmark")
                    }
                    Button(role: .destructive) {
                        Alertinator.shared.alert(
                            title: "Are you sure you'd like to reset your set keys?",
                            body: KPMsg.resetWarn,
                            actionLabel: "Confirm",
                            actionStyle: .destructive,
                            action: {
                                guard !isResettingKeys else { return }
                                isResettingKeys = true
                                Task { @MainActor in
                                    let succeeded: Bool
                                    if usesAirliftForSelectedExploit() {
                                        succeeded = await AirliftBridge.shared.resetDialerKeyCache()
                                    } else {
                                        succeeded = kpMgr.resetKeypadItems()
                                    }
                                    isResettingKeys = false
                                    if succeeded {
                                        kpMgr.clearKeypads()
                                        kpMgr.mpKeypad = emptyKeypadArray
                                        Alertinator.shared.alert(title: "Successfully reset dialer keys!", body: KPMsg.applyComp)
                                    } else {
                                        Alertinator.shared.alert(title: "Failed to reset dialer keys!", body: AppMsg.opFailed)
                                    }
                                }
                            }
                        )
                    } label: {
                        Label("Reset Keys", systemImage: "trash")
                    }
                    .disabled(isResettingKeys || resolvingMobilePhonePath)
                } label: {
                    Label("Menu", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
            }
            ToolbarSpacer(placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button("Import") {
                    showFileImporter = true
                }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            handleImport(result)
        }
        .onAppear {
            resolveMobilePhonePathIfNeeded()
        }
    }

    /// Combined resolves a missing container through InstallationProxy;
    /// the actual key-file read is always performed through Worse Query.
    /// A cached path is reused across exploit modes.
    private func resolveMobilePhonePathIfNeeded(completion: (() -> Void)? = nil) {
        guard !resolvingMobilePhonePath else { return }

        if !mpContainerPath.isEmpty {
            completion?()
            return
        }

        let selection = effectiveExploitSelection(for: exploitSelection)
        switch selection {
        case .airlift:
            // Airlift's existing Apply path resolves and persists its own target.
            return

        case .both:
            resolvingMobilePhonePath = true
            Task { @MainActor in
                let discoveredPath = await AirliftBridge.shared.resolveInstalledAppContainerPath(
                    bundleID: "com.apple.mobilephone"
                )
                resolvingMobilePhonePath = false
                if let discoveredPath, !discoveredPath.isEmpty {
                    mpContainerPath = discoveredPath
                    mpContainerPathSource = "installationProxy"
                    completion?()
                } else {
                    print("(kp) InstallationProxy could not resolve the MobilePhone container")
                }
            }

        case .worseQuery:
            resolvingMobilePhonePath = true
            DispatchQueue.global(qos: .userInitiated).async {
                let discoveredPath = fsHandlers.getContainerPathWithWorseQuery(forMatch: "com.apple.mobilephone")
                DispatchQueue.main.async {
                    resolvingMobilePhonePath = false
                    if !discoveredPath.isEmpty {
                        mpContainerPath = discoveredPath
                        mpContainerPathSource = "worse_query"
                        completion?()
                    } else {
                        print("(kp) Worse Query could not resolve the MobilePhone container")
                    }
                }
            }
        }
    }

    /// Load current TelephonyUI assets only after the shared path is available.
    private func getCurrentKeys() {
        size = .defSize
        resolveMobilePhonePathIfNeeded {
            kpMgr.getCurrentKeypads(size: .defSize, saveOgData: true)
        }
    }

    private struct KeyItem: View {
        @EnvironmentObject private var kpMgr: KeypadManager
        @Binding var size: KPSize
        @State var kpID: KeypadID
        @Binding var imgData: Data
        @State private var showPicker = false

        private var horizontalKeyOffset: CGFloat {
            switch kpID {
            case .one, .four, .seven, .star: return 10
            case .three, .six, .nine, .pound: return -10
            default: return 0
            }
        }
        
        var body: some View {
            Button {
                showPicker = true
            } label: {
                if let img = UIImage(data: imgData) {
                    KeypadArtworkImage(image: img)
                } else {
                    VStack(spacing: 1) {
                        Text(kpID.dialerNumber)
                            .font(.system(size: 34, weight: .regular))
                        if !kpID.dialerLetters.isEmpty {
                            Text(kpID.dialerLetters)
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
            .frame(width: 80, height: 80)
            .aspectRatio(1, contentMode: .fit)
            // Match Custom Passcode: bring only the outer columns inward.
            .offset(x: horizontalKeyOffset)
            .sheet(isPresented: $showPicker) {
                ImagePickerView() { data in
                    imgData = data
                    guard let img = UIImage(data: imgData) else { return }
                    let imgData = {
                        switch size {
                        case .defSize: return kpMgr.resizeAndRet(withData: data, isDefault: true)
                        case .custom: return kpMgr.resizeAndRet(withData: data, customSize: CGSize(width: Int(img.size.width), height: Int(img.size.height)))
                        default: return kpMgr.resizeAndRet(withData: data, newSize: size.float)
                        }
                    }()
                    kpMgr.updateKeypadItem(forID: kpID, withData: imgData, ogData: imgData)
                }
            }
        }
    }
    
    // MARK: handle import
    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let fileURL):
            let stopAccess = fileURL.startAccessingSecurityScopedResource()
            defer {
                if stopAccess {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }
            if kpMgr.importTheme(fromURL: fileURL) {
                Haptic.shared.play(.soft)
            } else {
                let detail = kpMgr.lastThemeImportError ?? AppMsg.opFailed
                Alertinator.shared.alert(title: "Failed to import file!", body: detail)
            }
        case .failure(let error):
            print("(kp) failed to import file: \(error.localizedDescription)")
            Alertinator.shared.alert(title: "Failed to import file!", body: "\(error.localizedDescription)")
        }
    }
    
}

// Shared artwork renderer. Keep this identical for Dialer Themer and Custom Passcode
// so imported images use the same native-size scaling and circular glass backdrop.
struct KeypadArtworkImage: View {
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

// MARK: UI
struct KeypadButtonStyle: ButtonStyle {
    var isConfirm = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 24))
            .frame(width: 75, height: 75)
            .foregroundStyle(Color(.label))
            .fontWeight(.medium)
            .glassEffect(.clear.tint(isConfirm ? Color.accentColor : Color.clear).interactive(), in: .circle)
    }
}
