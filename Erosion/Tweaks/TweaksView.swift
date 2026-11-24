//
//  TweaksView.swift
//  Erosion
//
//  Created by lunginspector on 8/26/26.
//

import SwiftUI

struct TweaksView: View {
    @EnvironmentObject private var airlift: AirliftBridge
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("erosion.exploitSelection") private var exploitSelection = ErosionExploitSelection.both.rawValue
    @State private var blockedFeature: String?
    @State private var airliftReady = false

    var body: some View {
        let selection = effectiveExploitSelection(for: exploitSelection)
        let themingAccessRequired = selection == .airlift
        // Other, Custom Passcode and Cards Overwrite always require both
        // LocalDevVPN and a valid pairing whenever the Airlift section is shown.
        // This is independent of the iOS build; the existing readiness check
        // remains the single source of truth.
        let airliftSectionAccessRequired = selection != .worseQuery

        NavigationStack {
            List {
                Section {
                    if themingAccessRequired && !airliftReady {
                        blockedFeatureRow("Custom Wallpapers")
                        blockedFeatureRow("Dialer Themer")
                    } else {
                        // Keep the original Erosion order in every exploit mode.
                        NavigationLink("Custom Wallpapers", destination: PosterBoardView())
                        NavigationLink("Dialer Themer", destination: KeypadView())
                    }
                } header: {
                    HeaderLabel("Theming", symbol: "paintbrush")
                }

                if selection != .airlift {
                    Section {
                        if selection == .worseQuery {
                            NavigationLink("MobileGestalt", destination: GestaltView())
                            NavigationLink("Config Tweaks", destination: ConfigView())
                            NavigationLink("File Operations", destination: OperationsView())
                        } else {
                            if raveSupported() || weOnADebugBuild || isAirliftCompatibilityMode() {
                                NavigationLink("MobileGestalt", destination: GestaltView())
                            }
                            NavigationLink("Config Tweaks", destination: ConfigView())
                            NavigationLink("File Operations", destination: OperationsView())
                        }
                    } header: {
                        HeaderLabel("System", symbol: "gear")
                    }
                }

                if selection != .worseQuery {
                    Section {
                        if airliftSectionAccessRequired && !airliftReady {
                            blockedFeatureRow("Custom Passcode")
                        } else {
                            NavigationLink("Custom Passcode", destination: ExperimentalPasscodeView())
                        }

                        if UIDevice.current.userInterfaceIdiom != .pad {
                            if airliftSectionAccessRequired && !airliftReady {
                                blockedFeatureRow("Cards Overwrite")
                            } else {
                                NavigationLink("Cards Overwrite", destination: ExperimentalWalletView())
                            }
                        }

                        if airliftSectionAccessRequired && !airliftReady {
                            blockedFeatureRow("Other")
                        } else {
                            NavigationLink("Other", destination: OtherView())
                        }
                    } header: {
                        HeaderLabel("Airlift", symbol: "antenna.radiowaves.left.and.right")
                    }
                }
            }
            .navigationTitle("Tweaks")
            .task(id: "\(selection.rawValue)-\(airliftSectionAccessRequired)") {
                refreshAirliftReadiness(required: airliftSectionAccessRequired)
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    refreshAirliftReadiness(required: airliftSectionAccessRequired)
                }
            }
            .alert("Airlift required", isPresented: Binding(get: { blockedFeature != nil }, set: { if !$0 { blockedFeature = nil } })) {
                Button("OK", role: .cancel) { blockedFeature = nil }
            } message: {
                Text("Enable LocalDevVPN and import a valid pairing file in Airlift before opening \(blockedFeature ?? "this feature").")
            }
        }
    }

    private func refreshAirliftReadiness(required: Bool) {
        guard required else {
            airliftReady = true
            return
        }
        let bridge = airlift
        DispatchQueue.global(qos: .utility).async {
            let ready = bridge.airliftFeatureReady()
            DispatchQueue.main.async {
                airliftReady = ready
            }
        }
    }

    @ViewBuilder
    private func blockedFeatureRow(_ title: String) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Image(systemName: "chevron.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
