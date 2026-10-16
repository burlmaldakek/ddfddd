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
    @AppStorage("hasShownAirliftCompatibilityAlert") private var hasShownAirliftCompatibilityAlert = false
    
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
        defaults.register(defaults: ["atomic_write": true])

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
                print("[*] Erosion mod v2.1 (Release)")
                print("[*] Running on \(UIDevice.current.systemName) \(UIDevice.current.systemVersion) \(machineName())")
                print("[*] iOS Build \(buildNumber())")
                if isAirliftCompatibilityMode() {
                    if !hasShownAirliftCompatibilityAlert {
                        hasShownAirliftCompatibilityAlert = true
                        Alertinator.shared.alert(
                            title: "Airlift compatibility mode",
                            body: "This iOS build is not supported by bad_query. AirLift will be used in this mode.",
                            showCancel: false,
                            actionLabel: "Ok",
                            action: {}
                        )
                    }
                } else if !isSupported() && !weOnADebugBuild {
                    Alertinator.shared.alert(title: "Your \(device.systemName) version is not supported!", body: AppMsg.unsupported, showCancel: false, actionLabel: "Exit", action: { exitinator() })
                }
            }
            .overlay {
                if mgr.shouldRespring {
                    RespringView()
                        .brightness(-1.0)
                        .ignoresSafeArea()
                }
            }
        }
    }
}

extension UIDocumentPickerViewController {
    @objc func fix_init(forOpeningContentTypes contentTypes: [UTType], asCopy: Bool) -> UIDocumentPickerViewController {
        return fix_init(forOpeningContentTypes: contentTypes, asCopy: true)
    }
}
