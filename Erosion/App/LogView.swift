//
//  LogView.swift
//  dirtyZero
//
//  Created by lunginspector on 4/17/26.
//

import SwiftUI

struct LogView: View {
    @StateObject private var mgr = ErosionManager.shared
    @AppStorage("erosion.exploitSelection") private var exploitSelection = ErosionExploitSelection.both.rawValue

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    Text(mgr.logOutput)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .multilineTextAlignment(.leading)
                    Spacer()
                        .id(0)
                }
                .onTapGesture(count: 2) {
                    cycleExploitSelection()
                }
                .contextMenu {
                    Button {
                        Haptic.shared.play(.soft)
                        UIPasteboard.general.string = mgr.logOutput
                    } label: {
                        Label("Copy Output", systemImage: "doc.on.doc")
                    }

                    Button {
                        do {
                            let formatter = DateFormatter()
                            formatter.dateFormat = "MM-dd-yyyy-HHmmss"
                            let date = formatter.string(from: Date())

                            let tempURL = URL.temporaryDirectory
                                .appendingPathComponent("Erosion-Log-\(date)")
                                .appendingPathExtension("txt")
                            guard let data = mgr.logOutput.data(using: .utf8) else {
                                throw "failed to create data from log string"
                            }

                            try data.write(to: tempURL)
                            presentShareSheet(with: tempURL)
                        } catch {
                            print("(fm) failed to export logs: \(error.localizedDescription)")
                        }
                    } label: {
                        Label("Export Logs", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    /// Changes the active exploit mode only on a deliberate double tap.
    /// This preference change is intentionally silent and does not append to logs.
    private func cycleExploitSelection() {
        let current = ErosionExploitSelection(rawValue: exploitSelection) ?? .both
        let next: ErosionExploitSelection
        switch current {
        case .both:
            next = .airlift
        case .airlift:
            next = .worseQuery
        case .worseQuery:
            next = .both
        }
        exploitSelection = next.rawValue
    }
}
