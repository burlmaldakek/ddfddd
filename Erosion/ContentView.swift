//
//  ContentView.swift
//  Erosion
//
//  Created by lunginspector on 8/14/26.
//

import SwiftUI


struct ContentView: View {
    @AppStorage("ogMachineName") var ogMachineName = ""
    @EnvironmentObject var mgr: ErosionManager
    @State private var showSettings = false
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    LogView()
                        .modifier(LogPlatter())
                } header: {
                    HeaderLabel("Logs", symbol: "apple.terminal")
                }

                Section {
                    NavigationLink("Explore", destination: HomeThemingExploreView())
                } header: {
                    HeaderLabel("Theming", symbol: "paintbrush")
                }
                
                Section {
                    Button("Respring") {
                        mgr.shouldRespring = true
                    }

                } header: {
                    HeaderLabel("Actions", symbol: "gearshape")
                }
            }
            .navigationTitle("Erosion mod")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gear")
                            .labelStyle(.iconOnly)
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .onAppear {
                if ogMachineName.isEmpty {
                    ogMachineName = machineName()
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
