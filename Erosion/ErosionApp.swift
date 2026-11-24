//
//  ErosionApp.swift
//  Erosion
//
//  Created by lunginspector on 8/14/26.
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

let device = UIDevice.current
let fm = FileManager.default
var weOnADebugBuild = false
var pipe = Pipe()
var sema = DispatchSemaphore(value: 0)

@main
struct ErosionApp: App {
    @StateObject private var mgr = ErosionManager.shared
    @StateObject private var airlift = AirliftBridge.shared
    @State private var currentTab = 0
    @State private var shouldScanPrefixOnNextActivation = true
    @State private var appGroupResolved = false
    @Environment(\.scenePhase) private var scenePhase
    
    init() {
        // Mond-compatible persistence setting. Keep the new key enabled by default.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "atomic_write") == nil {
            if let old = defaults.object(forKey: "mgWriteAtomically") as? Bool {
                defaults.set(old, forKey: "atomic_write")
            } else {
                defaults.set(true, forKey: "atomic_write")
            }
        }
        defaults.register(defaults: [
            "atomic_write": true,
            "airlift.saveReadResults": true
        ])
        if !defaults.bool(forKey: "airlift.saveReadResults") {
            _ = AirliftBridge.clearTemporaryDirectoryContents()
        }

        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        
        // fix file picker
        let fixMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, #selector(UIDocumentPickerViewController.fix_init(forOpeningContentTypes:asCopy:)))!
        let origMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, #selector(UIDocumentPickerViewController.init(forOpeningContentTypes:asCopy:)))!
        method_exchangeImplementations(origMethod, fixMethod)
        
        #if DEBUG
        weOnADebugBuild = true
        #else
        weOnADebugBuild = false
        #endif
    }
    
    var body: some Scene {
        WindowGroup {
            ZStack {
                TabView {
                    ContentView()
                        .tabItem {
                            Label("Home", systemImage: "house")
                        }
                        .id(0)
                    TweaksView()
                        .tabItem {
                            Label("Tweaks", systemImage: "wrench.and.screwdriver")
                        }
                        .id(1)
                    FMRootView()
                        .tabItem {
                            Label("File Browser", systemImage: "folder")
                        }
                        .id(2)
                }
                .environmentObject(mgr)
                .environmentObject(airlift)
                .allowsHitTesting(!isIOS273Beta2OrLater())

                if mgr.shouldRespring {
                    RespringView()
                        .brightness(-1.0)
                        .ignoresSafeArea()
                        .zIndex(10)
                }

                if isIOS273Beta2OrLater() {
                    UnsupportedBuildGateView()
                        .zIndex(1000)
                }
            }
            .onAppear {
                pipe.fileHandleForReading.readabilityHandler = { fh in
                    let data = fh.availableData
                    
                    if data.isEmpty {
                        fh.readabilityHandler = nil
                        sema.signal()
                        return
                    }
                    
                    guard let text = String(data: data, encoding: .utf8) else {
                        return
                    }
                    
                    DispatchQueue.main.async {
                        mgr.logOutput.append(text)
                    }
                }
                print("")
                print("[*] Erosion mod v3.1 (Release)")
                print("[*] Running on \(UIDevice.current.systemName) \(UIDevice.current.systemVersion) \(machineName())")
                print("[*] iOS Build \(buildNumber())")
                group = wq.getAppGroup()
                appGroupResolved = true
                print("(wq) Using app group: \(wq.appGroupLogValue())")
                if !isIOS273Beta2OrLater(), scenePhase == .active && shouldScanPrefixOnNextActivation {
                    shouldScanPrefixOnNextActivation = false
                    DialerPasscodePrefix.scanAtAppLaunch()
                }
                if !isIOS273Beta2OrLater() && !isAirliftCompatibilityMode() && !isSupported() && !weOnADebugBuild {
                    Alertinator.shared.alert(title: "Your \(device.systemName) version is not supported!", body: AppMsg.unsupported, showCancel: false, actionLabel: "Exit", action: { exitinator() })
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase != .active {
                    shouldScanPrefixOnNextActivation = true
                } else if !isIOS273Beta2OrLater(), appGroupResolved && shouldScanPrefixOnNextActivation {
                    shouldScanPrefixOnNextActivation = false
                    DialerPasscodePrefix.scanAtAppLaunch()
                }

                if newPhase == .background || newPhase == .active {
                    guard !UserDefaults.standard.bool(forKey: "airlift.saveReadResults") else { return }
                    Task {
                        await Task.detached(priority: .utility) {
                            _ = AirliftBridge.clearTemporaryDirectoryContents()
                        }.value
                        await MainActor.run {
                            airlift.clearReadSnapshotState()
                        }
                    }
                }
            }
        }
    }
}

private struct UnsupportedBuildGateView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 18) {
                Text("Your iOS version is NOT supported!")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)

                Text("Tweaks probably won’t apply. Please leave this app.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.72))

                Button("Exit") {
                    exitinator()
                }
                .font(.headline)
                .frame(minWidth: 132)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .padding(.top, 8)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
    }
}

extension UIDocumentPickerViewController {
    @objc func fix_init(forOpeningContentTypes contentTypes: [UTType], asCopy: Bool) -> UIDocumentPickerViewController {
        return fix_init(forOpeningContentTypes: contentTypes, asCopy: true)
    }
}
