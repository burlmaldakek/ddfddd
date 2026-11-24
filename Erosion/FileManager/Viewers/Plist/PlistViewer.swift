//
//  PlistViewer.swift
//  Filos
//
//  Created by lunginspector on 7/25/26.
//

import SwiftUI

struct PlistViewer: View {
    @StateObject private var pmgr = PlistManager.shared
    @Environment(\.dismiss) var dismiss
    var fileURL: URL
    var remotePath: String? = nil
    private let forceReadOnly: Bool
    
    @State private var file = clearFileItem
    @State private var showErrorView = false
    
    init(_ fileURL: URL, remotePath: String? = nil, readOnly: Bool = false) {
        self.fileURL = fileURL
        self.remotePath = remotePath
        self.forceReadOnly = readOnly
    }
    
    var body: some View {
        NavigationView {
            List {
                if showErrorView {
                    PlainAlert(title: "Failed to load plist!", symbol: "exclamationmark.triangle.fill", text: Errors.checkLogs, color: .yellow)
                } else {
                    ForEach($pmgr.plistArray) { $item in
                        ItemRow(item: $item, hierarchy: 0)
                            .environmentObject(pmgr)
                    }
                }
            }
            // The title is known from the input URL immediately. Avoid changing it from
            // an empty placeholder after the first frame, which can animate the top bar.
            .navigationTitle(fileURL.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .listStyle(.inset)
            .safeAreaInset(edge: .bottom) {
                if !pmgr.isWritable {
                    HStack {
                        Spacer()
                        Button {
                            Alertinator.shared.alert(title: "View-Only File", body: "You can only read this file.")
                        } label: {
                            Image(systemName: "lock")
                                .padding(10)
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.trailing)
                        .ignoresSafeArea()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if let url = makeTemp(file.fileURL) {
                            presentShareSheet(with: url)
                        }
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        ToolbarLabel("Close", symbol: "xmark")
                    }
                }
            }
        }
        .onAppear {
            // Loading plist rows can publish several state changes on first display.
            // Apply the initial setup without an implicit transition so the header
            // does not slide for a fraction of a second after the viewer appears.
            withTransaction(Transaction(animation: nil)) {
                pmgr.url = fileURL
                pmgr.remotePath = remotePath
                var loadedFile = getFileItem(at: fileURL)
                if forceReadOnly { loadedFile.writable = false }
                file = loadedFile
                let res = pmgr.loadPlistItems()
                if !res {
                    showErrorView = true
                }
                pmgr.isWritable = file.writable == true && !forceReadOnly && pmgr.isRootDictionary
            }
        }
        .navigationViewStyle(.stack)
    }
}

// no comment.
extension UIColor {
    static func hierarchyLevelColor(_ level: Int = 0) -> UIColor {
        UIColor { trait in
            let isDark = (trait.userInterfaceStyle == .dark)
            let baseColor = isDark ? UIColor.secondarySystemBackground.resolvedColor(with: trait) : UIColor.white.resolvedColor(with: trait)
            
            let clampedLevel = max(0, level)
            var factor = max(0, 1 - 0.03 * CGFloat(clampedLevel))
            if isDark {
                factor = max(0, 1 + 0.24 * CGFloat(clampedLevel))
            }

            var h: CGFloat = 0
            var s: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0

            if baseColor.getHue(&h, saturation: &s, brightness: &b, alpha: &a) {
                let newBrightness = max(0, min(1, b * factor))
                return UIColor(hue: h, saturation: s, brightness: newBrightness, alpha: a)
            }

            var r: CGFloat = 0
            var g: CGFloat = 0
            var bl: CGFloat = 0

            guard baseColor.getRed(&r, green: &g, blue: &bl, alpha: &a) else {
                return baseColor
            }

            return UIColor(red: max(0, r * factor), green: max(0, g * factor), blue: max(0, bl * factor), alpha: a)
        }
    }
}
